import json
import logging
import os
import ssl
import urllib.error
import urllib.request

import azure.functions as func
from azure.core import MatchConditions
from azure.core.exceptions import ResourceExistsError, ResourceModifiedError, ResourceNotFoundError
from azure.storage.blob import BlobClient, BlobServiceClient

app = func.FunctionApp()

DEFAULT_THRESHOLD = 3
STATE_BLOB = "failures.txt"
# Bounded retries for concurrent timer / cold-start races on the failure counter.
_RMW_ATTEMPTS = 8


def _threshold() -> int:
    raw = os.environ.get("FAILURE_THRESHOLD", str(DEFAULT_THRESHOLD)).strip()
    try:
        n = int(raw)
        if n < 1:
            return DEFAULT_THRESHOLD
        return n
    except ValueError:
        logging.error("invalid FAILURE_THRESHOLD=%r; using %s", raw, DEFAULT_THRESHOLD)
        return DEFAULT_THRESHOLD


def _blob_service() -> BlobServiceClient:
    conn = os.environ.get("AzureWebJobsStorage", "")
    if not conn:
        raise RuntimeError("AzureWebJobsStorage not set")
    return BlobServiceClient.from_connection_string(conn)


def _container_name() -> str:
    return os.environ.get("WITNESS_STATE_CONTAINER", "witness-state").strip() or "witness-state"


def _ensure_container(svc: BlobServiceClient, name: str) -> None:
    try:
        svc.create_container(name)
    except ResourceExistsError:
        pass


def _parse_count(raw: bytes) -> int:
    text = raw.decode("utf-8").strip()
    if not text:
        return 0
    return int(text)


def _state_blob() -> BlobClient:
    svc = _blob_service()
    container = _container_name()
    _ensure_container(svc, container)
    return svc.get_blob_client(container, STATE_BLOB)


def _set_failures(n: int) -> None:
    """Overwrite failure count (used to reset to zero on healthy probe)."""
    blob = _state_blob()
    blob.upload_blob(str(n), overwrite=True)


def _increment_failures() -> int:
    """Atomically bump the consecutive failure counter using ETag If-Match.

    Consumption Y1 normally runs one timer instance, but cold starts / overlaps
    can race a plain read-modify-write. Conditional upload retries on conflict.
    """
    blob = _state_blob()
    for _ in range(_RMW_ATTEMPTS):
        try:
            downloader = blob.download_blob()
            etag = downloader.properties.etag
            try:
                count = _parse_count(downloader.readall())
            except ValueError:
                count = 0
            nxt = count + 1
            blob.upload_blob(
                str(nxt),
                overwrite=True,
                etag=etag,
                match_condition=MatchConditions.IfNotModified,
            )
            return nxt
        except ResourceNotFoundError:
            try:
                blob.upload_blob("1", overwrite=False)
                return 1
            except ResourceExistsError:
                continue
        except ResourceModifiedError:
            continue
    raise RuntimeError("failed to increment witness failure count after retries")


def _notify_failover(failures: int, threshold: int) -> None:
    """Optional outbound hook when the failure threshold is first crossed.

    Set FAILOVER_WEBHOOK_URL to an HTTPS endpoint (Event Grid subscription,
    Logic App, Slack incoming webhook, etc.). Empty/unset = log-only (default).
    Fires once at the crossing (failures == threshold), not every later minute.
    """
    hook = os.environ.get("FAILOVER_WEBHOOK_URL", "").strip()
    if not hook:
        return
    payload = json.dumps(
        {
            "event": "FAILOVER_CANDIDATE",
            "consecutive_failures": failures,
            "threshold": threshold,
            "primary_api_url": os.environ.get("PRIMARY_API_URL", ""),
        }
    ).encode("utf-8")
    req = urllib.request.Request(
        hook,
        data=payload,
        method="POST",
        headers={"Content-Type": "application/json", "User-Agent": "metal-mirage-witness/1"},
    )
    try:
        with urllib.request.urlopen(req, timeout=8) as resp:
            logging.info("failover webhook status=%s", resp.status)
    except Exception as exc:  # noqa: BLE001 — never crash the timer on webhook failure
        logging.error("failover webhook failed: %s", exc)


@app.timer_trigger(schedule="0 */1 * * * *", arg_name="timer", run_on_startup=False)
def probe_primary(timer: func.TimerRequest) -> None:
    """Probe primary Kubernetes /readyz every minute; log when threshold exceeded."""
    url = os.environ.get("PRIMARY_API_URL", "")
    threshold = _threshold()
    if not url:
        logging.error("PRIMARY_API_URL not set")
        return

    ctx = ssl._create_unverified_context()
    healthy = False
    try:
        req = urllib.request.Request(url, method="GET")
        with urllib.request.urlopen(req, timeout=8, context=ctx) as resp:
            healthy = 200 <= resp.status < 300
            body = resp.read(200)
            logging.info("probe status=%s body=%s", resp.status, body[:80])
    except Exception as exc:  # noqa: BLE001 — witness must never crash the host
        logging.warning("probe failed: %s", exc)
        healthy = False

    if healthy:
        try:
            _set_failures(0)
        except Exception as exc:  # noqa: BLE001
            logging.warning("reset failure state: %s", exc)
        logging.info("primary healthy")
        return

    try:
        n = _increment_failures()
    except Exception as exc:  # noqa: BLE001
        logging.error("persist failure state: %s", exc)
        return

    logging.error("primary unhealthy consecutive_failures=%s threshold=%s", n, threshold)
    if n >= threshold:
        logging.error("FAILOVER_CANDIDATE primary down for %s probes", n)
        if n == threshold:
            _notify_failover(n, threshold)


@app.route(route="health", auth_level=func.AuthLevel.ANONYMOUS)
def health(req: func.HttpRequest) -> func.HttpResponse:
    return func.HttpResponse("ok", status_code=200)
