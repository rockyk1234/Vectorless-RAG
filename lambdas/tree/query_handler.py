"""Regional v3 tree query Lambda.

Direct invoke: {"order_id": "...", "question": "...", "unit_id": "..." (optional)}
Function URL through CloudFront OAC:
  POST /api/ask with a JSON body -> verified answer
  GET /api/ask/orders -> demo orders with their unit options

CloudFront is the only principal allowed to invoke the Function URL. The Lambda
also validates the Cognito ID token on every HTTP request. Every answer is
logged as one JSON line for the audit trail.
"""

import base64
import binascii
import hashlib
import json
import os

import adapters
import auth
import runtime

_KEYS = None
_CLIENT_ID = None
_DEPS = None
_S3 = None
FIGURE_URL_TTL = 900  # Fifteen minutes limits exposure of document links.
MAX_QUESTION_LENGTH = 1000  # Bound request size and model input.
MAX_IDENTIFIER_LENGTH = 64  # Match the accepted order and unit identifier shape.
MAX_REQUEST_BODY_BYTES = 16_384  # Reject oversized JSON before parsing.


class AuthenticationUnavailable(Exception):
    """Authentication dependencies are unavailable, rather than credentials invalid."""


def _configured_client_id():
    """Load the expected Cognito audience from encrypted regional metadata."""
    global _CLIENT_ID
    if _CLIENT_ID is None:
        import boto3
        response = boto3.client(
            "dynamodb",
            region_name=os.environ["AWS_REGION_NAME"],
        ).get_item(
            TableName=os.environ["METADATA_TABLE"],
            Key={"pk": {"S": "CONFIG"}, "sk": {"S": "COGNITO_CLIENT"}},
            ConsistentRead=True,
        )
        _CLIENT_ID = response.get("Item", {}).get("value", {}).get("S")
    return _CLIENT_ID


def _authorized(event):
    """Verify the Cognito ID token forwarded separately from OAC signing."""
    global _KEYS
    pool = os.environ.get("USER_POOL_ID")
    issuer = os.environ.get("COGNITO_ISSUER", "").rstrip("/")
    if not pool or not issuer:
        raise AuthenticationUnavailable("authentication configuration missing")
    try:
        client_id = _configured_client_id()
    except Exception as error:
        raise AuthenticationUnavailable("authentication metadata unavailable") from error
    if not client_id:
        raise AuthenticationUnavailable("authentication metadata missing")

    headers = {key.lower(): value for key, value in (event.get("headers") or {}).items()}
    token = headers.get("x-id-token", "")
    try:
        if _KEYS is None:
            _KEYS = auth.load_jwks(issuer=issuer)
        return auth.verify(token, keys=_KEYS, client_id=client_id, issuer=issuer)
    except auth.JwksUnavailable as error:
        raise AuthenticationUnavailable("signing keys unavailable") from error
    except auth.AuthError as error:
        if str(error) == "unknown key":
            try:
                refreshed_keys = auth.load_jwks(issuer=issuer)
                claims = auth.verify(
                    token,
                    keys=refreshed_keys,
                    client_id=client_id,
                    issuer=issuer,
                )
                _KEYS = refreshed_keys
                return claims
            except auth.JwksUnavailable as refresh_error:
                raise AuthenticationUnavailable("signing-key refresh unavailable") from refresh_error
            except auth.AuthError as retry_error:
                error = retry_error
        print(json.dumps({"auth": "rejected", "reason": str(error)}), flush=True)
        return None


def _deps():
    global _DEPS
    if _DEPS is None:
        _DEPS = (
            adapters.S3DynamoStore(),
            adapters.BedrockLLM(),
            adapters.MockOrders(),
            adapters.MockCompat(),
        )
    return _DEPS


def _client():
    global _S3
    if _S3 is None:
        import boto3
        from botocore.config import Config
        # A presigned URL cannot follow the global S3 endpoint redirect because
        # the regional hostname must match the hostname covered by SigV4.
        _S3 = boto3.client(
            "s3",
            region_name=os.environ["AWS_REGION_NAME"],
            config=Config(
                signature_version="s3v4",
                s3={"addressing_style": "virtual"},
            ),
        )
    return _S3


def _sign_figures(result):
    """Turn stored figure keys into short-lived presigned URLs for the browser."""
    bucket = os.environ.get("DOCUMENT_BUCKET")
    citations = result.get("citations") or []
    if not bucket or not any(citation.get("figures") for citation in citations):
        return result
    s3 = _client()
    for citation in citations:
        for figure in citation.get("figures", []):
            if figure.get("key", "").startswith("figures/"):
                params = {"Bucket": bucket, "Key": figure["key"]}
                # Browser image requests cannot add x-amz-expected-bucket-owner.
                # The bucket name comes only from the trusted deployment environment.
                figure["url"] = s3.generate_presigned_url(
                    "get_object",
                    Params=params,
                    ExpiresIn=FIGURE_URL_TTL,
                )
    return result


def _sign_manual(result):
    """Add a short-lived link to the exact PDF revision that produced the answer."""
    audit = result.get("audit") or {}
    source = audit.get("source") or ""
    bucket = os.environ.get("DOCUMENT_BUCKET")
    prefix = f"s3://{bucket}/"
    if not bucket or not source.startswith(prefix):
        return result
    key = source[len(prefix):]
    if not key.startswith(("manuals/", "units/")) or not key.endswith(".pdf"):
        return result
    params = {
        "Bucket": bucket,
        "Key": key,
        "ResponseContentType": "application/pdf",
        "ResponseContentDisposition": "inline",
    }
    # Browser navigation cannot add x-amz-expected-bucket-owner. The bucket
    # name comes only from the trusted deployment environment.
    audit["manual_url"] = _client().generate_presigned_url(
        "get_object",
        ExpiresIn=FIGURE_URL_TTL,
        Params=params,
    )
    return result


