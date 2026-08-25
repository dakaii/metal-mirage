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
  echo "FAIL: standby should need Azure subscription" >&2
  fail=1
fi
if ! target_needs_azure_subscription all up; then
  echo "FAIL: up all should need Azure subscription" >&2
  fail=1
fi
# destroy all with bare-metal + no pin → skip
if target_needs_azure_subscription all destroy; then
  echo "FAIL: destroy all without pin should skip Azure check on bare-metal" >&2
  fail=1
fi

if [[ "${fail}" -ne 0 ]]; then
  exit 1
fi
echo "OK — azure subscription guard helpers"
