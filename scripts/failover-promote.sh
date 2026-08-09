#!/usr/bin/env bash
# Operator helper for portfolio failover: warm standby demo + optional TM primary disable.
#
# Does NOT auto-run from the witness Function. Wire FAILOVER_WEBHOOK_URL to something
# that invokes this script (or run it by hand after FAILOVER_CANDIDATE / Drill A).
#
# Usage:
#   ./scripts/failover-promote.sh              # scale standby demo up (default)
#   ./scripts/failover-promote.sh --disable-primary-tm
#   ./scripts/failover-promote.sh --failback   # scale cold + re-enable primary TM
#   ./scripts/failover-promote.sh --dry-run
#
# Requires: kubectl (standby kubeconfig), pulumi; az when touching Traffic Manager.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "${ROOT}/scripts/lib.sh"
STACK="${PULUMI_STACK:-dev}"

MODE="promote"
DISABLE_PRIMARY_TM=0
DRY_RUN=0
REPLICAS="${FAILOVER_REPLICAS:-2}"
KUBECONFIG_PATH="${STANDBY_KUBECONFIG:-${ROOT}/.secrets/standby.kubeconfig}"

usage() {
  cat <<'EOF' >&2
usage: ./scripts/failover-promote.sh [--promote|--failback] [--disable-primary-tm] [--replicas N] [--dry-run]

  --promote              Warm standby demo (default). Suspends Flux apps-standby so
                         the cold replicas:0 patch cannot revert the scale.
  --failback             Scale demo to 0, resume Flux, re-enable primary TM endpoint.
  --disable-primary-tm   On promote: set TM primary endpoint Disabled (half-dead primary
                         still passing /healthz). Failback always re-enables it.
  --replicas N           Standby demo replicas when promoting (default 2 or FAILOVER_REPLICAS).
  --dry-run              Print actions only.

Env:
  PULUMI_STACK           Pulumi stack (default: dev)
  STANDBY_KUBECONFIG     Path to standby kubeconfig (default: .secrets/standby.kubeconfig)
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --promote) MODE="promote"; shift ;;
    --failback) MODE="failback"; shift ;;
    --disable-primary-tm) DISABLE_PRIMARY_TM=1; shift ;;
    --replicas)
      REPLICAS="${2:-}"
      [[ -n "${REPLICAS}" ]] || usage
      shift 2
      ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage ;;
    *) echo "unknown arg: $1" >&2; usage ;;
  esac
done

need pulumi "Install: https://www.pulumi.com/docs/install/"
need kubectl

if [[ ! -f "${KUBECONFIG_PATH}" ]]; then
  echo "missing standby kubeconfig: ${KUBECONFIG_PATH}" >&2
  echo "  pulumi -C $(resolve_pulumi_dir standby) stack output kubeconfig --show-secrets > .secrets/standby.kubeconfig" >&2
  exit 1
fi
export KUBECONFIG="${KUBECONFIG_PATH}"

run() {
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo "DRY-RUN: $*"
    return 0
  fi
  "$@"
}

tm_primary_endpoint_name() {
  # Prefer stack export; fall back to the stable name set in infra/shared.
  local ep=""
  ep="$(
    cd "${ROOT}/infra/shared" || exit 0
    pulumi stack select "${STACK}" >/dev/null 2>&1 || exit 0
    pulumi stack output trafficManagerPrimaryEndpoint 2>/dev/null || exit 0
  )"
  if [[ -z "${ep}" || "${ep}" == "null" ]]; then
    ep="primary"
  fi
  printf '%s\n' "${ep}"
}

