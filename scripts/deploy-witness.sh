#!/usr/bin/env bash
# Zip-deploy the witness Function App sources.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}/infra/shared"
APP="$(pulumi stack output witnessFunctionName)"
RG="$(pulumi stack output --json 2>/dev/null | python3 -c "import sys,json; print('shared-rg')" 2>/dev/null || true)"
# Prefer resource group from Azure naming — look up by function name
RG="$(az functionapp list --query "[?name=='${APP}'].resourceGroup | [0]" -o tsv)"
ZIP="$(mktemp -t witnessXXXX).zip"
(
  cd "${ROOT}/infra/shared/witness"
  zip -qr "${ZIP}" function_app.py host.json requirements.txt
)
echo "==> Deploying witness to ${APP} in ${RG}"
az functionapp deployment source config-zip -g "${RG}" -n "${APP}" --src "${ZIP}"
rm -f "${ZIP}"
echo "Done. Timer probe runs every minute against shared:primaryAPIURL."
