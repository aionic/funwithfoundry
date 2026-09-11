"""Authorized SharePoint/fixture raw-byte staging for native knowledge-source ingestion."""

import hashlib
import json
import logging
import os
import re
import time
import unicodedata
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
from pathlib import PurePosixPath
from typing import Any
from urllib.parse import quote, urlsplit
from uuid import uuid4

import azure.functions as func
import requests
from azure.core.exceptions import HttpResponseError, ResourceExistsError, ServiceRequestError, ServiceResponseError
from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobServiceClient, ContentSettings

from authorization import IngestionError, authorize
from synthetic_fixture import fixture_pdf

app = func.FunctionApp(http_auth_level=func.AuthLevel.ANONYMOUS)

GRAPH_SCOPE = "https://graph.microsoft.com/.default"
MAX_REQUEST_BYTES = 4096
MAX_RESULT_BYTES = 10 * 1024 * 1024
MAX_ATTEMPTS = 3
MAX_RETRY_AFTER = 10.0
RETRYABLE = {429, 500, 502, 503, 504}
MEDIA_TYPES = {".pdf": "application/pdf", ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".txt": "text/plain"}

_credential = DefaultAzureCredential()


def _token(scope: str) -> str:
    return _credential.get_token(scope).token


def _retry_delay(headers: Any, attempt: int) -> float:
    value = headers.get("Retry-After", "")
    try:
        delay = float(value)
    except (TypeError, ValueError):
        try:
            delay = (parsedate_to_datetime(value) - datetime.now(timezone.utc)).total_seconds()
        except (TypeError, ValueError, OverflowError):
            delay = float(2 ** attempt)
    return min(MAX_RETRY_AFTER, max(0.0, delay))


def _request(method: str, url: str, stage: str, request_id: str, **kwargs: Any) -> requests.Response:
    headers = dict(kwargs.pop("headers", {}))
    headers["x-ms-client-request-id"] = request_id
    for attempt in range(MAX_ATTEMPTS):
        try:
            response = requests.request(
                method, url, headers=headers, timeout=(5, 30), stream=True,
                allow_redirects=False, **kwargs,
            )
        except (requests.Timeout, requests.ConnectionError):
            if method != "GET" or attempt == MAX_ATTEMPTS - 1:
                raise IngestionError(f"{stage}_unavailable", 502) from None
            time.sleep(_retry_delay({}, attempt))
            continue
        if response.status_code in RETRYABLE and attempt < MAX_ATTEMPTS - 1:
            delay = _retry_delay(response.headers, attempt)
            response.close()
            time.sleep(delay)
            continue
        if response.status_code >= 400:
            response.close()
            raise IngestionError(f"{stage}_http_error", 502)
        return response
    raise IngestionError(f"{stage}_unavailable", 502)


def _read_bytes(response: requests.Response, limit: int, code: str) -> bytes:
    try:
        length = int(response.headers.get("Content-Length", "0"))
    except (TypeError, ValueError):
        raise IngestionError("invalid_upstream_response", 502) from None
    if length > limit:
        raise IngestionError(code, 413)
    data = bytearray()
    for chunk in response.iter_content(chunk_size=65536):
        if len(data) + len(chunk) > limit:
            raise IngestionError(code, 413)
        data.extend(chunk)
    return bytes(data)


def _read_json(response: requests.Response) -> dict[str, Any]:
    if not 200 <= response.status_code < 300:
        raise IngestionError("unexpected_upstream_redirect", 502)
    try:
        body = json.loads(_read_bytes(response, MAX_RESULT_BYTES, "upstream_response_too_large"))
    except (ValueError, UnicodeError):
        raise IngestionError("invalid_upstream_json", 502) from None
    if not isinstance(body, dict):
        raise IngestionError("invalid_upstream_json", 502)
    return body


def _endpoint(name: str) -> str:
    value = os.environ[name].rstrip("/")
    parsed = urlsplit(value)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password or parsed.port not in (None, 443) or parsed.path or parsed.query or parsed.fragment:
        raise IngestionError("invalid_configuration", 503)
    return value


def _scoped_url(url: str, hostname: str) -> str:
    parsed = urlsplit(url)
    if parsed.scheme != "https" or parsed.hostname != hostname or parsed.username or parsed.password or parsed.port not in (None, 443) or parsed.fragment:
        raise IngestionError("untrusted_source_url", 502)
    return url


def _configured_path(value: str, root_allowed: bool = False) -> str:
    path = unicodedata.normalize("NFC", value)
    if root_allowed and path == "/":
        return path
    if not path or path.startswith("//") or any(char in path for char in "\\%?#") or any(ord(char) < 32 or ord(char) == 127 for char in path):
        raise IngestionError("invalid_source_configuration", 503)
    if any(part in ("", ".", "..") for part in path.lstrip("/").split("/")):
        raise IngestionError("invalid_source_configuration", 503)
    return path


