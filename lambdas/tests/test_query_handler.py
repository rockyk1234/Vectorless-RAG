"""Offline tests for the v3 HTTP handler and privacy-preserving audit record."""

import base64
import contextlib
import hashlib
import io
import json
import os
import sys
import types
import unittest
from unittest.mock import patch

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tree"))

import query_handler  # noqa: E402


class TestAuditLogging(unittest.TestCase):
    def test_audit_log_hashes_question_and_quotes(self):
        question = "What confidential value applies?"
        quote = "The confidential value is 25 Nm."
        result = {
            "status": "ANSWERED",
            "answer": "25 Nm",
            "citations": [{"node_id": "S_1", "pages": [4], "quote": quote}],
            "audit": {"manual_id": "PART#X", "route": []},
        }
        query_handler._DEPS = (object(), object(), object(), object())
        output = io.StringIO()
        with patch("query_handler.runtime.answer", return_value=result), \
                contextlib.redirect_stdout(output):
            returned = query_handler.ask("ORDER-1", question)

        record = json.loads(output.getvalue())
        self.assertEqual(returned, result)
        self.assertNotIn(question, output.getvalue())
        self.assertNotIn(quote, output.getvalue())
        self.assertEqual(record["question_sha256"], hashlib.sha256(question.encode()).hexdigest())
        self.assertEqual(record["citations"][0]["quote_sha256"],
                         hashlib.sha256(quote.encode()).hexdigest())
        self.assertEqual(record["citations"][0]["quote_length"], len(quote))


class TestBrowserPresignedLinks(unittest.TestCase):
    class S3:
        def __init__(self):
            self.calls = []

        def generate_presigned_url(self, operation, **kwargs):
            self.calls.append((operation, kwargs))
            return "https://example.invalid/signed"

    def setUp(self):
        self.s3 = self.S3()
        query_handler._S3 = self.s3
        self.environment = patch.dict(os.environ, {
            "AWS_ACCOUNT_ID": "123456789012",
            "DOCUMENT_BUCKET": "trusted-documents",
        })
        self.environment.start()

    def tearDown(self):
        self.environment.stop()
        query_handler._S3 = None

    def test_figure_url_uses_browser_compatible_signed_headers(self):
        result = {
            "citations": [{"figures": [{"key": "figures/test.png"}]}],
        }
        query_handler._sign_figures(result)
        params = self.s3.calls[0][1]["Params"]
        self.assertEqual(params, {"Bucket": "trusted-documents", "Key": "figures/test.png"})

    def test_manual_url_uses_browser_compatible_signed_headers(self):
        result = {
            "audit": {"source": "s3://trusted-documents/manuals/PART/r1.pdf"},
        }
        query_handler._sign_manual(result)
        params = self.s3.calls[0][1]["Params"]
        self.assertNotIn("ExpectedBucketOwner", params)
        self.assertEqual(params["Bucket"], "trusted-documents")
        self.assertEqual(params["Key"], "manuals/PART/r1.pdf")


class TestS3ClientConfiguration(unittest.TestCase):
    def test_client_uses_regional_virtual_host_addressing(self):
        captured = {}

        class FakeConfig:
            def __init__(self, **options):
                self.options = options

        fake_boto3 = types.ModuleType("boto3")
        fake_botocore = types.ModuleType("botocore")
        fake_botocore_config = types.ModuleType("botocore.config")
        fake_botocore_config.Config = FakeConfig

        def client(service, **options):
            captured["service"] = service
            captured.update(options)
            return object()

        fake_boto3.client = client
        query_handler._S3 = None
        try:
            with patch.dict(sys.modules, {
                    "boto3": fake_boto3,
                    "botocore": fake_botocore,
                    "botocore.config": fake_botocore_config,
            }), patch.dict(os.environ, {"AWS_REGION_NAME": "us-west-2"}):
                query_handler._client()
        finally:
            query_handler._S3 = None

        self.assertEqual(captured["service"], "s3")
        self.assertEqual(captured["region_name"], "us-west-2")
        self.assertEqual(captured["config"].options, {
            "signature_version": "s3v4",
            "s3": {"addressing_style": "virtual"},
        })


class TestHttpResilience(unittest.TestCase):
    EVENT = {
        "rawPath": "/api/ask",
        "requestContext": {"http": {"method": "POST"}},
        "body": json.dumps({"order_id": "ORDER-1", "question": "Torque?"}),
        "isBase64Encoded": False,
    }

    def test_request_body_accepts_plain_and_base64_json(self):
        payload = {"order_id": "ORDER-1", "question": "Torque?"}
        plain = {"body": json.dumps(payload), "isBase64Encoded": False}
        encoded = {
            "body": base64.b64encode(json.dumps(payload).encode()).decode(),
            "isBase64Encoded": True,
        }
        self.assertEqual(query_handler._request_body(plain), payload)
        self.assertEqual(query_handler._request_body(encoded), payload)

    def test_request_body_rejects_invalid_or_oversized_content(self):
        self.assertIsNone(query_handler._request_body({"body": "not-json"}))
        self.assertIsNone(query_handler._request_body({
            "body": "x" * (query_handler.MAX_REQUEST_BODY_BYTES + 1),
        }))

    def test_auth_dependency_failure_returns_503_without_login_redirect(self):
        with patch("query_handler._authorized",
                   side_effect=query_handler.AuthenticationUnavailable("jwks offline")):
            response = query_handler.lambda_handler(self.EVENT, None)
        self.assertEqual(response["statusCode"], 503)
        self.assertEqual(
            json.loads(response["body"])["code"],
            "AUTHENTICATION_UNAVAILABLE",
        )

    def test_aws_dependency_failure_returns_safe_503(self):
        class AwsFailure(Exception):
            response = {"Error": {"Code": "ThrottlingException"}}

        output = io.StringIO()
        with patch("query_handler._authorized", return_value={"sub": "user"}), \
                patch("query_handler.ask", side_effect=AwsFailure("sensitive detail")), \
                contextlib.redirect_stdout(output):
            response = query_handler.lambda_handler(self.EVENT, None)
        self.assertEqual(response["statusCode"], 503)
        self.assertEqual(json.loads(response["body"])["code"], "DEPENDENCY_UNAVAILABLE")
        self.assertNotIn("sensitive detail", response["body"])

    def test_unexpected_failure_returns_safe_500(self):
        with patch("query_handler._authorized", return_value={"sub": "user"}), \
                patch("query_handler.ask", side_effect=RuntimeError("sensitive detail")):
            response = query_handler.lambda_handler(self.EVENT, None)
        self.assertEqual(response["statusCode"], 500)
        self.assertEqual(json.loads(response["body"])["code"], "INTERNAL_ERROR")
        self.assertNotIn("sensitive detail", response["body"])


if __name__ == "__main__":
    unittest.main()
