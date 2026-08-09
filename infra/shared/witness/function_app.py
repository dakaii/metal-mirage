import azure.functions as func
import logging
import os
import urllib.request
import urllib.error
import ssl

app = func.FunctionApp()

FAILURE_FILE = "/tmp/witness_failures"


def _failures() -> int:
    try:
        with open(FAILURE_FILE) as f:
            return int(f.read().strip() or "0")
    except FileNotFoundError:
        return 0


def _set_failures(n: int) -> None:
    with open(FAILURE_FILE, "w") as f:
        f.write(str(n))


@app.timer_trigger(schedule="0 */1 * * * *", arg_name="timer", run_on_startup=False)
def probe_primary(timer: func.TimerRequest) -> None:
    """Probe primary Kubernetes /readyz every minute; log when threshold exceeded."""
    url = os.environ.get("PRIMARY_API_URL", "")
    threshold = int(os.environ.get("FAILURE_THRESHOLD", "3"))
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
        _set_failures(0)
        logging.info("primary healthy")
        return

    n = _failures() + 1
    _set_failures(n)
    logging.error("primary unhealthy consecutive_failures=%s threshold=%s", n, threshold)
    if n >= threshold:
        # Hook point: publish to Event Grid / webhook / scale standby apps.
        logging.error("FAILOVER_CANDIDATE primary down for %s probes", n)


@app.route(route="health", auth_level=func.AuthLevel.ANONYMOUS)
def health(req: func.HttpRequest) -> func.HttpResponse:
    return func.HttpResponse("ok", status_code=200)
