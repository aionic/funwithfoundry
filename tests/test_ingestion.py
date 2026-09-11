"""Cloud-free ingestion regression tests; all network/SDK calls are mocked."""

import hashlib
import inspect
import json
import os
import sys
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

import jwt
import requests
from azure.core.exceptions import HttpResponseError, ResourceExistsError, ServiceRequestError, ServiceResponseError
from cryptography.hazmat.primitives.asymmetric import rsa

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src" / "ingest_func"))
import authorization

http_binding = MagicMock()
http_binding.FunctionApp.return_value.route.side_effect = lambda **kwargs: lambda handler: handler
http_binding.HttpResponse.side_effect = lambda body, status_code, mimetype, headers: SimpleNamespace(
    status_code=status_code, mimetype=mimetype, headers=headers, get_body=lambda: body.encode("utf-8")
)
with patch.dict(sys.modules, {"azure.functions": http_binding}):
    import function_app

TENANT = "11111111-1111-4111-8111-111111111111"
AUDIENCE = "22222222-2222-4222-8222-222222222222"
CALLER = "33333333-3333-4333-8333-333333333333"
PRINCIPAL = "44444444-4444-4444-8444-444444444444"
AUTH_ENV = {
    "INGEST_TENANT_ID": TENANT,
    "INGEST_AUDIENCE": AUDIENCE,
    "INGEST_AUTHORIZED_CALLERS": json.dumps({CALLER: PRINCIPAL}),
}


class AuthorizationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)

    def setUp(self):
        self.environment = patch.dict(os.environ, AUTH_ENV, clear=True)
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.keys = patch.object(authorization, "_keys")
        self.mock_keys = self.keys.start()
        self.addCleanup(self.keys.stop)
        self.mock_keys.return_value.get_signing_key_from_jwt.return_value = SimpleNamespace(
            key=self.private_key.public_key()
        )

    def token(self, **overrides):
        now = int(time.time())
        claims = {
            "iss": f"https://login.microsoftonline.com/{TENANT}/v2.0",
            "aud": AUDIENCE, "tid": TENANT, "azp": CALLER, "oid": PRINCIPAL,
            "sub": PRINCIPAL, "ver": "2.0", "idtyp": "app",
            "roles": ["Ingestion.Invoke"], "iat": now, "nbf": now, "exp": now + 300,
        }
        claims.update(overrides)
        return "Bearer " + jwt.encode(claims, self.private_key, algorithm="RS256", headers={"kid": "local-test"})

    def test_signed_app_token_is_authorized(self):
        authorization.authorize(self.token())

    def test_missing_or_malformed_bearer_never_fetches_keys(self):
        for value in ("", "Basic abc", "Bearer", "Bearer a b", "Bearer " + "a" * 16384):
            with self.subTest(value=value[:30]), self.assertRaises(authorization.IngestionError) as caught:
                authorization.authorize(value)
            self.assertEqual(caught.exception.status, 401)
        self.mock_keys.assert_not_called()

    def test_wrong_audience_issuer_expiry_and_signature_are_rejected(self):
        for changes in ({"aud": CALLER}, {"iss": "https://attacker.invalid"}, {"exp": 1}, {"nbf": int(time.time()) + 600}):
            with self.subTest(changes=changes), self.assertRaises(authorization.IngestionError) as caught:
                authorization.authorize(self.token(**changes))
            self.assertEqual(caught.exception.status, 401)
        other_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        self.mock_keys.return_value.get_signing_key_from_jwt.return_value = SimpleNamespace(key=other_key.public_key())
        with self.assertRaises(authorization.IngestionError) as caught:
            authorization.authorize(self.token())
        self.assertEqual(caught.exception.status, 401)

    def test_caller_role_tenant_and_delegated_tokens_are_rejected(self):
        for changes in ({"azp": AUDIENCE}, {"oid": CALLER}, {"roles": []}, {"roles": "Ingestion.Invoke"}, {"tid": CALLER}, {"scp": "read"}, {"idtyp": "user"}):
            with self.subTest(changes=changes), self.assertRaises(authorization.IngestionError) as caught:
                authorization.authorize(self.token(**changes))
            self.assertEqual(caught.exception.status, 403)

    def test_missing_allowlist_fails_closed(self):
        os.environ["INGEST_AUTHORIZED_CALLERS"] = "{}"
        with self.assertRaises(authorization.IngestionError) as caught:
            authorization.authorize(self.token())
        self.assertEqual(caught.exception.status, 503)
        self.mock_keys.assert_not_called()

    def test_wrong_algorithm_missing_claim_and_identity_outage(self):
        with self.assertRaises(authorization.IngestionError) as caught:
            authorization.authorize("Bearer " + jwt.encode({"aud": AUDIENCE}, "local-test-only", algorithm="HS256"))
        self.assertEqual(caught.exception.status, 401)
        self.mock_keys.assert_not_called()
        self.mock_keys.return_value.get_signing_key_from_jwt.side_effect = jwt.PyJWKClientConnectionError("raw-secret")
        with self.assertRaises(authorization.IngestionError) as caught:
            authorization.authorize(self.token())
        self.assertEqual(caught.exception.code, "identity_unavailable")
        self.assertEqual(caught.exception.status, 503)
        self.mock_keys.return_value.get_signing_key_from_jwt.side_effect = None
        encoded = self.token().split()[1]
        claims = jwt.decode(encoded, options={"verify_signature": False})
        del claims["idtyp"]
        encoded = jwt.encode(claims, self.private_key, algorithm="RS256", headers={"kid": "local-test"})
        with self.assertRaises(authorization.IngestionError) as caught:
            authorization.authorize("Bearer " + encoded)
        self.assertEqual(caught.exception.status, 401)


