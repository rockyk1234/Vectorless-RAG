"""Verify Cognito ID tokens with Python's standard library.

The v3 query Lambda runs outside a VPC and loads the user pool's public JWKS
from its regional Cognito endpoint. Keys are cached by the handler and refreshed
when Cognito rotates to an unknown key id.

Checks: RS256 signature against a known key id, issuer, audience (app client),
token_use == "id", and expiry (with 60s clock skew). Anything else is rejected.
"""

import base64
import hashlib
import hmac
import json
import os
import random
import re
import time
import urllib.error
import urllib.request
from urllib.parse import urlparse

# DER prefix of the PKCS#1 v1.5 DigestInfo for SHA-256.
_SHA256_PREFIX = bytes.fromhex("3031300d060960864801650304020105000420")
_SKEW = 60
_JWKS_ATTEMPTS = 3
_JWKS_TIMEOUT_SECONDS = 5
_JWKS_BACKOFF_SECONDS = 0.25
_RANDOM = random.SystemRandom()


class AuthError(Exception):
    pass


class JwksUnavailable(AuthError):
    """The trusted Cognito signing-key endpoint could not be read."""


def _b64(data):
    return base64.urlsafe_b64decode(data + "=" * (-len(data) % 4))


def _int(data):
    return int.from_bytes(_b64(data), "big")


def _fetch_jwks(request):
    last_error = None
    for attempt in range(_JWKS_ATTEMPTS):
        try:
            # The HTTPS scheme and Cognito hostname are allowlisted before this call.
            with urllib.request.urlopen(  # nosec B310
                    request, timeout=_JWKS_TIMEOUT_SECONDS) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            last_error = error
            if error.code < 500 and error.code != 429:
                break
        except (urllib.error.URLError, TimeoutError, ConnectionError, OSError,
                json.JSONDecodeError, ValueError) as error:
            last_error = error

        if attempt + 1 < _JWKS_ATTEMPTS:
            exponential = _JWKS_BACKOFF_SECONDS * (2 ** attempt)
            time.sleep(exponential + _RANDOM.uniform(0, _JWKS_BACKOFF_SECONDS))

    raise JwksUnavailable("jwks unavailable") from last_error


def load_jwks(path=None, issuer=None):
    if path:
        with open(path) as file:
            document = json.load(file)
    else:
        issuer = (issuer or os.environ.get("COGNITO_ISSUER", "")).rstrip("/")
        parsed = urlparse(issuer)
        hostname = parsed.hostname or ""
        valid_host = re.fullmatch(
            r"cognito-idp\.[a-z0-9-]+\.amazonaws\.com(?:\.cn)?", hostname
        )
        if (parsed.scheme != "https" or not valid_host or not parsed.path.strip("/")
                or parsed.query or parsed.fragment):
            raise AuthError("invalid issuer")
        request = urllib.request.Request(
            f"{issuer}/.well-known/jwks.json",
            headers={"Accept": "application/json"},
        )
        document = _fetch_jwks(request)
    keys = document.get("keys", []) if isinstance(document, dict) else []
    return {
        key["kid"]: key
        for key in keys
        if key.get("kty") == "RSA"
        and key.get("use") in (None, "sig")
        and key.get("alg") in (None, "RS256")
        and all(isinstance(key.get(field), str) and key[field]
                for field in ("kid", "n", "e"))
    }


def _rs256_ok(signing_input, signature, key):
    n, e = _int(key["n"]), _int(key["e"])
    k = (n.bit_length() + 7) // 8
    if len(signature) != k:
        return False
    em = pow(int.from_bytes(signature, "big"), e, n).to_bytes(k, "big")
    t = _SHA256_PREFIX + hashlib.sha256(signing_input).digest()
    if k < len(t) + 11:
        return False
    expected = b"\x00\x01" + b"\xff" * (k - len(t) - 3) + b"\x00" + t
    return hmac.compare_digest(em, expected)


def verify(token, *, keys, issuer, client_id, now=None):
    """Return the claims of a valid ID token, else raise AuthError."""
    if not token or token.count(".") != 2 or len(token) > 8192:
        raise AuthError("malformed token")
    h64, p64, s64 = token.split(".")
    try:
        header, claims, sig = json.loads(_b64(h64)), json.loads(_b64(p64)), _b64(s64)
    except (ValueError, json.JSONDecodeError):
        raise AuthError("malformed token")
    if header.get("alg") != "RS256":
        raise AuthError("unsupported alg")
    key = keys.get(header.get("kid"))
    if not key:
        raise AuthError("unknown key")
    if not _rs256_ok(f"{h64}.{p64}".encode(), sig, key):
        raise AuthError("bad signature")
    now = now if now is not None else time.time()
    if claims.get("iss") != issuer:
        raise AuthError("bad issuer")
    if claims.get("aud") != client_id:
        raise AuthError("bad audience")
    if claims.get("token_use") != "id":
        raise AuthError("not an id token")
    if not isinstance(claims.get("exp"), (int, float)) or claims["exp"] < now - _SKEW:
        raise AuthError("expired")
    return claims
