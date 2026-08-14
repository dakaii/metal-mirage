#!/usr/bin/env bash
# Zip-deploy the witness Function App sources from infra/shared/witness.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "${ROOT}/scripts/lib.sh"
STACK="${PULUMI_STACK:-dev}"

need az "Install Azure CLI: https://learn.microsoft.com/cli/azure/install-azure-cli"
need zip
need pulumi "Install: https://www.pulumi.com/docs/install/"
need curl

select_stack infra/shared
APP="$(require_stack_output infra/shared witnessFunctionName "enable shared:enableWitness (default) and ./scripts/up.sh shared")"
HOST="$(stack_output infra/shared witnessDefaultHost || true)"
cd "${ROOT}/infra/shared"

RG="$(az functionapp list --query "[?name=='${APP}'].resourceGroup | [0]" -o tsv)"
if [[ -z "${RG}" || "${RG}" == "null" ]]; then
  echo "Could not resolve resource group for function app ${APP}" >&2
  exit 1
fi

# Ensure Python v2 indexing + remote build flags (also set by infra/shared Pulumi).
# Safe to re-apply so an already-created app picks them up without a full stack rewrite.
az functionapp config appsettings set -g "${RG}" -n "${APP}" --settings \
  AzureWebJobsFeatureFlags=EnableWorkerIndexing \
  SCM_DO_BUILD_DURING_DEPLOYMENT=true \
  ENABLE_ORYX_BUILD=true \
  >/dev/null

ZIP="$(mktemp -t witnessXXXX).zip"
trap 'rm -f "${ZIP}"' EXIT
(
  cd "${ROOT}/infra/shared/witness"
  zip -qr "${ZIP}" function_app.py notify.py host.json requirements.txt
)
echo "==> Deploying witness to ${APP} in ${RG} (remote build)"
# --build-remote installs requirements.txt on Linux (needed for azure-storage-blob).
az functionapp deployment source config-zip -g "${RG}" -n "${APP}" --src "${ZIP}" --build-remote true

echo "==> Waiting for anonymous /api/health (Python v2 index)"
if [[ -z "${HOST}" || "${HOST}" == "null" ]]; then
  HOST="$(az functionapp show -g "${RG}" -n "${APP}" --query defaultHostName -o tsv)"
fi
ok=0
for _ in $(seq 1 18); do
  if curl -fsS --max-time 10 "https://${HOST}/api/health" >/dev/null 2>&1; then
    ok=1
    break
  fi
  sleep 10
done
if [[ "${ok}" -ne 1 ]]; then
  echo "error: https://${HOST}/api/health did not return ok after deploy" >&2
  echo "  Check Portal → Function App → Functions (expect probe_primary + health)." >&2
  echo "  Y1 CLI logstream often 404s — use Portal → Functions → Monitor instead." >&2
  echo "  Re-run: ./scripts/up.sh shared && ./scripts/deploy-witness.sh" >&2
  exit 1
fi
echo "health: https://${HOST}/api/health → ok"

FUNCS="$(az functionapp function list -g "${RG}" -n "${APP}" --query "length(@)" -o tsv 2>/dev/null || echo 0)"
if [[ "${FUNCS}" == "0" || -z "${FUNCS}" ]]; then
  echo "warn: az functionapp function list is still empty (portal/index lag); /api/health passed" >&2
else
  echo "functions registered: ${FUNCS}"
fi

echo "Done. Timer probe runs every minute against shared:primaryAPIURL (/readyz)."
echo "Failure counter lives in blob container witness-state (survives Y1 cold starts)."
echo "Logs: Portal → Functions → Monitor (az webapp log tail often 404s on Linux Y1)."
echo "Opt-in notify: docs/AUTO-FAILOVER.md (webhook / GitHub repository_dispatch)."
