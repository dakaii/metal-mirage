import logging
import os
import ssl
import urllib.error
import urllib.request

import azure.functions as func
from azure.core.exceptions import ResourceExistsError, ResourceNotFoundError
from azure.storage.blob import BlobServiceClient

app = func.FunctionApp()

DEFAULT_THRESHOLD = 3
STATE_BLOB = "failures.txt"


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


def _failures() -> int:
    """Read consecutive failure count from durable blob storage (Y1-safe)."""
    try:
        svc = _blob_service()
        container = _container_name()
        blob = svc.get_blob_client(container, STATE_BLOB)
        data = blob.download_blob().readall().decode("utf-8").strip()
        return int(data or "0")
    except ResourceNotFoundError:
        return 0
    except Exception as exc:  # noqa: BLE001 — missing state must not crash the timer
        logging.warning("read failure state: %s", exc)
        return 0


def _set_failures(n: int) -> None:
    """Persist consecutive failure count to blob storage (survives cold starts)."""
    svc = _blob_service()
    container = _container_name()
    _ensure_container(svc, container)
    blob = svc.get_blob_client(container, STATE_BLOB)
    blob.upload_blob(str(n), overwrite=True)


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
        n = _failures() + 1
        _set_failures(n)
    except Exception as exc:  # noqa: BLE001
        logging.error("persist failure state: %s", exc)
        return

    logging.error("primary unhealthy consecutive_failures=%s threshold=%s", n, threshold)
    if n >= threshold:
        # Hook point: publish to Event Grid / webhook / scale standby apps.
        logging.error("FAILOVER_CANDIDATE primary down for %s probes", n)


@app.route(route="health", auth_level=func.AuthLevel.ANONYMOUS)
def health(req: func.HttpRequest) -> func.HttpResponse:
    return func.HttpResponse("ok", status_code=200)
