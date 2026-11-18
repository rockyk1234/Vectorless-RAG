"""Tests for the Cognito ID token verifier. Signs real RS256 tokens with a
throwaway key (needs the `cryptography` package locally; skipped if missing)."""

import base64
import io
import json
import os
import sys
import unittest
import urllib.error
from unittest.mock import patch

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tree"))

import auth  # noqa: E402

try:
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.asymmetric import padding, rsa
except ImportError:  # pragma: no cover
    rsa = None

ISS = "https://cognito-idp.us-east-1.amazonaws.com/us-east-1_TEST"
CID = "client123"


def _b64(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


@unittest.skipIf(rsa is None, "cryptography not installed")
class TestVerify(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        cls.other = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        pub = cls.key.public_key().public_numbers()
        cls.keys = {"k1": {"kid": "k1", "kty": "RSA",
                           "n": _b64(pub.n.to_bytes(256, "big")), "e": _b64(pub.e.to_bytes(3, "big"))}}

    def token(self, claims=None, header=None, signer=None):
        h = {"alg": "RS256", "kid": "k1", **(header or {})}
        c = {"iss": ISS, "aud": CID, "token_use": "id", "exp": 2_000_000_000, "email": "a@b.c", **(claims or {})}
        si = f"{_b64(json.dumps(h).encode())}.{_b64(json.dumps(c).encode())}"
        sig = (signer or self.key).sign(si.encode(), padding.PKCS1v15(), hashes.SHA256())
        return f"{si}.{_b64(sig)}"

    def check(self, tok, now=1_900_000_000):
        return auth.verify(tok, keys=self.keys, issuer=ISS, client_id=CID, now=now)

    def test_valid_token(self):
        self.assertEqual(self.check(self.token())["email"], "a@b.c")

    def test_rejections(self):
        cases = {
            "wrong key": self.token(signer=self.other),
            "issuer": self.token({"iss": "https://evil"}),
            "audience": self.token({"aud": "other"}),
            "access token": self.token({"token_use": "access"}),
            "expired": self.token({"exp": 1_000}),
            "alg none": self.token(header={"alg": "none"}),
            "unknown kid": self.token(header={"kid": "zz"}),
            "garbage": "abc",
            "empty": "",
        }
        for name, tok in cases.items():
            with self.subTest(name), self.assertRaises(auth.AuthError):
                self.check(tok)

    def test_tampered_payload_rejected(self):
        h, _, s = self.token().split(".")
        forged = _b64(json.dumps({"iss": ISS, "aud": CID, "token_use": "id", "exp": 2_000_000_000,
                                  "email": "admin@x"}).encode())
        with self.assertRaises(auth.AuthError):
            self.check(f"{h}.{forged}.{s}")


class TestStandardLibraryPaths(unittest.TestCase):
    def token(self, claims=None, header=None):
        h = {"alg": "RS256", "kid": "k1", **(header or {})}
        c = {"iss": ISS, "aud": CID, "token_use": "id", "exp": 2_000_000_000,
             **(claims or {})}
        return f"{_b64(json.dumps(h).encode())}.{_b64(json.dumps(c).encode())}.{_b64(b'sig')}"

    @patch("auth._rs256_ok", return_value=True)
    def test_claim_checks_without_optional_crypto_package(self, _signature):
        keys = {"k1": {"kid": "k1", "kty": "RSA", "n": "AQ", "e": "Aw"}}
        claims = auth.verify(self.token(), keys=keys, issuer=ISS, client_id=CID,
                             now=1_900_000_000)
        self.assertEqual(claims["aud"], CID)
        for changed in (
            {"iss": "https://invalid.example"},
            {"aud": "different-client"},
            {"token_use": "access"},
            {"exp": 1_000},
        ):
            with self.subTest(changed=changed), self.assertRaises(auth.AuthError):
                auth.verify(self.token(changed), keys=keys, issuer=ISS, client_id=CID,
                            now=1_900_000_000)

    def test_load_jwks_filters_non_signing_and_incomplete_keys(self):
        document = {"keys": [
            {"kid": "valid", "kty": "RSA", "use": "sig", "alg": "RS256",
             "n": "AQ", "e": "Aw"},
            {"kid": "encrypt", "kty": "RSA", "use": "enc", "alg": "RS256",
             "n": "AQ", "e": "Aw"},
            {"kid": "wrong-alg", "kty": "RSA", "use": "sig", "alg": "RS512",
             "n": "AQ", "e": "Aw"},
            {"kid": "missing-modulus", "kty": "RSA", "use": "sig", "alg": "RS256",
             "e": "Aw"},
        ]}
        response = io.BytesIO(json.dumps(document).encode())
        with patch("auth.urllib.request.urlopen", return_value=response) as get:
            keys = auth.load_jwks(issuer=ISS)
        self.assertEqual(list(keys), ["valid"])
        get.assert_called_once()

    @patch("auth.urllib.request.urlopen")
    def test_load_jwks_rejects_untrusted_issuer_before_fetch(self, get):
        with self.assertRaisesRegex(auth.AuthError, "invalid issuer"):
            auth.load_jwks(issuer="https://cognito-idp.us-east-1.amazonaws.com.evil.example/pool")
        get.assert_not_called()

    def test_load_jwks_retries_transient_failure(self):
        document = {"keys": [
            {"kid": "valid", "kty": "RSA", "use": "sig", "alg": "RS256",
             "n": "AQ", "e": "Aw"},
        ]}
        response = io.BytesIO(json.dumps(document).encode())
        with patch("auth.urllib.request.urlopen", side_effect=[
                urllib.error.URLError("temporary"), response]) as get, \
                patch("auth.time.sleep") as sleep:
            keys = auth.load_jwks(issuer=ISS)
        self.assertEqual(list(keys), ["valid"])
        self.assertEqual(get.call_count, 2)
        sleep.assert_called_once()

    def test_load_jwks_raises_distinct_unavailable_error(self):
        with patch("auth.urllib.request.urlopen",
                   side_effect=urllib.error.URLError("offline")) as get, \
                patch("auth.time.sleep") as sleep:
            with self.assertRaises(auth.JwksUnavailable):
                auth.load_jwks(issuer=ISS)
        self.assertEqual(get.call_count, 3)
        self.assertEqual(sleep.call_count, 2)


if __name__ == "__main__":
    unittest.main()
