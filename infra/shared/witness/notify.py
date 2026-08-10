"""Pure helpers for optional failover notifications (no Azure Functions imports)."""

from __future__ import annotations

import hashlib
import hmac
import json
import logging
import os
import urllib.error
import urllib.request
from typing import Any, Mapping, MutableMapping

USER_AGENT = "metal-mirage-witness/1"
SIGNATURE_HEADER = "X-Metal-Mirage-Signature"
GITHUB_EVENT_TYPE = "failover-candidate"


def build_failover_payload(
    *,
    failures: int,
    threshold: int,
    primary_api_url: str = "",
    source: str = "metal-mirage-witness",
    extra: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    """JSON body posted at threshold crossing (FAILOVER_CANDIDATE)."""
    payload: dict[str, Any] = {
        "event": "FAILOVER_CANDIDATE",
        "consecutive_failures": failures,
        "threshold": threshold,
        "primary_api_url": primary_api_url,
        "source": source,
        # Hint for runners (GHA repository_dispatch / Logic Apps).
        "recommended_action": "promote_standby",
        "schema_version": 1,
    }
    if extra:
        for key, value in extra.items():
            if key not in payload:
                payload[key] = value
    return payload


def sign_payload(body: bytes, secret: str) -> str:
    """Return sha256=<hex> HMAC for the raw JSON body."""
    digest = hmac.new(secret.encode("utf-8"), body, hashlib.sha256).hexdigest()
    return f"sha256={digest}"


def verify_signature(body: bytes, secret: str, header_value: str) -> bool:
    """Constant-time check of X-Metal-Mirage-Signature."""
    expected = sign_payload(body, secret)
    return hmac.compare_digest(expected, (header_value or "").strip())


def _post_json(url: str, body: bytes, headers: MutableMapping[str, str], timeout: float = 8.0) -> int:
    req = urllib.request.Request(url, data=body, method="POST", headers=dict(headers))
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return int(resp.status)


def post_failover_webhook(
    url: str,
    payload: Mapping[str, Any],
    *,
    hmac_secret: str = "",
    timeout: float = 8.0,
) -> int:
    """POST JSON to an arbitrary HTTPS webhook; optional HMAC header."""
    body = json.dumps(payload, separators=(",", ":"), sort_keys=True).encode("utf-8")
    headers: dict[str, str] = {
        "Content-Type": "application/json",
        "User-Agent": USER_AGENT,
    }
    secret = hmac_secret.strip()
    if secret:
        headers[SIGNATURE_HEADER] = sign_payload(body, secret)
    return _post_json(url, body, headers, timeout=timeout)


def dispatch_github_failover(
    repo: str,
    token: str,
    payload: Mapping[str, Any],
    *,
    event_type: str = GITHUB_EVENT_TYPE,
    timeout: float = 8.0,
) -> int:
    """Trigger GitHub repository_dispatch (event_type=failover-candidate by default).

    repo: 'owner/name'. client_payload is the witness event (size-limited by GitHub).
    """
    owner_repo = repo.strip().strip("/")
    if "/" not in owner_repo or owner_repo.count("/") != 1:
        raise ValueError(f"FAILOVER_GITHUB_REPO must be owner/name, got {repo!r}")
    body = json.dumps(
        {
            "event_type": event_type,
            "client_payload": dict(payload),
        },
        separators=(",", ":"),
    ).encode("utf-8")
    headers = {
        "Authorization": f"Bearer {token.strip()}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "Content-Type": "application/json",
        "User-Agent": USER_AGENT,
    }
    url = f"https://api.github.com/repos/{owner_repo}/dispatches"
    return _post_json(url, body, headers, timeout=timeout)


def notify_failover_from_env(failures: int, threshold: int) -> None:
    """Fire optional webhook and/or GitHub dispatch using Function app settings.

    Never raises — callers must not crash the probe timer on notify failure.
    """
    primary = os.environ.get("PRIMARY_API_URL", "")
    payload = build_failover_payload(
        failures=failures,
        threshold=threshold,
        primary_api_url=primary,
    )

    hook = os.environ.get("FAILOVER_WEBHOOK_URL", "").strip()
    hmac_secret = os.environ.get("FAILOVER_WEBHOOK_HMAC_SECRET", "").strip()
    if hook:
        try:
            status = post_failover_webhook(hook, payload, hmac_secret=hmac_secret)
            logging.info("failover webhook status=%s", status)
        except Exception as exc:  # noqa: BLE001
            logging.error("failover webhook failed: %s", exc)

    gh_token = os.environ.get("FAILOVER_GITHUB_TOKEN", "").strip()
    gh_repo = os.environ.get("FAILOVER_GITHUB_REPO", "").strip()
    if gh_token and gh_repo:
        try:
            status = dispatch_github_failover(gh_repo, gh_token, payload)
            # GitHub returns 204 No Content on success.
            logging.info("failover github dispatch status=%s repo=%s", status, gh_repo)
        except Exception as exc:  # noqa: BLE001
            logging.error("failover github dispatch failed: %s", exc)
    elif gh_token or gh_repo:
        logging.warning(
            "FAILOVER_GITHUB_TOKEN and FAILOVER_GITHUB_REPO must both be set; skipping GitHub dispatch"
        )