def _source_id(kind: str, hostname: str, site_path: str, file_path: str) -> str:
    identity = json.dumps(
        [kind, hostname.lower(), unicodedata.normalize("NFC", site_path).lower(), unicodedata.normalize("NFC", file_path).lower()],
        ensure_ascii=True, separators=(",", ":"),
    )
    return hashlib.sha256(identity.encode("utf-8")).hexdigest()


def _document_media_type(title: str, media_type: str) -> str:
    extension = PurePosixPath(title).suffix.lower()
    expected = MEDIA_TYPES.get(extension)
    if expected == "text/plain" and isinstance(media_type, str):
        media_type = media_type.strip(" \t").lower()
        if re.fullmatch(r'text/plain(?:[ \t]*;[ \t]*charset[ \t]*=[ \t]*(?:utf-?8|"utf-?8"))?', media_type):
            media_type = expected
    if not expected or media_type not in (expected, "application/octet-stream"):
        raise IngestionError("unsupported_document_type", 415)
    return expected


def _validate_document(data: bytes, title: str, media_type: str, max_bytes: int) -> None:
    expected = _document_media_type(title, media_type)
    if not data:
        raise IngestionError("empty_document", 422)
    if len(data) > max_bytes:
        raise IngestionError("document_too_large", 413)
    if expected == "text/plain":
        try:
            text = data.decode("utf-8-sig")
        except UnicodeDecodeError:
            raise IngestionError("invalid_document_type", 415) from None
        if any(unicodedata.category(char) == "Cc" and char not in "\t\r\n" for char in text):
            raise IngestionError("invalid_document_type", 415)
        if not text.strip():
            raise IngestionError("empty_document", 422)
        return
    signatures = {"application/pdf": b"%PDF-", "image/png": b"\x89PNG\r\n\x1a\n", "image/jpeg": b"\xff\xd8\xff"}
    signature = signatures.get(expected)
    if signature is None or not data.startswith(signature):
        raise IngestionError("invalid_document_type", 415)


def _fetch_sharepoint_file(max_bytes: int, request_id: str) -> tuple[bytes, str, str, str, str]:
    hostname = os.environ["SP_SITE_HOSTNAME"].lower()
    site_path = _configured_path(os.environ["SP_SITE_PATH"], root_allowed=True)
    file_path = _configured_path(os.environ["SP_FILE_PATH"])
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]*\.sharepoint\.com", hostname) or not site_path.startswith("/") or file_path.startswith("/"):
        raise IngestionError("invalid_source_configuration", 503)
    title = PurePosixPath(file_path).name
    if PurePosixPath(title).suffix.lower() not in MEDIA_TYPES:
        raise IngestionError("unsupported_document_type", 415)
    headers = {"Authorization": f"Bearer {_token(GRAPH_SCOPE)}"}
    site_url = f"https://graph.microsoft.com/v1.0/sites/{hostname}"
    if site_path != "/":
        site_url += f":{quote(site_path, safe='/')}"
    with _request("GET", site_url, "graph", request_id, headers=headers) as response:
        site_id = _read_json(response)["id"]
    item_url = f"https://graph.microsoft.com/v1.0/sites/{quote(site_id, safe=',')}/drive/root:/{quote(file_path, safe='/')}"
    with _request("GET", item_url, "graph", request_id, headers=headers) as response:
        item = _read_json(response)
    size = item.get("size")
    if type(size) is not int or size <= 0 or not isinstance(item.get("file"), dict) or "remoteItem" in item:
        raise IngestionError("invalid_source_metadata", 502)
    if size > max_bytes:
        raise IngestionError("document_too_large", 413)
    source_url = _scoped_url(item["webUrl"], hostname)
    if urlsplit(source_url).query:
        raise IngestionError("invalid_source_metadata", 502)
    media_type = item["file"].get("mimeType", "")
    _document_media_type(title, media_type)
    with _request("GET", f"{item_url}:/content", "graph", request_id, headers=headers) as response:
        if response.status_code == 302:
            download_url = _scoped_url(response.headers.get("Location", ""), hostname)
            with _request("GET", download_url, "download", request_id) as download:
                if download.status_code != 200:
                    raise IngestionError("unexpected_upstream_redirect", 502)
                data = _read_bytes(download, max_bytes, "document_too_large")
        elif response.status_code == 200:
            data = _read_bytes(response, max_bytes, "document_too_large")
        else:
            raise IngestionError("unexpected_upstream_redirect", 502)
    return data, title, media_type, source_url, _source_id("sharepoint", hostname, site_path, file_path)


def _blob_call(operation: Any, already_exists: str | None = None) -> None:
    for attempt in range(MAX_ATTEMPTS):
        try:
            operation()
            return
        except ResourceExistsError as error:
            if already_exists and error.error_code == already_exists:
                return
            raise IngestionError("staging_conflict", 502) from None
        except HttpResponseError as error:
            if error.status_code not in RETRYABLE or attempt == MAX_ATTEMPTS - 1:
                raise IngestionError("staging_http_error", 502) from None
            time.sleep(_retry_delay(error.response.headers if error.response else {}, attempt))
        except (ServiceRequestError, ServiceResponseError):
            if attempt == MAX_ATTEMPTS - 1:
                raise IngestionError("staging_unavailable", 502) from None
            time.sleep(_retry_delay({}, attempt))


