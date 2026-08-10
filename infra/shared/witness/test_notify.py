"""Unit tests for witness notify helpers (no Azure Functions runtime required)."""

from __future__ import annotations

import json
import unittest
from unittest import mock

from notify import (
    SIGNATURE_HEADER,
    build_failover_payload,
    dispatch_github_failover,
    notify_failover_from_env,
    post_failover_webhook,
    sign_payload,
    verify_signature,
)


class PayloadTests(unittest.TestCase):
    def test_build_payload_shape(self) -> None:
        p = build_failover_payload(
            failures=3,
            threshold=3,
            primary_api_url="https://10.0.0.1:6443/readyz",
        )
        self.assertEqual(p["event"], "FAILOVER_CANDIDATE")
        self.assertEqual(p["consecutive_failures"], 3)
        self.assertEqual(p["threshold"], 3)
        self.assertEqual(p["recommended_action"], "promote_standby")
        self.assertEqual(p["schema_version"], 1)
        self.assertEqual(p["source"], "metal-mirage-witness")

    def test_hmac_roundtrip(self) -> None:
        body = b'{"event":"FAILOVER_CANDIDATE"}'
        secret = "test-secret"
        sig = sign_payload(body, secret)
        self.assertTrue(sig.startswith("sha256="))
        self.assertTrue(verify_signature(body, secret, sig))
        self.assertFalse(verify_signature(body, secret, "sha256=deadbeef"))
        self.assertFalse(verify_signature(body, "other", sig))


class PostTests(unittest.TestCase):
    def test_webhook_sends_signature(self) -> None:
        payload = build_failover_payload(failures=3, threshold=3)
        with mock.patch("notify._post_json", return_value=200) as post:
            status = post_failover_webhook(
                "https://example.test/hook",
                payload,
                hmac_secret="s3cret",
            )
        self.assertEqual(status, 200)
        args, _kwargs = post.call_args
        url, body, headers = args[0], args[1], args[2]
        self.assertEqual(url, "https://example.test/hook")
        self.assertEqual(headers["Content-Type"], "application/json")
        self.assertIn(SIGNATURE_HEADER, headers)
        self.assertTrue(verify_signature(body, "s3cret", headers[SIGNATURE_HEADER]))
        # Body must be stable for HMAC (sorted keys).
        self.assertEqual(body, json.dumps(payload, separators=(",", ":"), sort_keys=True).encode())

    def test_github_dispatch_url(self) -> None:
        payload = build_failover_payload(failures=3, threshold=3)
        with mock.patch("notify._post_json", return_value=204) as post:
            status = dispatch_github_failover("acme/metal-mirage", "ghp_test", payload)
        self.assertEqual(status, 204)
        args, _kwargs = post.call_args
        url, body, headers = args[0], args[1], args[2]
        self.assertEqual(url, "https://api.github.com/repos/acme/metal-mirage/dispatches")
        self.assertEqual(headers["Authorization"], "Bearer ghp_test")
        parsed = json.loads(body.decode())
        self.assertEqual(parsed["event_type"], "failover-candidate")
        self.assertEqual(parsed["client_payload"]["event"], "FAILOVER_CANDIDATE")

    def test_github_repo_validation(self) -> None:
        with self.assertRaises(ValueError):
            dispatch_github_failover("not-a-repo", "tok", {"event": "x"})

    def test_notify_from_env_both_paths(self) -> None:
        env = {
            "PRIMARY_API_URL": "https://api.example/readyz",
            "FAILOVER_WEBHOOK_URL": "https://hooks.example/x",
            "FAILOVER_WEBHOOK_HMAC_SECRET": "hmac",
            "FAILOVER_GITHUB_TOKEN": "tok",
            "FAILOVER_GITHUB_REPO": "acme/metal-mirage",
        }
        with mock.patch.dict("os.environ", env, clear=False):
            with mock.patch("notify.post_failover_webhook", return_value=200) as wh:
                with mock.patch("notify.dispatch_github_failover", return_value=204) as gh:
                    notify_failover_from_env(3, 3)
        wh.assert_called_once()
        gh.assert_called_once()
        self.assertEqual(gh.call_args.args[0], "acme/metal-mirage")


if __name__ == "__main__":
    unittest.main()
