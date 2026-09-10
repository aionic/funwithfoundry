"""Cloud-free ingestion regression tests; all network/SDK calls are mocked."""

import hashlib
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
from azure.core.exceptions import HttpResponseError, ResourceExistsError
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
            "CU_ENDPOINT": "https://cu.example.test",
            "SEARCH_ENDPOINT": "https://search.example.test",
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

    def success_responses(self, markdown='Project Cedar says "hello".\nRetention: 30 days.'):
        return [
            self.response({"result": {"contents": [{"markdown": markdown}]}}),
            self.response({"value": [{"key": self.source_id, "status": True, "statusCode": 201}]}),
        ]

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

    def test_fixture_routes_through_actual_pipeline_and_serializes_valid_json(self):
        self.http.side_effect = self.success_responses()
        result = function_app.ingest(self.fixture_request())
        body = json.loads(result.get_body())
        self.assertEqual(result.status_code, 200)
        self.assertEqual(body["request_id"], result.headers["X-Request-ID"])
        self.assertEqual(body["status"], "indexed")
        self.assertEqual(body["document_id"], self.source_id)
        blob_client = self.blob.return_value.__enter__.return_value
        staged = blob_client.get_blob_client.return_value.upload_blob.call_args
        data = staged.args[0]
        self.assertTrue(data.startswith(b"%PDF-1.4"))
        self.assertFalse(staged.kwargs["overwrite"])
        cu_call, search_call = self.http.call_args_list
        self.assertIn(":analyzeBinary?", cu_call.args[1])
        self.assertEqual(cu_call.kwargs["data"], data)
        document = search_call.kwargs["json"]["value"][0]
        self.assertEqual(set(document), {"@search.action", "id", "title", "content", "source_url", "source_id", "content_hash"})
        self.assertEqual(document["source_url"], "urn:funwithfoundry:fixture:accelerator-v1")
        self.assertEqual(document["content_hash"], hashlib.sha256(data).hexdigest())
        self.assertEqual(json.loads(json.dumps(document))["content"], 'Project Cedar says "hello".\nRetention: 30 days.')
        self.assertEqual(cu_call.kwargs["headers"]["x-ms-client-request-id"], body["request_id"])
        self.assertNotIn("secret-upstream-token", result.get_body().decode())
        self.assertEqual([call.args[0] for call in self.http.call_args_list], ["POST", "POST"])

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

    def test_search_partial_or_malformed_results_fail_closed(self):
        cases = [[], [{"key": self.source_id, "status": False, "statusCode": 503, "errorMessage": "raw-secret"}],
                 [{"key": "wrong", "status": True, "statusCode": 201}],
                 [{"key": self.source_id, "status": "true", "statusCode": 201}],
                 [{"key": self.source_id, "status": True, "statusCode": 400}]]
        for items in cases:
            with self.subTest(items=items):
                self.http.side_effect = [self.success_responses()[0], self.response({"value": items}, status=207)]
                result = function_app.ingest(self.fixture_request())
                self.assertEqual(result.status_code, 502)
                self.assertEqual(json.loads(result.get_body())["error"]["stage"], "indexing")
                self.assertNotIn("raw-secret", result.get_body().decode())

    def test_empty_extraction_prevents_search(self):
        self.http.side_effect = [self.success_responses(markdown=" \n ")[0]]
        self.assertEqual(function_app.ingest(self.fixture_request()).status_code, 422)
        self.assertEqual(self.http.call_count, 1)

    def test_malformed_failed_and_oversized_extraction_fail_closed(self):
        for body in ({"result": None}, {"result": {"contents": {}}},
                     {"status": "Failed", "result": {"contents": [{"markdown": "partial"}]}},
                     {"result": {"contents": [{"markdown": "x" * (function_app.MAX_CONTENT_BYTES + 1)}]}}):
            with self.subTest(body_type=type(body)), self.assertRaises(authorization.IngestionError):
                function_app._extract_markdown(body)

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

    def test_retry_dates_and_post_transport_ambiguity(self):
        self.assertEqual(function_app._retry_delay({"Retry-After": "Wed, 01 Jan 2100 00:00:00 GMT"}, 0), 10)
        self.assertEqual(function_app._retry_delay({"Retry-After": "Wed, 01 Jan 2000 00:00:00 GMT"}, 0), 0)
        self.assertEqual(function_app._retry_delay({"Retry-After": "invalid"}, 1), 2)
        self.http.side_effect = requests.Timeout("raw-secret")
        with self.assertRaises(authorization.IngestionError):
            function_app._request("POST", "https://cu.example.test", "cu", "id", data=b"fixture")
        self.assertEqual(self.http.call_count, 1)

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

    def test_polling_has_finite_attempt_limit(self):
        self.http.side_effect = [self.response(status=202, headers={"Operation-Location": "https://cu.example.test/contentunderstanding/operations/1"})] + [self.response({"status": "Running"}) for _attempt in range(40)]
        with self.assertRaises(authorization.IngestionError) as caught:
            function_app._analyze(b"%PDF-", "id")
        self.assertEqual(caught.exception.status, 504)
        self.assertEqual(self.http.call_count, 41)

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

    def test_upload_accepts_only_specific_already_exists_codes(self):
        for code, expected in (("ContainerAlreadyExists", "ContainerAlreadyExists"), ("BlobAlreadyExists", "BlobAlreadyExists")):
            error = ResourceExistsError("raw-secret")
            error.error_code = code
            operation = MagicMock(side_effect=error)
            function_app._blob_call(operation, expected)
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

    def test_cu_operation_polling_checks_status_and_host(self):
        self.http.side_effect = [self.response(status=202, headers={"Operation-Location": "https://cu.example.test/contentunderstanding/operations/1", "Retry-After": "1"}),
                                 self.response({"status": "Running"}), self.response({"status": "Succeeded", "result": {"contents": [{"markdown": "ok"}]}})]
        self.assertEqual(function_app._extract_markdown(function_app._analyze(b"%PDF-", "id")), "ok")
        for status in ("Failed", "Canceled", "Unknown"):
            self.http.side_effect = [self.response(status=202, headers={"Operation-Location": "https://cu.example.test/contentunderstanding/operations/1"}), self.response({"status": status})]
            with self.assertRaises(authorization.IngestionError):
                function_app._analyze(b"%PDF-", "id")
        self.http.side_effect = [self.response(status=202, headers={"Operation-Location": "https://evil.invalid/operations/1"})]
        with self.assertRaises(authorization.IngestionError):
            function_app._analyze(b"%PDF-", "id")

    def test_unexpected_exceptions_do_not_leak_content_or_tokens(self):
        self.http.side_effect = RuntimeError("raw-document-content secret-upstream-token")
        with self.assertLogs(level="ERROR") as logged:
            result = function_app.ingest(self.fixture_request())
        self.assertEqual(result.status_code, 500)
        rendered = result.get_body().decode() + " ".join(logged.output)
        self.assertNotIn("raw-document-content", rendered)
        self.assertNotIn("secret-upstream-token", rendered)
        self.assertIn("request_id", rendered)


if __name__ == "__main__":
    unittest.main()
