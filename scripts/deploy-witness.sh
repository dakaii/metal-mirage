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

select_stack infra/shared
APP="$(require_stack_output infra/shared witnessFunctionName "enable shared:enableWitness (default) and ./scripts/up.sh shared")"
cd "${ROOT}/infra/shared"

RG="$(az functionapp list --query "[?name=='${APP}'].resourceGroup | [0]" -o tsv)"
if [[ -z "${RG}" || "${RG}" == "null" ]]; then
  echo "Could not resolve resource group for function app ${APP}" >&2
  exit 1
fi

ZIP="$(mktemp -t witnessXXXX).zip"
trap 'rm -f "${ZIP}"' EXIT
(
  cd "${ROOT}/infra/shared/witness"
  zip -qr "${ZIP}" function_app.py notify.py host.json requirements.txt
)
echo "==> Deploying witness to ${APP} in ${RG}"
az functionapp deployment source config-zip -g "${RG}" -n "${APP}" --src "${ZIP}"
echo "Done. Timer probe runs every minute against shared:primaryAPIURL (/readyz)."
echo "Failure counter lives in blob container witness-state (survives Y1 cold starts)."
echo "Opt-in notify: docs/AUTO-FAILOVER.md (webhook / GitHub repository_dispatch)."