class IngestionTests(unittest.TestCase):
    def setUp(self):
        environment = {
            **AUTH_ENV,
            "INGEST_FIXTURE_ENABLED": "true",
            "STAGING_BLOB_ENDPOINT": "https://staging.blob.core.windows.net",
            "SP_SITE_HOSTNAME": "tenant.sharepoint.com",
            "SP_SITE_PATH": "/sites/Example",
            "SP_FILE_PATH": "Documents/Example.pdf",
        }
        for target, replacement in (
            (patch.dict(os.environ, environment, clear=True), "environment"),
            (patch.object(function_app, "authorize"), "authorize"),
            (patch.object(function_app, "_credential"), "credential"),
            (patch.object(function_app, "BlobServiceClient"), "blob"),
            (patch.object(function_app.requests, "request", side_effect=AssertionError("Unexpected HTTP call")), "http"),
            (patch.object(function_app.time, "sleep"), "sleep"),
            (patch("socket.socket.connect", side_effect=AssertionError("Live network is prohibited")), "socket"),
        ):
            setattr(self, replacement, target.start())
            self.addCleanup(target.stop)
        self.credential.get_token.return_value = SimpleNamespace(token="secret-upstream-token")
        self.source_id = function_app._source_id("fixture", "funwithfoundry", "/synthetic", "accelerator-v1.pdf")
        self.storage = self.blob.return_value.__enter__.return_value
        self.upload = MagicMock()
        self.storage.get_blob_client.side_effect = lambda container, name: SimpleNamespace(
            url=f"https://staging.blob.core.windows.net/{container}/{name}", upload_blob=self.upload,
        )

    def request(self, body=None, raw=None, headers=None, params=None):
        return SimpleNamespace(
            method="POST", params=params or {},
            headers=requests.structures.CaseInsensitiveDict({"Content-Type": "application/json", "Authorization": "Bearer test", **(headers or {})}),
            get_body=lambda: raw if raw is not None else json.dumps(body).encode("utf-8"),
        )

    def response(self, body=None, status=200, headers=None, data=None):
        response = requests.Response()
        response.status_code = status
        response.headers.update(headers or {})
        response._content = data if data is not None else json.dumps(body).encode("utf-8")
        response._content_consumed = True
        return response

    def fixture_request(self):
        return self.request({"mode": "fixture", "fixtureId": "accelerator-v1"})

    def test_unauthorized_and_spoofed_headers_never_reach_services(self):
        self.authorize.side_effect = authorization.authorize
        response = function_app.ingest(self.request(raw=b"not json", headers={
            "Authorization": "", "X-MS-CLIENT-PRINCIPAL": "spoofed", "X-MS-CLIENT-PRINCIPAL-ID": PRINCIPAL,
        }))
        self.assertEqual(response.status_code, 401)
        self.http.assert_not_called()
        self.blob.assert_not_called()
        self.credential.get_token.assert_not_called()
        self.assertEqual(response.headers["WWW-Authenticate"], "Bearer")

    def test_strict_input_rejects_overrides_unknown_fixture_and_arbitrary_content(self):
        invalid = [[], None, 1, "fixture", {}, {"mode": "fixture"},
                   {"mode": "fixture", "fixtureId": "other"},
                   {"mode": "fixture", "fixtureId": "accelerator-v1", "content": "payload"},
                   *({"mode": "sharepoint", key: value} for key, value in (
                       ("siteHostname", "evil.sharepoint.com"), ("sitePath", "/sites/Elsewhere"),
                       ("filePath", "Documents/Other.pdf"), ("url", "https://evil.invalid"), ("bytes", "eA=="))) ]
        for body in invalid:
            with self.subTest(body=body):
                self.assertEqual(function_app.ingest(self.request(body)).status_code, 400)
        for raw in (b"{", b'{"mode":"sharepoint","mode":"sharepoint"}'):
            self.assertEqual(function_app.ingest(self.request(raw=raw)).status_code, 400)
        self.assertEqual(function_app.ingest(self.request(raw=b" " * 4097)).status_code, 413)
        self.assertEqual(function_app.ingest(self.request({}, headers={"Content-Type": "text/plain"})).status_code, 415)
        self.assertEqual(function_app.ingest(self.request({"mode": "sharepoint"}, params={"filePath": "other"})).status_code, 400)
        self.http.assert_not_called()
        self.blob.assert_not_called()

    def test_fixture_stages_raw_bytes_with_202_and_no_http_calls(self):
        result = function_app.ingest(self.fixture_request())
        body = json.loads(result.get_body())
        self.assertEqual(result.status_code, 202)
        self.assertEqual(set(body), {
            "status", "source_id", "content_hash", "source_url", "blob_url", "blob_name", "request_id", "bytes", "mode",
        })
        self.assertEqual(body["request_id"], result.headers["X-Request-ID"])
        self.assertEqual(result.headers["Cache-Control"], "no-store")
        self.assertEqual(body["status"], "staged")
        self.assertEqual(body["mode"], "fixture")
        self.assertEqual(body["source_id"], self.source_id)
        self.assertEqual(body["source_url"], "urn:funwithfoundry:fixture:accelerator-v1")
        self.assertEqual(body["blob_name"], f"native/{self.source_id}/source.pdf")
        self.assertEqual(body["blob_url"], f"https://staging.blob.core.windows.net/spo-staging/{body['blob_name']}")
        self.storage.get_blob_client.assert_called_once_with("spo-staging", body["blob_name"])
        self.upload.assert_called_once()
        staged = self.upload.call_args
        data = staged.args[0]
        self.assertTrue(data.startswith(b"%PDF-1.4"))
        self.assertEqual(data, function_app.fixture_pdf())
        self.assertEqual(body["bytes"], len(data))
        self.assertEqual(body["content_hash"], hashlib.sha256(data).hexdigest())
        self.assertTrue(staged.kwargs["overwrite"])
        self.assertEqual(staged.kwargs["content_settings"].content_type, "application/pdf")
        self.assertEqual(staged.kwargs["metadata"], {
            "source_id": self.source_id, "content_hash": body["content_hash"], "doc_url": body["source_url"],
        })
        self.assertEqual(staged.kwargs["client_request_id"], body["request_id"])
        self.assertEqual(staged.kwargs["timeout"], 30)
        self.storage.create_container.assert_called_once_with("spo-staging", timeout=30, client_request_id=body["request_id"])
        self.assertEqual(self.blob.call_args.kwargs["retry_total"], 0)
        self.assertEqual(self.blob.call_args.kwargs["connection_timeout"], 5)
        self.assertEqual(self.blob.call_args.kwargs["read_timeout"], 30)
        self.assertIs(self.blob.call_args.kwargs["credential"], self.credential)
        self.assertNotIn("secret-upstream-token", result.get_body().decode())
        self.http.assert_not_called()
        self.credential.get_token.assert_not_called()

    def test_custom_analysis_and_indexing_code_is_absent(self):
        source = inspect.getsource(function_app)
        for removed in ("_analyze", "_extract_markdown", "_push_to_search", "COGNITIVE_SCOPE", "SEARCH_SCOPE",
                        "CU_API_VERSION", "SEARCH_API_VERSION", "CU_ENDPOINT", "CU_ANALYZER_ID", "SEARCH_ENDPOINT", "SEARCH_INDEX",
                        "contentunderstanding", "analyzeBinary", "/docs/index", "indexers", "MAX_CONTENT_BYTES"):
            with self.subTest(removed=removed):
                self.assertNotIn(removed, source)

    def test_fixture_requires_explicit_enablement(self):
        del os.environ["INGEST_FIXTURE_ENABLED"]
        self.assertEqual(function_app.ingest(self.fixture_request()).status_code, 403)
        self.blob.assert_not_called()

    def test_ids_include_site_path_and_avoid_filename_collisions(self):
        source = function_app._source_id
        paths = [("/sites/One", "Folder/a.b.pdf"), ("/sites/Two", "Folder/a.b.pdf"),
                 ("/sites/One", "Elsewhere/a.b.pdf"), ("/sites/One", "Folder/a_b.pdf")]
        ids = {source("sharepoint", "tenant.sharepoint.com", site, path) for site, path in paths}
        self.assertEqual(len(ids), 4)
        self.assertTrue(all(len(value) == 64 for value in ids))
        self.assertEqual(source("sharepoint", "TENANT.sharepoint.com", "/sites/ONE", "Folder/a.b.pdf"), source("sharepoint", "tenant.sharepoint.com", "/sites/One", "folder/a.b.pdf"))
        self.assertEqual(function_app.fixture_pdf(), function_app.fixture_pdf())
        self.assertNotEqual(source("sharepoint", "tenant.sharepoint.com", "/sites/One", "Stra\u00dfe.pdf"), source("sharepoint", "tenant.sharepoint.com", "/sites/One", "Strasse.pdf"))

    def test_reingestion_same_and_changed_content_overwrites_stable_target(self):
        original = function_app.fixture_pdf()
        contents = [original, original, original + b"\n% changed revision\n"]
        results = []
        for data in contents:
            with patch.object(function_app, "fixture_pdf", return_value=data):
                response = function_app.ingest(self.fixture_request())
            self.assertEqual(response.status_code, 202)
            results.append(json.loads(response.get_body()))
        self.assertEqual(len({body["source_id"] for body in results}), 1)
        self.assertEqual(len({body["blob_name"] for body in results}), 1)
        self.assertEqual(len({body["blob_url"] for body in results}), 1)
        self.assertEqual(len({body["request_id"] for body in results}), 3)
        self.assertEqual(results[0]["content_hash"], results[1]["content_hash"])
        self.assertNotEqual(results[0]["content_hash"], results[2]["content_hash"])
        self.assertEqual(self.upload.call_count, 3)
        for data, result, staged, target in zip(contents, results, self.upload.call_args_list, self.storage.get_blob_client.call_args_list):
            self.assertEqual(target.args, ("spo-staging", f"native/{self.source_id}/source.pdf"))
            self.assertEqual(staged.args[0], data)
            self.assertTrue(staged.kwargs["overwrite"])
            self.assertEqual(staged.kwargs["metadata"]["content_hash"], hashlib.sha256(data).hexdigest())
            self.assertEqual(staged.kwargs["metadata"]["source_id"], self.source_id)
            self.assertEqual(staged.kwargs["metadata"]["doc_url"], result["source_url"])
        self.http.assert_not_called()

    def test_staging_failures_never_report_success_or_leak_upstream_errors(self):
        forbidden = HttpResponseError("raw-secret")
        forbidden.status_code = 403
        conflict = ResourceExistsError("raw-secret")
        conflict.error_code = "BlobAlreadyExists"
        cases = [(forbidden, "staging_http_error", 1), (conflict, "staging_conflict", 1),
                 (ServiceRequestError("raw-secret"), "staging_unavailable", 3),
                 (ServiceResponseError("raw-secret"), "staging_unavailable", 3)]
        for error, code, attempts in cases:
            with self.subTest(code=code, error_type=type(error)):
                self.upload.reset_mock(side_effect=True)
                self.upload.side_effect = error
                result = function_app.ingest(self.fixture_request())
                body = json.loads(result.get_body())
                self.assertEqual(result.status_code, 502)
                self.assertEqual(body["error"], {"code": code, "stage": "staging"})
                self.assertEqual(set(body), {"request_id", "error"})
                self.assertEqual(self.upload.call_count, attempts)
                self.assertNotIn("raw-secret", result.get_body().decode())
        self.http.assert_not_called()

    def test_container_failure_prevents_upload(self):
        failure = HttpResponseError("raw-secret")
        failure.status_code = 403
        self.storage.create_container.side_effect = failure
        result = function_app.ingest(self.fixture_request())
        self.assertEqual(result.status_code, 502)
        self.assertEqual(json.loads(result.get_body())["error"], {"code": "staging_http_error", "stage": "staging"})
        self.upload.assert_not_called()
        self.http.assert_not_called()

    def test_existing_container_still_overwrites_blob(self):
        conflict = ResourceExistsError("raw-secret")
        conflict.error_code = "ContainerAlreadyExists"
        self.storage.create_container.side_effect = conflict
        result = function_app.ingest(self.fixture_request())
        self.assertEqual(result.status_code, 202)
        self.upload.assert_called_once()
        self.assertTrue(self.upload.call_args.kwargs["overwrite"])

    def test_blob_retries_are_bounded_and_reuse_overwrite_payload(self):
        transient = HttpResponseError("raw-secret")
        transient.status_code = 503
        transient.response = SimpleNamespace(headers={"Retry-After": "9999"})
        self.upload.side_effect = [transient, ServiceResponseError("raw-secret"), None]
        result = function_app.ingest(self.fixture_request())
        self.assertEqual(result.status_code, 202)
        self.assertEqual(self.upload.call_count, 3)
        self.assertEqual([call.args[0] for call in self.sleep.call_args_list], [10, 2])
        self.assertTrue(all(call == self.upload.call_args for call in self.upload.call_args_list))
        self.assertTrue(self.upload.call_args.kwargs["overwrite"])
        self.upload.reset_mock(side_effect=True)
        self.upload.side_effect = transient
        result = function_app.ingest(self.fixture_request())
        self.assertEqual(result.status_code, 502)
        self.assertEqual(self.upload.call_count, 3)
        self.assertEqual(json.loads(result.get_body())["error"]["code"], "staging_http_error")

    def test_sharepoint_oversize_shortcut_and_config_paths_fail_before_download(self):
        for metadata in ({"size": 10001, "file": {"mimeType": "application/pdf"}},
                         {"size": 50, "file": {"mimeType": "application/pdf"}, "remoteItem": {"id": "other-site"}}):
            self.http.reset_mock(side_effect=True)
            self.http.side_effect = [self.response({"id": "tenant,site,web"}), self.response(metadata)]
            with self.assertRaises(authorization.IngestionError):
                function_app._fetch_sharepoint_file(10000, "id")
            self.assertEqual(self.http.call_count, 2)
        for path in ("//sites/Example", "Documents/../file.pdf", "Documents//file.pdf", "Documents/%2E%2E/file.pdf", "Documents/file.pdf?query=1"):
            with self.subTest(path=path), self.assertRaises(authorization.IngestionError):
                function_app._configured_path(path)

    def test_retry_dates_and_get_transport_failures_are_bounded(self):
        self.assertEqual(function_app._retry_delay({"Retry-After": "Wed, 01 Jan 2100 00:00:00 GMT"}, 0), 10)
        self.assertEqual(function_app._retry_delay({"Retry-After": "Wed, 01 Jan 2000 00:00:00 GMT"}, 0), 0)
        self.assertEqual(function_app._retry_delay({"Retry-After": "invalid"}, 1), 2)
        self.http.side_effect = requests.Timeout("raw-secret")
        with self.assertRaises(authorization.IngestionError) as caught:
            function_app._request("GET", "https://graph.microsoft.com/v1.0/sites/example", "graph", "id")
        self.assertEqual(caught.exception.code, "graph_unavailable")
        self.assertEqual(self.http.call_count, 3)

    def test_fixture_pdf_offsets_and_stream_length_are_valid(self):
        data = function_app.fixture_pdf()
        xref_offset = int(data.rsplit(b"startxref\n", 1)[1].splitlines()[0])
        xref = data[xref_offset:].splitlines()
        self.assertEqual(xref[:2], [b"xref", b"0 6"])
        for number, entry in enumerate(xref[3:8], 1):
            offset = int(entry[:10])
            self.assertTrue(data[offset:].startswith(f"{number} 0 obj\n".encode()))
        stream = data.split(b"stream\n", 1)[1].split(b"endstream", 1)[0]
        declared_length = int(data.split(b"/Length ", 1)[1].split(b" ", 1)[0])
        self.assertEqual(len(stream), declared_length)

    def test_bounded_retries_honor_capped_retry_after_and_never_retry_terminal_4xx(self):
        self.http.side_effect = [self.response(status=429, headers={"Retry-After": "9999"}), self.response(status=503), self.response({"ok": True})]
        function_app._request("GET", "https://example.test", "test", "correlation")
        self.assertEqual(self.http.call_count, 3)
        self.assertEqual([call.args[0] for call in self.sleep.call_args_list], [10, 2])
        for status in (400, 401, 403, 404, 409, 413):
            self.http.reset_mock(side_effect=True)
            self.http.side_effect = [self.response(status=status)]
            with self.assertRaises(authorization.IngestionError):
                function_app._request("GET", "https://example.test", "test", "correlation")
            self.assertEqual(self.http.call_count, 1)
        self.http.reset_mock(side_effect=True)
        self.http.side_effect = [self.response(status=503) for _attempt in range(3)]
        with self.assertRaises(authorization.IngestionError):
            function_app._request("GET", "https://example.test", "test", "correlation")
        self.assertEqual(self.http.call_count, 3)

    def test_blob_call_accepts_only_expected_container_conflict(self):
        error = ResourceExistsError("raw-secret")
        error.error_code = "ContainerAlreadyExists"
        operation = MagicMock(side_effect=error)
        function_app._blob_call(operation, "ContainerAlreadyExists")
        self.assertEqual(operation.call_count, 1)
        error = ResourceExistsError("raw-secret")
        error.error_code = "LeaseAlreadyPresent"
        with self.assertRaises(authorization.IngestionError):
            function_app._blob_call(MagicMock(side_effect=error), "ContainerAlreadyExists")
        failure = HttpResponseError("raw-secret")
        failure.status_code = 403
        operation = MagicMock(side_effect=failure)
        with self.assertRaises(authorization.IngestionError):
            function_app._blob_call(operation, "ContainerAlreadyExists")
        self.assertEqual(operation.call_count, 1)

    def test_document_type_size_and_stream_limits(self):
        for data, title, media, limit in ((b"hello", "x.pdf", "application/pdf", 100), (b"%PDF-", "x.exe", "application/pdf", 100),
                                          (b"%PDF-", "x.pdf", "text/plain", 100), (b"", "x.pdf", "application/pdf", 100), (b"%PDF-xx", "x.pdf", "application/pdf", 5)):
            with self.subTest(title=title, data=data), self.assertRaises(authorization.IngestionError):
                function_app._validate_document(data, title, media, limit)
        for headers in ({}, {"Content-Length": "1000"}):
            with self.assertRaises(authorization.IngestionError):
                function_app._read_bytes(self.response(data=b"123456", headers=headers), 5, "document_too_large")

    def test_document_text_utf8_is_allowed(self):
        for data in (b"Architecture\tUTF-8\r\n", b"\xef\xbb\xbfArchitecture\r\n", "R\u00e9sum\u00e9 \u6771\u4eac\n".encode("utf-8")):
            for media_type in ("text/plain", "text/plain; charset=utf-8", 'Text/Plain; Charset="UTF8"', "application/octet-stream"):
                with self.subTest(data=data, media_type=media_type):
                    function_app._validate_document(data, "architecture.TXT", media_type, len(data))

    def test_document_text_rejects_binary_invalid_utf8_and_controls(self):
        invalid = [b"\x89PNG\r\n\x1a\n", b"\xff\xd8\xff", b"PK\x03\x04", b"text\x00binary",
                   b"\xff", b"\xc0\xaf", b"\xe2\x82", b"\xed\xa0\x80", b"\xef\xbb\xbf\xff",
                   "Architecture".encode("utf-16"), "Architecture".encode("utf-16-le")]
        invalid.extend(("before" + chr(control) + "after").encode("utf-8")
                       for control in (*range(32), *range(127, 160)) if control not in (9, 10, 13))
        for data in invalid:
            for media_type in ("text/plain", "application/octet-stream"):
                with self.subTest(data=data, media_type=media_type), self.assertRaises(authorization.IngestionError) as caught:
                    function_app._validate_document(data, "architecture.txt", media_type, 1000)
                self.assertEqual(caught.exception.code, "invalid_document_type")
                self.assertEqual(caught.exception.status, 415)

    def test_document_text_empty_and_raw_byte_size_guards(self):
        for data in (b"", b"\xef\xbb\xbf", b" \t\r\n", b"\xef\xbb\xbf \t\r\n", "\u00a0\u2003".encode("utf-8")):
            with self.subTest(data=data), self.assertRaises(authorization.IngestionError) as caught:
                function_app._validate_document(data, "architecture.txt", "text/plain", 100)
            self.assertEqual(caught.exception.code, "empty_document")
            self.assertEqual(caught.exception.status, 422)
        for data in (b"abcdef", b"\xef\xbb\xbfabc", "\u6771\u4eac".encode("utf-8"), b"\x00" * 6):
            with self.subTest(data=data), self.assertRaises(authorization.IngestionError) as caught:
                function_app._validate_document(data, "architecture.txt", "text/plain", 5)
            self.assertEqual(caught.exception.code, "document_too_large")
            self.assertEqual(caught.exception.status, 413)

    def test_document_text_mime_allowlist_is_exact(self):
        for media_type in ("", None, {}, [], "text/html", "text/html; charset=utf-8", "text/markdown", "application/pdf",
                           "text/plainx", "text/plain; charset=utf-16", "text/plain; charset=ascii",
                           "text/plain; charset=iso-8859-1", "text/plain; charset=utf-8; charset=utf-16",
                           "text/plain; charset=utf-8; charset=utf-8", "text/plain; charset=utf-8; name=file.txt",
                           "text/plain;", "text/plain; charset=", 'text/plain; charset="utf-8',
                           "text/plain; charset=utf-8junk", "text/plain, text/html", "text/plain\r\n",
                           "text/plain;\ncharset=utf-8", "application/octet-stream; charset=utf-8"):
            with self.subTest(media_type=media_type), self.assertRaises(authorization.IngestionError) as caught:
                function_app._validate_document(b"Architecture", "architecture.txt", media_type, 100)
            self.assertEqual(caught.exception.code, "unsupported_document_type")
            self.assertEqual(caught.exception.status, 415)

    def test_binary_signature_checks_and_unsupported_extensions_remain_enforced(self):
        for data, title, media_type in ((b"%PDF-1.4", "file.pdf", "application/pdf"),
                                        (b"\x89PNG\r\n\x1a\n", "file.png", "image/png"),
                                        (b"\xff\xd8\xff", "file.jpg", "image/jpeg"),
                                        (b"\xff\xd8\xff", "file.jpeg", "image/jpeg")):
            for declared_type in (media_type, "application/octet-stream"):
                with self.subTest(title=title, declared_type=declared_type):
                    function_app._validate_document(data, title, declared_type, 100)
                    with self.assertRaises(authorization.IngestionError) as caught:
                        function_app._validate_document(b"plain text", title, declared_type, 100)
                    self.assertEqual(caught.exception.code, "invalid_document_type")
        for extension in ("md", "html", "docx", "csv", "rtf", "exe"):
            with self.subTest(extension=extension), self.assertRaises(authorization.IngestionError) as caught:
                function_app._validate_document(b"Architecture", f"file.{extension}", "application/octet-stream", 100)
            self.assertEqual(caught.exception.status, 415)

    def test_sharepoint_text_stages_unchanged_bytes_hash_metadata_and_exact_urls(self):
        graph_root = "https://graph.microsoft.com/v1.0/sites/"
        paths = [("/", "Documents/funwithfoundry-architecture-note.txt", "", "Documents/funwithfoundry-architecture-note.txt"),
                 ("/sites/R\u00e9sum\u00e9 Team", "Documents/Project Notes/R\u00e9sum\u00e9.TXT",
                  ":/sites/R%C3%A9sum%C3%A9%20Team", "Documents/Project%20Notes/R%C3%A9sum%C3%A9.TXT")]
        for site_path, file_path, site_suffix, encoded_file_path in paths:
            os.environ.update({"SP_SITE_PATH": site_path, "SP_FILE_PATH": file_path})
            item_url = f"{graph_root}tenant,site,web/drive/root:/{encoded_file_path}"
            web_url = f"https://tenant.sharepoint.com/{encoded_file_path}"
            download_url = "https://tenant.sharepoint.com/download?temporary=secret"
            source_id = function_app._source_id("sharepoint", "tenant.sharepoint.com", site_path, file_path)
            for media_type in ("text/plain", "text/plain; charset=utf-8", ' Text/Plain ; Charset = "UTF8" ', "APPLICATION/OCTET-STREAM"):
                for redirect in (False, True):
                    with self.subTest(site_path=site_path, media_type=media_type, redirect=redirect):
                        data = (b"\xef\xbb\xbf" if redirect else b"") + "Architecture\tR\u00e9sum\u00e9 \u6771\u4eac\r\n  ".encode("utf-8")
                        content_hash = hashlib.sha256(data).hexdigest()
                        self.upload.reset_mock()
                        self.credential.get_token.reset_mock()
                        results = []
                        for _attempt in range(2):
                            self.http.reset_mock(side_effect=True)
                            responses = [self.response({"id": "tenant,site,web"}),
                                         self.response({"size": len(data), "file": {"mimeType": media_type}, "webUrl": web_url})]
                            if redirect:
                                responses.append(self.response(status=302, headers={"Location": download_url}))
                            responses.append(self.response(data=data))
                            self.http.side_effect = responses
                            result = function_app.ingest(self.request({"mode": "sharepoint"}))
                            self.assertEqual(result.status_code, 202, result.get_body())
                            body = json.loads(result.get_body())
                            results.append(body)
                            self.assertEqual(body["status"], "staged")
                            self.assertEqual(body["mode"], "sharepoint")
                            self.assertEqual(body["source_id"], source_id)
                            self.assertEqual(body["source_url"], web_url)
                            self.assertEqual(body["content_hash"], content_hash)
                            self.assertEqual(body["bytes"], len(data))
                            self.assertEqual(body["blob_name"], f"native/{source_id}/source.txt")
                            self.assertEqual(body["blob_url"], f"https://staging.blob.core.windows.net/spo-staging/native/{source_id}/source.txt")
                            expected_urls = [f"{graph_root}tenant.sharepoint.com{site_suffix}", item_url, f"{item_url}:/content"]
                            if redirect:
                                expected_urls.append(download_url)
                            self.assertEqual([call.args for call in self.http.call_args_list], [("GET", url) for url in expected_urls])
                            for position, call in enumerate(self.http.call_args_list):
                                self.assertFalse(call.kwargs["allow_redirects"])
                                self.assertTrue(call.kwargs["stream"])
                                self.assertEqual(call.kwargs["timeout"], (5, 30))
                                self.assertEqual(call.kwargs["headers"]["x-ms-client-request-id"], body["request_id"])
                                if position < 3:
                                    self.assertEqual(call.kwargs["headers"]["Authorization"], "Bearer secret-upstream-token")
                                else:
                                    self.assertNotIn("Authorization", call.kwargs["headers"])
                            self.assertNotIn("secret", result.get_body().decode())
                        self.assertEqual(self.upload.call_count, 2)
                        for staged, body in zip(self.upload.call_args_list, results):
                            self.assertEqual(staged.args[0], data)
                            self.assertTrue(staged.kwargs["overwrite"])
                            self.assertEqual(staged.kwargs["content_settings"].content_type, "text/plain")
                            self.assertEqual(staged.kwargs["metadata"], {"source_id": source_id, "content_hash": content_hash, "doc_url": web_url})
                            self.assertEqual(staged.kwargs["client_request_id"], body["request_id"])
                        self.assertEqual(results[0]["content_hash"], results[1]["content_hash"])
                        self.assertEqual(results[0]["blob_name"], results[1]["blob_name"])
                        self.assertEqual(self.credential.get_token.call_count, 2)
                        self.assertTrue(all(call.args == (function_app.GRAPH_SCOPE,) for call in self.credential.get_token.call_args_list))
        self.socket.assert_not_called()

    def test_sharepoint_text_rejects_unsafe_content_before_staging(self):
        os.environ["SP_FILE_PATH"] = "Documents/architecture.txt"
        for data, status, code in ((b"bad\x00text", 415, "invalid_document_type"),
                                   (b"bad\xfftext", 415, "invalid_document_type"),
                                   (b"bad\x1btext", 415, "invalid_document_type"),
                                   (b"", 422, "empty_document"), (b"\xef\xbb\xbf \t\r\n", 422, "empty_document")):
            with self.subTest(data=data):
                self.http.reset_mock(side_effect=True)
                self.http.side_effect = [self.response({"id": "tenant,site,web"}),
                                         self.response({"size": max(1, len(data)), "file": {"mimeType": "application/octet-stream"},
                                                        "webUrl": "https://tenant.sharepoint.com/Documents/architecture.txt"}),
                                         self.response(data=data)]
                result = function_app.ingest(self.request({"mode": "sharepoint"}))
                self.assertEqual(result.status_code, status)
                self.assertEqual(json.loads(result.get_body())["error"], {"code": code, "stage": "source"})
                self.assertEqual(self.http.call_count, 3)
        self.blob.assert_not_called()

    def test_sharepoint_text_rejects_mime_mismatches_before_download(self):
        os.environ["SP_FILE_PATH"] = "Documents/architecture.txt"
        for media_type in ("text/html", "text/html; charset=utf-8", "text/markdown", "application/pdf", None,
                           "text/plain; charset=utf-16", "text/plain; charset=utf-8; charset=ascii"):
            with self.subTest(media_type=media_type):
                self.http.reset_mock(side_effect=True)
                self.http.side_effect = [self.response({"id": "tenant,site,web"}),
                                         self.response({"size": 10, "file": {"mimeType": media_type},
                                                        "webUrl": "https://tenant.sharepoint.com/Documents/architecture.txt"})]
                result = function_app.ingest(self.request({"mode": "sharepoint"}))
                self.assertEqual(result.status_code, 415)
                self.assertEqual(json.loads(result.get_body())["error"], {"code": "unsupported_document_type", "stage": "source"})
                self.assertEqual(self.http.call_count, 2)
        self.blob.assert_not_called()

    def test_sharepoint_unsupported_extensions_fail_before_graph(self):
        for extension in ("md", "html", "docx", "csv", "rtf", "exe"):
            with self.subTest(extension=extension):
                os.environ["SP_FILE_PATH"] = f"Documents/architecture.{extension}"
                result = function_app.ingest(self.request({"mode": "sharepoint"}))
                self.assertEqual(result.status_code, 415)
        self.http.assert_not_called()
        self.credential.get_token.assert_not_called()
        self.blob.assert_not_called()

    def test_sharepoint_text_size_limits_apply_to_metadata_and_download(self):
        os.environ.update({"SP_FILE_PATH": "Documents/architecture.txt", "INGEST_MAX_BYTES": "5"})
        for size, headers, calls in ((6, {}, 2), (5, {"Content-Length": "6"}, 3), (5, {}, 3)):
            with self.subTest(size=size, headers=headers):
                self.http.reset_mock(side_effect=True)
                self.http.side_effect = [self.response({"id": "tenant,site,web"}),
                                         self.response({"size": size, "file": {"mimeType": "text/plain"},
                                                        "webUrl": "https://tenant.sharepoint.com/Documents/architecture.txt"}),
                                         self.response(data=b"abcdef", headers=headers)]
                result = function_app.ingest(self.request({"mode": "sharepoint"}))
                self.assertEqual(result.status_code, 413)
                self.assertEqual(json.loads(result.get_body())["error"], {"code": "document_too_large", "stage": "source"})
                self.assertEqual(self.http.call_count, calls)
        self.blob.assert_not_called()

    def test_sharepoint_text_download_redirect_remains_same_host_only(self):
        os.environ["SP_FILE_PATH"] = "Documents/architecture.txt"
        for location in ("https://other.sharepoint.com/file.txt", "https://tenant.sharepoint.com.evil.invalid/file.txt",
                         "https://graph.microsoft.com/file.txt", "http://tenant.sharepoint.com/file.txt",
                         "https://user:secret@tenant.sharepoint.com/file.txt", "https://tenant.sharepoint.com:8443/file.txt",
                         "https://tenant.sharepoint.com/file.txt#secret", "//tenant.sharepoint.com/file.txt", "/file.txt"):
            with self.subTest(location=location):
                self.http.reset_mock(side_effect=True)
                self.http.side_effect = [self.response({"id": "tenant,site,web"}),
                                         self.response({"size": 10, "file": {"mimeType": "text/plain"},
                                                        "webUrl": "https://tenant.sharepoint.com/Documents/architecture.txt"}),
                                         self.response(status=302, headers={"Location": location})]
                result = function_app.ingest(self.request({"mode": "sharepoint"}))
                self.assertEqual(result.status_code, 502)
                self.assertEqual(json.loads(result.get_body())["error"], {"code": "untrusted_source_url", "stage": "source"})
                self.assertEqual(self.http.call_count, 3)
                self.assertNotIn("secret", result.get_body().decode())
        self.blob.assert_not_called()

    def test_sharepoint_root_site_uses_canonical_graph_url(self):
        os.environ["SP_SITE_PATH"] = "/"
        data = function_app.fixture_pdf()
        web_url = "https://tenant.sharepoint.com/Documents/Example.pdf"
        self.http.side_effect = [self.response({"id": "tenant,site,web"}),
                                 self.response({"size": len(data), "file": {"mimeType": "application/pdf"}, "webUrl": web_url}),
                                 self.response(data=data)]
        function_app._fetch_sharepoint_file(10000, "request-id")
        self.assertEqual(self.http.call_args_list[0].args[1], "https://graph.microsoft.com/v1.0/sites/tenant.sharepoint.com")
        self.assertEqual(self.http.call_count, 3)

    def test_sharepoint_is_scoped_and_redirect_does_not_forward_bearer(self):
        data = function_app.fixture_pdf()
        web_url = "https://tenant.sharepoint.com/sites/Example/Shared%20Documents/Documents/Example.pdf"
        self.http.side_effect = [self.response({"id": "tenant,site,web"}), self.response({"size": len(data), "file": {"mimeType": "application/pdf"}, "webUrl": web_url}),
                                 self.response(status=302, headers={"Location": "https://tenant.sharepoint.com/download?temporary=secret"}), self.response(data=data)]
        source = function_app._fetch_sharepoint_file(10000, "request-id")
        self.assertEqual(source[3], web_url)
        self.assertIn("/sites/tenant.sharepoint.com:/sites/Example", self.http.call_args_list[0].args[1])
        self.assertIn("Documents/Example.pdf", self.http.call_args_list[1].args[1])
        self.assertNotIn("Authorization", self.http.call_args_list[3].kwargs["headers"])
        self.assertFalse(self.http.call_args_list[3].kwargs["allow_redirects"])
        for url in ("http://tenant.sharepoint.com/x", "https://evil.invalid/x", "https://tenant.sharepoint.com@evil.invalid/x", "https://tenant.sharepoint.com:8443/x"):
            with self.subTest(url=url), self.assertRaises(authorization.IngestionError):
                function_app._scoped_url(url, "tenant.sharepoint.com")

    def test_sharepoint_stages_raw_bytes_with_ascii_unicode_provenance(self):
        os.environ["SP_FILE_PATH"] = "Documents/R\u00e9sum\u00e9 \u6771\u4eac.PDF"
        os.environ["STAGING_CONTAINER"] = "native-staging"
        data = function_app.fixture_pdf()
        prefix = "https://tenant.sharepoint.com/sites/Example/Shared%20Documents/Documents/"
        for filename in ("R\u00e9sum\u00e9%20\u6771\u4eac.PDF", "R%C3%A9sum%C3%A9%20%E6%9D%B1%E4%BA%AC.PDF"):
            with self.subTest(filename=filename):
                web_url = prefix + filename
                self.http.reset_mock(side_effect=True)
                self.http.side_effect = [self.response({"id": "tenant,site,web"}),
                                         self.response({"size": len(data), "file": {"mimeType": "application/octet-stream"}, "webUrl": web_url}),
                                         self.response(status=302, headers={"Location": "https://tenant.sharepoint.com/download?temporary=secret"}),
                                         self.response(data=data)]
                result = function_app.ingest(self.request({"mode": "sharepoint"}))
                self.assertEqual(result.status_code, 202)
                body = json.loads(result.get_body())
                source_id = function_app._source_id("sharepoint", "tenant.sharepoint.com", "/sites/Example", os.environ["SP_FILE_PATH"])
                self.assertEqual(body["status"], "staged")
                self.assertEqual(body["mode"], "sharepoint")
                self.assertEqual(body["source_id"], source_id)
                self.assertEqual(body["source_url"], web_url)
                self.assertEqual(body["blob_name"], f"native/{source_id}/source.pdf")
                self.assertEqual(body["blob_url"], f"https://staging.blob.core.windows.net/native-staging/{body['blob_name']}")
                staged = self.upload.call_args
                self.assertEqual(staged.args[0], data)
                self.assertTrue(staged.kwargs["overwrite"])
                self.assertEqual(staged.kwargs["content_settings"].content_type, "application/pdf")
                metadata = staged.kwargs["metadata"]
                self.assertEqual(metadata, {
                    "source_id": source_id, "content_hash": hashlib.sha256(data).hexdigest(),
                    "doc_url": prefix + "R%C3%A9sum%C3%A9%20%E6%9D%B1%E4%BA%AC.PDF",
                })
                for value in metadata.values():
                    self.assertTrue(value.isascii())
                    self.assertNotIn("secret", value)
                self.assertEqual(self.http.call_count, 4)
                self.assertEqual([call.args[0] for call in self.http.call_args_list], ["GET"] * 4)
                self.assertNotIn("Authorization", self.http.call_args_list[-1].kwargs["headers"])
                self.assertTrue(all(call.kwargs["headers"]["x-ms-client-request-id"] == body["request_id"] for call in self.http.call_args_list))
                self.assertNotIn("secret", result.get_body().decode())
        self.assertTrue(all(call.args[0] == function_app.GRAPH_SCOPE for call in self.credential.get_token.call_args_list))

    def test_sharepoint_rejects_secret_bearing_or_untrusted_provenance_before_staging(self):
        for url in ("https://tenant.sharepoint.com/file.pdf?token=secret", "https://tenant.sharepoint.com/file.pdf#secret",
                    "https://user:secret@tenant.sharepoint.com/file.pdf", "https://evil.invalid/file.pdf"):
            with self.subTest(url=url):
                self.http.reset_mock(side_effect=True)
                self.http.side_effect = [self.response({"id": "tenant,site,web"}),
                                         self.response({"size": 100, "file": {"mimeType": "application/pdf"}, "webUrl": url})]
                result = function_app.ingest(self.request({"mode": "sharepoint"}))
                self.assertEqual(result.status_code, 502)
                self.assertEqual(json.loads(result.get_body())["error"]["stage"], "source")
                self.assertEqual(self.http.call_count, 2)
                self.assertNotIn("secret", result.get_body().decode())
        self.blob.assert_not_called()

    def test_invalid_fixture_bytes_never_reach_staging(self):
        for data, status in ((b"", 422), (b"not a pdf", 415), (b"%PDF-" + b"x" * 100, 413)):
            with self.subTest(status=status), patch.object(function_app, "fixture_pdf", return_value=data), patch.dict(os.environ, {"INGEST_MAX_BYTES": "100"}):
                result = function_app.ingest(self.fixture_request())
                self.assertEqual(result.status_code, status)
                self.assertEqual(json.loads(result.get_body())["error"]["stage"], "source")
        self.blob.assert_not_called()
        self.http.assert_not_called()

    def test_unexpected_exceptions_do_not_leak_content_or_tokens(self):
        self.upload.side_effect = RuntimeError("raw-document-content secret-upstream-token")
        with self.assertLogs(level="ERROR") as logged:
            result = function_app.ingest(self.fixture_request())
        self.assertEqual(result.status_code, 500)
        rendered = result.get_body().decode() + " ".join(logged.output)
        self.assertNotIn("raw-document-content", rendered)
        self.assertNotIn("secret-upstream-token", rendered)
        self.assertIn("request_id", rendered)


if __name__ == "__main__":
    unittest.main()
