#!/usr/bin/env bash
# Operator helper for portfolio failover: warm standby demo + optional TM primary disable.
#
# Does NOT auto-run from the witness Function by default. Opt-in paths:
#   - FAILOVER_WEBHOOK_URL / FAILOVER_GITHUB_* → runner (see docs/AUTO-FAILOVER.md)
#   - .github/workflows/failover-promote.yml (workflow_dispatch / repository_dispatch)
#   - run this script by hand after FAILOVER_CANDIDATE / Drill A
#
# Usage:
#   ./scripts/failover-promote.sh              # scale standby demo up (default)
#   ./scripts/failover-promote.sh --disable-primary-tm
#   ./scripts/failover-promote.sh --failback   # scale cold + re-enable primary TM
#   ./scripts/failover-promote.sh --dry-run
#
# Requires: kubectl (standby kubeconfig); az when touching Traffic Manager unless
# TM_* env overrides are set. Pulumi is optional when TM_* + kubeconfig are provided.
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
  FAILOVER_REPLICAS      Default replica count for --promote
  TM_RESOURCE_GROUP      Optional: skip Pulumi for TM updates (CI / automation)
  TM_PROFILE_NAME        Optional: Traffic Manager profile name
  TM_PRIMARY_ENDPOINT    Optional: primary endpoint name (default: primary)
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

if [[ "${DRY_RUN}" -eq 0 ]]; then
  need kubectl
fi

if [[ ! -f "${KUBECONFIG_PATH}" ]]; then
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo "note: missing standby kubeconfig ${KUBECONFIG_PATH} (ok for --dry-run)" >&2
  else
    echo "missing standby kubeconfig: ${KUBECONFIG_PATH}" >&2
    echo "  pulumi -C $(resolve_pulumi_dir standby) stack output kubeconfig --show-secrets > .secrets/standby.kubeconfig" >&2
    exit 1
  fi
else
  export KUBECONFIG="${KUBECONFIG_PATH}"
fi

run() {
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo "DRY-RUN: $*"
    return 0
  fi
  "$@"
}

tm_env_complete() {
  [[ -n "${TM_RESOURCE_GROUP:-}" && -n "${TM_PROFILE_NAME:-}" ]]
}

tm_primary_endpoint_name() {
  if [[ -n "${TM_PRIMARY_ENDPOINT:-}" ]]; then
    printf '%s\n' "${TM_PRIMARY_ENDPOINT}"
    return 0
  fi
  # Prefer stack export; fall back to the stable name set in infra/shared.
  local ep=""
  if command -v pulumi >/dev/null 2>&1; then
    ep="$(
      cd "${ROOT}/infra/shared" || exit 0
      pulumi stack select "${STACK}" >/dev/null 2>&1 || exit 0
      pulumi stack output trafficManagerPrimaryEndpoint 2>/dev/null || exit 0
    )"
  fi
  if [[ -z "${ep}" || "${ep}" == "null" ]]; then
    ep="primary"
  fi
  printf '%s\n' "${ep}"
}

tm_resolve_names() {
  # Sets TM_RG / TM_PROFILE for callers. Prefers TM_* env (automation), else Pulumi.
  if tm_env_complete; then
    TM_RG="${TM_RESOURCE_GROUP}"
    TM_PROFILE="${TM_PROFILE_NAME}"
    return 0
  fi
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    TM_RG="<resourceGroupName>"
    TM_PROFILE="metal-mirage-app"
    if command -v pulumi >/dev/null 2>&1 && (
      cd "${ROOT}/infra/shared" && pulumi stack select "${STACK}" >/dev/null 2>&1
    ); then
      TM_RG="$(
        cd "${ROOT}/infra/shared" && pulumi stack output resourceGroupName 2>/dev/null || echo "<resourceGroupName>"
      )"
      TM_PROFILE="$(
        cd "${ROOT}/infra/shared" && pulumi stack output trafficManagerProfileName 2>/dev/null || echo "metal-mirage-app"
      )"
      [[ -n "${TM_RG}" && "${TM_RG}" != "null" ]] || TM_RG="<resourceGroupName>"
      [[ -n "${TM_PROFILE}" && "${TM_PROFILE}" != "null" ]] || TM_PROFILE="metal-mirage-app"
    fi
    return 0
  fi
  need pulumi "Install: https://www.pulumi.com/docs/install/ (or set TM_RESOURCE_GROUP + TM_PROFILE_NAME)"
  select_stack infra/shared
  TM_RG="$(require_stack_output infra/shared resourceGroupName "run ./scripts/up.sh shared")"
  TM_PROFILE="$(require_stack_output infra/shared trafficManagerProfileName "re-run ./scripts/up.sh shared after this change (stable TM names)")"
}

tm_set_endpoint_status() {
  # tm_set_endpoint_status <endpoint-name> <Enabled|Disabled>
  local ep="$1" status="$2"
  local TM_RG TM_PROFILE
  tm_resolve_names
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo "==> Traffic Manager endpoint ${ep} → ${status} (profile=${TM_PROFILE} rg=${TM_RG})"
    echo "DRY-RUN: az network traffic-manager endpoint update --name ${ep} --profile-name ${TM_PROFILE} --resource-group ${TM_RG} --type externalEndpoints --endpoint-status ${status} --output none"
    return 0
  fi
  need az "Install Azure CLI: https://learn.microsoft.com/cli/azure/install-azure-cli"
  echo "==> Traffic Manager endpoint ${ep} → ${status} (profile=${TM_PROFILE} rg=${TM_RG})"
  az network traffic-manager endpoint update \
    --name "${ep}" \
    --profile-name "${TM_PROFILE}" \
    --resource-group "${TM_RG}" \
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
