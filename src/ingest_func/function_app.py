"""SharePoint -> private blob -> Content Understanding -> AI Search across the vWAN.

The SharePoint fetch is a public Graph call. Everything after it stays on private
endpoints, and the push to AI Search crosses regions over the Virtual WAN.
"""

import logging
import os
import time
from typing import Any

import azure.functions as func
import requests
from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobServiceClient

# Anonymous is safe here only because the app has public network access disabled and is
# reachable solely through its private endpoint - the network is the auth boundary.
# Key-based auth needs the admin API, which is itself only reachable through that same
# private endpoint, so it adds nothing here.
app = func.FunctionApp(http_auth_level=func.AuthLevel.ANONYMOUS)

GRAPH_SCOPE = "https://graph.microsoft.com/.default"
COGNITIVE_SCOPE = "https://cognitiveservices.azure.com/.default"
SEARCH_SCOPE = "https://search.azure.com/.default"

CU_API_VERSION = "2025-11-01"
SEARCH_API_VERSION = "2024-07-01"

_credential = DefaultAzureCredential()


def _token(scope: str) -> str:
    return _credential.get_token(scope).token


def _fetch_sharepoint_file(site_hostname: str, site_path: str, file_path: str) -> tuple[bytes, str]:
    """Public-internet Graph call, egressing via Azure Firewall."""
    headers = {"Authorization": f"Bearer {_token(GRAPH_SCOPE)}"}

    site_resp = requests.get(
        f"https://graph.microsoft.com/v1.0/sites/{site_hostname}:{site_path}",
        headers=headers,
        timeout=30,
    )
    site_resp.raise_for_status()
    site_id = site_resp.json()["id"]

    content_resp = requests.get(
        f"https://graph.microsoft.com/v1.0/sites/{site_id}/drive/root:/{file_path}:/content",
        headers=headers,
        timeout=120,
    )
    content_resp.raise_for_status()
    return content_resp.content, os.path.basename(file_path)


def _stage_to_blob(account_url: str, container: str, name: str, data: bytes) -> None:
    client = BlobServiceClient(account_url=account_url, credential=_credential)
    try:
        client.create_container(container)
    except Exception:
        pass
    client.get_blob_client(container, name).upload_blob(data, overwrite=True)


def _analyze(cu_endpoint: str, analyzer_id: str, data: bytes) -> dict[str, Any]:
    """analyzeBinary, not the URL-reference analyze API.

    The file-reference API makes the CU service fetch the blob URL itself, which is
    impossible when the storage account has public access disabled.
    """
    url = (
        f"{cu_endpoint}/contentunderstanding/analyzers/{analyzer_id}:analyzeBinary"
        f"?api-version={CU_API_VERSION}"
    )
    resp = requests.post(
        url,
        headers={
            "Authorization": f"Bearer {_token(COGNITIVE_SCOPE)}",
            "Content-Type": "application/octet-stream",
        },
        data=data,
        timeout=120,
    )
    resp.raise_for_status()

    operation_url = resp.headers.get("Operation-Location")
    if not operation_url:
        return resp.json()

    for _ in range(60):
        time.sleep(3)
        poll = requests.get(
            operation_url,
            headers={"Authorization": f"Bearer {_token(COGNITIVE_SCOPE)}"},
            timeout=60,
        )
        poll.raise_for_status()
        body = poll.json()
        status = body.get("status", "").lower()
        if status == "succeeded":
            return body
        if status == "failed":
            raise RuntimeError(f"Content Understanding failed: {body}")

    raise TimeoutError("Content Understanding did not complete in time")


def _extract_markdown(result: dict[str, Any]) -> str:
    contents = result.get("result", {}).get("contents", [])
    return "\n\n".join(c.get("markdown", "") for c in contents if c.get("markdown"))


def _push_to_search(search_endpoint: str, index: str, doc_id: str, title: str, content: str) -> dict:
    """Cross-region call over the vWAN to the private search service."""
    url = f"{search_endpoint}/indexes/{index}/docs/index?api-version={SEARCH_API_VERSION}"
    payload = {
        "value": [
            {
                "@search.action": "mergeOrUpload",
                "id": doc_id,
                "title": title,
                "content": content,
            }
        ]
    }
    resp = requests.post(
        url,
        headers={
            "Authorization": f"Bearer {_token(SEARCH_SCOPE)}",
            "Content-Type": "application/json",
        },
        json=payload,
        timeout=60,
    )
    resp.raise_for_status()
    return resp.json()


@app.route(route="ingest", methods=["POST"])
def ingest(req: func.HttpRequest) -> func.HttpResponse:
    try:
        body = req.get_json()
    except ValueError:
        return func.HttpResponse("Expected a JSON body", status_code=400)

    site_hostname = body.get("siteHostname") or os.environ["SP_SITE_HOSTNAME"]
    site_path = body.get("sitePath") or os.environ["SP_SITE_PATH"]
    file_path = body.get("filePath") or os.environ["SP_FILE_PATH"]

    cu_endpoint = os.environ["CU_ENDPOINT"].rstrip("/")
    analyzer_id = os.environ.get("CU_ANALYZER_ID", "prebuilt-document")
    search_endpoint = os.environ["SEARCH_ENDPOINT"].rstrip("/")
    search_index = os.environ.get("SEARCH_INDEX", "spo-docs")
    blob_account_url = os.environ["STAGING_BLOB_ENDPOINT"]
    container = os.environ.get("STAGING_CONTAINER", "spo-staging")

    logging.info("Fetching %s from SharePoint", file_path)
    data, filename = _fetch_sharepoint_file(site_hostname, site_path, file_path)

    logging.info("Staging %s (%d bytes) to private blob", filename, len(data))
    _stage_to_blob(blob_account_url, container, filename, data)

    logging.info("Analyzing with Content Understanding")
    result = _analyze(cu_endpoint, analyzer_id, data)
    markdown = _extract_markdown(result)

    logging.info("Pushing to AI Search across the vWAN")
    doc_id = filename.replace(".", "_").replace(" ", "_")
    search_result = _push_to_search(search_endpoint, search_index, doc_id, filename, markdown)

    return func.HttpResponse(
        body=str(
            {
                "file": filename,
                "bytes": len(data),
                "markdownChars": len(markdown),
                "search": search_result,
            }
        ),
        status_code=200,
        mimetype="application/json",
    )
