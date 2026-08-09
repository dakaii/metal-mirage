#!/usr/bin/env bash
# Zip-deploy the witness Function App sources from infra/shared/witness.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}/infra/shared"
APP="$(pulumi stack output witnessFunctionName)"
RG="$(az functionapp list --query "[?name=='${APP}'].resourceGroup | [0]" -o tsv)"
if [[ -z "${RG}" || "${RG}" == "null" ]]; then
  echo "Could not resolve resource group for function app ${APP}" >&2
  exit 1
fi
ZIP="$(mktemp -t witnessXXXX).zip"
(
  cd "${ROOT}/infra/shared/witness"
  zip -qr "${ZIP}" function_app.py host.json requirements.txt
)
echo "==> Deploying witness to ${APP} in ${RG}"
az functionapp deployment source config-zip -g "${RG}" -n "${APP}" --src "${ZIP}"
rm -f "${ZIP}"
echo "Done. Timer probe runs every minute against shared:primaryAPIURL."