def _http(status, body):
    return {
        "statusCode": status,
        "headers": {"content-type": "application/json", "cache-control": "no-store"},
        "body": json.dumps(body, default=str),
    }


def _request_body(event):
    """Return a bounded JSON object from a Lambda Function URL event."""
    raw_body = event.get("body") or ""
    try:
        if event.get("isBase64Encoded"):
            body = base64.b64decode(raw_body, validate=True)
        else:
            body = raw_body.encode("utf-8")
        if len(body) > MAX_REQUEST_BODY_BYTES:
            return None
        value = json.loads(body.decode("utf-8"))
    except (binascii.Error, UnicodeDecodeError, json.JSONDecodeError, ValueError):
        return None
    return value if isinstance(value, dict) else None


def _request_error_message():
    return (
        f"order_id and question (max {MAX_QUESTION_LENGTH} chars) are required; "
        f"identifiers must not exceed {MAX_IDENTIFIER_LENGTH} chars"
    )


def _dependency_error_response(error):
    """Log dependency detail and return a stable response without leaking internals."""
    response = getattr(error, "response", {})
    aws_code = response.get("Error", {}).get("Code") if isinstance(response, dict) else None
    error_module = type(error).__module__
    is_aws_error = bool(aws_code) or error_module.startswith(("botocore.", "boto3."))
    print(json.dumps({
        "request": "failed",
        "error_type": type(error).__name__,
        "aws_error_code": aws_code,
    }), flush=True)
    if is_aws_error:
        return _http(503, {
            "code": "DEPENDENCY_UNAVAILABLE",
            "message": "A required AWS service is temporarily unavailable. Retry later.",
        })
    return _http(500, {
        "code": "INTERNAL_ERROR",
        "message": "The request could not be completed.",
    })


def ask(order_id, question, unit_id=None):
    order_id = str(order_id or "").strip()
    question = str(question or "").strip()
    unit_id = str(unit_id).strip() if unit_id else None
    if (not order_id or not question
            or len(question) > MAX_QUESTION_LENGTH
            or len(order_id) > MAX_IDENTIFIER_LENGTH
            or (unit_id and len(unit_id) > MAX_IDENTIFIER_LENGTH)):
        return None
    store, llm, orders, compat = _deps()
    result = runtime.answer(
        order_id,
        question,
        orders=orders,
        store=store,
        llm=llm,
        compat=compat,
        unit_id=unit_id,
    )
    audit = result.get("audit") or {}
    citation_audit = [{
        "node_id": citation.get("node_id"),
        "pages": citation.get("pages"),
        "quote_sha256": hashlib.sha256(
            str(citation.get("quote") or "").encode("utf-8")
        ).hexdigest(),
        "quote_length": len(str(citation.get("quote") or "")),
    } for citation in (result.get("citations") or [])]
    print(json.dumps({
        "audit": True,
        "order_id": order_id,
        "question_sha256": hashlib.sha256(question.encode("utf-8")).hexdigest(),
        "question_length": len(question),
        "unit_requested": unit_id,
        "manual_id": audit.get("manual_id"),
        "unit": audit.get("unit"),
        "status": result["status"],
        "reason": result.get("reason"),
        "route": audit.get("route"),
        "citations": citation_audit,
    }, default=str), flush=True)
    return _sign_manual(_sign_figures(result))


def list_orders():
    _, _, orders, compat = _deps()
    return [
        {"order_id": order_id, **row, "unit_options": compat.units_for(row["part_id"])}
        for order_id, row in orders.mapping.items()
    ]


def lambda_handler(event, context):
    if "requestContext" not in event:  # Direct invocation.
        result = ask(event.get("order_id"), event.get("question"), event.get("unit_id"))
        return result or {"status": "BAD_REQUEST", "message": _request_error_message()}

    path = event.get("rawPath", "").rstrip("/")
    method = event.get("requestContext", {}).get("http", {}).get("method", "GET")

    try:
        user = _authorized(event)
    except AuthenticationUnavailable as error:
        print(json.dumps({"auth": "unavailable", "reason": str(error)}), flush=True)
        return _http(503, {
            "code": "AUTHENTICATION_UNAVAILABLE",
            "message": "Authentication is temporarily unavailable. Retry later.",
        })
    if not user:
        return _http(401, {"message": "Sign in required"})

    if path.endswith("/api/ask/orders"):
        if method != "GET":
            return _http(405, {"message": "GET required"})
        return _http(200, {"orders": list_orders()})

    if path.endswith("/api/ask"):
        if method != "POST":
            return _http(405, {"message": "POST required"})
        request = _request_body(event)
        if request is None:
            return _http(400, {"message": "A valid JSON request body is required"})
        try:
            result = ask(
                request.get("order_id"),
                request.get("question"),
                request.get("unit_id"),
            )
        except Exception as error:
            return _dependency_error_response(error)
        if result is None:
            return _http(400, {"message": _request_error_message()})
        return _http(200, result)

    return _http(404, {"message": "not found"})
