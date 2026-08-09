#!/usr/bin/env bash
# Zip-deploy the witness Function App sources from infra/shared/witness.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STACK="${PULUMI_STACK:-dev}"

command -v az >/dev/null || {
  echo "missing az CLI" >&2
  exit 1
}
command -v zip >/dev/null || {
  echo "missing zip" >&2
  exit 1
}
command -v pulumi >/dev/null || {
  echo "missing pulumi" >&2
  exit 1
}

cd "${ROOT}/infra/shared"
pulumi stack select "${STACK}" >/dev/null

if ! APP="$(pulumi stack output witnessFunctionName 2>/dev/null)"; then
  echo "no witnessFunctionName output — enable shared:enableWitness (default) and ./scripts/up.sh shared" >&2
  exit 1
fi

RG="$(az functionapp list --query "[?name=='${APP}'].resourceGroup | [0]" -o tsv)"
if [[ -z "${RG}" || "${RG}" == "null" ]]; then
  echo "Could not resolve resource group for function app ${APP}" >&2
  exit 1
fi

ZIP="$(mktemp -t witnessXXXX).zip"
trap 'rm -f "${ZIP}"' EXIT
(
  cd "${ROOT}/infra/shared/witness"
  zip -qr "${ZIP}" function_app.py host.json requirements.txt
)
echo "==> Deploying witness to ${APP} in ${RG}"
az functionapp deployment source config-zip -g "${RG}" -n "${APP}" --src "${ZIP}"
echo "Done. Timer probe runs every minute against shared:primaryAPIURL (/readyz)."