def _stage_to_blob(data: bytes, title: str, source_id: str, content_hash: str, source_url: str, request_id: str) -> tuple[str, str]:
    container = os.environ.get("STAGING_CONTAINER", "spo-staging")
    name = f"native/{source_id}/source{PurePosixPath(title).suffix.lower()}"
    with BlobServiceClient(
        account_url=_endpoint("STAGING_BLOB_ENDPOINT"), credential=_credential,
        retry_total=0, connection_timeout=5, read_timeout=30,
    ) as client:
        _blob_call(lambda: client.create_container(container, timeout=30, client_request_id=request_id), "ContainerAlreadyExists")
        blob = client.get_blob_client(container, name)
        _blob_call(lambda: blob.upload_blob(
            data, overwrite=True, timeout=30, client_request_id=request_id,
            content_settings=ContentSettings(content_type=MEDIA_TYPES[PurePosixPath(title).suffix.lower()]),
            metadata={"source_id": source_id, "content_hash": content_hash, "doc_url": quote(source_url, safe=":/%")},
        ))
        return blob.url, name


def _unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    body: dict[str, Any] = {}
    for key, value in pairs:
        if key in body:
            raise ValueError("Duplicate JSON key")
        body[key] = value
    return body


def _input(req: func.HttpRequest) -> str:
    if req.method != "POST":
        raise IngestionError("method_not_allowed", 405)
    if req.params or req.headers.get("content-encoding"):
        raise IngestionError("invalid_request", 400)
    if req.headers.get("content-type", "").split(";", 1)[0].strip().lower() != "application/json":
        raise IngestionError("expected_json", 415)
    raw = req.get_body()
    if len(raw) > MAX_REQUEST_BYTES:
        raise IngestionError("request_too_large", 413)
    try:
        body = json.loads(raw.decode("utf-8"), object_pairs_hook=_unique_object)
    except (ValueError, UnicodeError):
        raise IngestionError("invalid_json", 400) from None
    if body == {"mode": "fixture", "fixtureId": "accelerator-v1"}:
        return "fixture"
    if body == {"mode": "sharepoint"}:
        return "sharepoint"
    raise IngestionError("invalid_request", 400)


@app.route(route="ingest", methods=["POST"])
def ingest(req: func.HttpRequest) -> func.HttpResponse:
    request_id = str(uuid4())
    started = time.monotonic()
    stage = "authorization"
    try:
        authorize(req.headers.get("authorization", ""))
        stage = "input"
        mode = _input(req)
        max_bytes = int(os.environ.get("INGEST_MAX_BYTES", str(5 * 1024 * 1024)))
        if not 1 <= max_bytes <= 10 * 1024 * 1024:
            raise IngestionError("invalid_configuration", 503)
        stage = "source"
        if mode == "fixture":
            if os.environ.get("INGEST_FIXTURE_ENABLED", "false").lower() != "true":
                raise IngestionError("fixture_disabled", 403)
            data, title, media_type = fixture_pdf(), "accelerator-v1.pdf", "application/pdf"
            source_url = "urn:funwithfoundry:fixture:accelerator-v1"
            source_id = _source_id("fixture", "funwithfoundry", "/synthetic", "accelerator-v1.pdf")
        else:
            data, title, media_type, source_url, source_id = _fetch_sharepoint_file(max_bytes, request_id)
        _validate_document(data, title, media_type, max_bytes)
        content_hash = hashlib.sha256(data).hexdigest()
        stage = "staging"
        blob_url, blob_name = _stage_to_blob(data, title, source_id, content_hash, source_url, request_id)
        result = {
            "request_id": request_id, "status": "staged", "source_id": source_id,
            "content_hash": content_hash, "source_url": source_url,
            "blob_url": blob_url, "blob_name": blob_name, "bytes": len(data), "mode": mode,
        }
        status = 202
    except IngestionError as error:
        result = {"request_id": request_id, "error": {"code": error.code, "stage": stage}}
        status = error.status
    except Exception as error:
        logging.error("ingestion request_id=%s stage=%s exception_type=%s", request_id, stage, type(error).__name__)
        result = {"request_id": request_id, "error": {"code": "ingestion_failed", "stage": stage}}
        status = 500
    logging.info("ingestion request_id=%s stage=%s status=%d duration_ms=%d", request_id, stage, status, int((time.monotonic() - started) * 1000))
    headers = {"X-Request-ID": request_id, "Cache-Control": "no-store"}
    if status == 401:
        headers["WWW-Authenticate"] = "Bearer"
    return func.HttpResponse(json.dumps(result, ensure_ascii=True), status_code=status, mimetype="application/json", headers=headers)
