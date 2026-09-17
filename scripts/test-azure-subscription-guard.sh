#!/usr/bin/env bash
# Offline unit checks for Azure subscription pin helpers in scripts/lib.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "${ROOT}/scripts/lib.sh"

fail=0
assert_ok() {
  if ! "$@"; then
    echo "FAIL: expected success: $*" >&2
    fail=1
  fi
}
assert_fail() {
  if "$@"; then
    echo "FAIL: expected failure: $*" >&2
    fail=1
  fi
}

assert_ok assert_azure_subscription_match \
  'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' \
  'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
assert_ok assert_azure_subscription_match \
  'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE' \
  'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
assert_fail assert_azure_subscription_match \
  'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' \
  '00000000-0000-0000-0000-000000000000'

# Default committed clusters.yaml is bare-metal → up primary does not need Azure.
if target_needs_azure_subscription primary up; then
  echo "FAIL: bare-metal primary should not need Azure subscription" >&2
  fail=1
fi
if ! target_needs_azure_subscription standby up; then
  echo "FAIL: aks/default standby should need Azure subscription" >&2
  fail=1
fi
# Simulate gke by checking helper with a temp note — default clusters.yaml is aks-shaped
# (provisioner aks). When standby.provisioner=gke, Azure is not required:
# covered indirectly via resolve path; keep aks default assertion above.

if ! target_needs_azure_subscription all up; then
  echo "FAIL: up all should need Azure subscription (default aks shared path)" >&2
  fail=1
fi
# destroy all with bare-metal + no pin → skip
if target_needs_azure_subscription all destroy; then
  echo "FAIL: destroy all without pin should skip Azure check on bare-metal" >&2
  fail=1
fi

assert_ok assert_gcp_project_match 'metal-mirage-lab' 'metal-mirage-lab'
assert_fail assert_gcp_project_match 'metal-mirage-lab' 'other-project'

# provisioner wins over a stale sibling pulumi_dir (bugbot: high)
ROOT_BAK="${ROOT}"
tmpdir="$(mktemp -d)"
mkdir -p "${tmpdir}/config"
cat >"${tmpdir}/config/clusters.yaml" <<'YAML'
standby:
  provisioner: gke
  pulumi_dir: infra/standby-aks
YAML
ROOT="${tmpdir}"
got="$(resolve_pulumi_dir standby)"
ROOT="${ROOT_BAK}"
rm -rf "${tmpdir}"
if [[ "${got}" != "infra/standby-gke" ]]; then
  echo "FAIL: gke + stale pulumi_dir=infra/standby-aks should resolve to infra/standby-gke (got ${got})" >&2
  fail=1
fi

if [[ "${fail}" -ne 0 ]]; then
  exit 1
fi
echo "OK — azure subscription guard helpers"