tm_set_endpoint_status() {
  # tm_set_endpoint_status <endpoint-name> <Enabled|Disabled>
  local ep="$1" status="$2" rg="<resourceGroupName>" profile="<trafficManagerProfileName>"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    # Resolve real names when the shared stack is available; otherwise keep placeholders.
    if (
      cd "${ROOT}/infra/shared" && pulumi stack select "${STACK}" >/dev/null 2>&1
    ); then
      rg="$(
        cd "${ROOT}/infra/shared" && pulumi stack output resourceGroupName 2>/dev/null || echo "<resourceGroupName>"
      )"
      profile="$(
        cd "${ROOT}/infra/shared" && pulumi stack output trafficManagerProfileName 2>/dev/null || echo "metal-mirage-app"
      )"
      [[ -n "${rg}" && "${rg}" != "null" ]] || rg="<resourceGroupName>"
      [[ -n "${profile}" && "${profile}" != "null" ]] || profile="metal-mirage-app"
    else
      profile="metal-mirage-app"
    fi
    echo "==> Traffic Manager endpoint ${ep} → ${status} (profile=${profile} rg=${rg})"
    echo "DRY-RUN: az network traffic-manager endpoint update --name ${ep} --profile-name ${profile} --resource-group ${rg} --type externalEndpoints --endpoint-status ${status} --output none"
    return 0
  fi
  need az "Install Azure CLI: https://learn.microsoft.com/cli/azure/install-azure-cli"
  select_stack infra/shared
  rg="$(require_stack_output infra/shared resourceGroupName "run ./scripts/up.sh shared")"
  profile="$(require_stack_output infra/shared trafficManagerProfileName "re-run ./scripts/up.sh shared after this change (stable TM names)")"
  echo "==> Traffic Manager endpoint ${ep} → ${status} (profile=${profile} rg=${rg})"
  az network traffic-manager endpoint update \
    --name "${ep}" \
    --profile-name "${profile}" \
    --resource-group "${rg}" \
    --type externalEndpoints \
    --endpoint-status "${status}" \
    --output none
}

flux_suspend_apps() {
  echo "==> Suspending Flux Kustomization apps-standby (avoids replicas:0 revert)"
  run kubectl -n flux-system patch kustomization apps-standby \
    --type merge \
    -p '{"spec":{"suspend":true}}'
}

flux_resume_apps() {
  echo "==> Resuming Flux Kustomization apps-standby (re-applies cold replicas:0)"
  run kubectl -n flux-system patch kustomization apps-standby \
    --type merge \
    -p '{"spec":{"suspend":false}}'
}

scale_demo() {
  local n="$1"
  echo "==> Scaling demo/demo → ${n}"
  run kubectl -n demo scale deploy/demo --replicas="${n}"
}

case "${MODE}" in
  promote)
    if ! [[ "${REPLICAS}" =~ ^[1-9][0-9]*$ ]]; then
      echo "--replicas must be a positive integer (got ${REPLICAS})" >&2
      exit 1
    fi
    echo "==> Promote standby (replicas=${REPLICAS}, disable_primary_tm=${DISABLE_PRIMARY_TM}, dry_run=${DRY_RUN})"
    flux_suspend_apps
    scale_demo "${REPLICAS}"
    if [[ "${DISABLE_PRIMARY_TM}" -eq 1 ]]; then
      tm_set_endpoint_status "$(tm_primary_endpoint_name)" Disabled
    else
      echo "==> Leaving TM primary Enabled (DNS failover still follows /healthz + TTL)."
      echo "    Pass --disable-primary-tm if primary is half-dead but still answering /healthz."
    fi
    echo "Done. Wait for pods Ready, then curl Traffic Manager FQDN (see docs/DR.md)."
    echo "Durable GitOps promote (optional): edit gitops/clusters/standby/flux.yaml replicas patch."
    ;;
  failback)
    echo "==> Failback to cold standby (dry_run=${DRY_RUN})"
    scale_demo 0
    flux_resume_apps
    primary_ep="$(tm_primary_endpoint_name)"
    # Re-enable primary TM (safe if already Enabled). Dry-run prints the az command without requiring az.
    if [[ "${DRY_RUN}" -eq 1 ]] || command -v az >/dev/null 2>&1; then
      tm_set_endpoint_status "${primary_ep}" Enabled || {
        echo "warning: could not re-enable TM primary endpoint ${primary_ep}" >&2
      }
    else
      echo "warning: az not installed — re-enable TM primary endpoint ${primary_ep} manually if you disabled it" >&2
    fi
    echo "Done. Confirm primary /healthz and dig Traffic Manager FQDN (docs/DR.md)."
    ;;
  *)
    usage
    ;;
esac
