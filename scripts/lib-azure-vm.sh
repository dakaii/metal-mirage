# Shared Azure VM size helpers (quota + SKU probe).
# shellcheck shell=bash
# Source from scripts after ROOT is set.

# Default candidate list — prefer families that usually have quota on new subs.
# Override: AZURE_VM_SIZE_CANDIDATES="Standard_D2s_v4 Standard_B2ms …"
azure_vm_size_candidates() {
  if [[ -n "${AZURE_VM_SIZE_CANDIDATES:-}" ]]; then
    # Intentional word-split of space-separated sizes.
    # shellcheck disable=SC2086
    echo ${AZURE_VM_SIZE_CANDIDATES}
    return 0
  fi
  echo \
    Standard_D2s_v4 \
    Standard_D2s_v3 \
    Standard_DS2_v2 \
    Standard_D2_v3 \
    Standard_D2_v2 \
    Standard_D2s_v5 \
    Standard_B2ms \
    Standard_B2s \
    Standard_A2_v2 \
    Standard_F2s_v2 \
    Standard_E2s_v3
}

# Map VM size → Compute quota name.value (az vm list-usage).
azure_vm_size_family() {
  case "$1" in
    Standard_B2s) echo standardBSFamily ;;
    Standard_B2ms) echo standardBmsFamily ;;
    Standard_D2s_v5) echo standardDSv5Family ;;
    Standard_D2s_v4) echo standardDSv4Family ;;
    Standard_D2s_v3) echo standardDSv3Family ;;
    Standard_DS2_v2) echo standardDSv2Family ;;
    Standard_D2_v3) echo standardDv3Family ;;
    Standard_D2_v2) echo standardDv2Family ;;
    Standard_A2_v2) echo standardAv2Family ;;
    Standard_F2s_v2) echo standardFSv2Family ;;
    Standard_E2s_v3) echo standardESv3Family ;;
    *) return 1 ;;
  esac
}

# Cores required for a size in our candidate set (all *2* SKUs here).
azure_vm_size_cores() {
  echo 2
}

# Returns 0 if usage JSON allows allocating +cores on family.
azure_vm_family_has_quota() {
  local usage_json="$1" family="$2" cores="$3"
  printf '%s' "${usage_json}" | python3 -c '
import json, sys
family = sys.argv[1]
cores = int(sys.argv[2])
usage = json.load(sys.stdin)
for u in usage:
    name = (u.get("name") or {}).get("value") or ""
    if name != family:
        continue
    limit = int(u.get("limit") or 0)
    current = int(u.get("currentValue") or 0)
    sys.exit(0 if limit > 0 and current + cores <= limit else 1)
sys.exit(1)
' "${family}" "${cores}"
}

# Returns 0 if SKU is restricted for this subscription in the location.
azure_vm_sku_blocked() {
  local location="$1" size="$2"
  local raw
  raw="$(az vm list-skus \
    --location "${location}" \
    --size "${size}" \
    --resource-type virtualMachines \
    --query "[?name=='${size}'].restrictions" \
    -o json 2>/dev/null || echo '[]')"
  printf '%s' "${raw}" | python3 -c '
import json, sys
data = json.load(sys.stdin)
restrictions = []
if isinstance(data, list) and data:
    restrictions = data[0] if isinstance(data[0], list) else data
for r in restrictions or []:
    reason = r.get("reasonCode") or ""
    rtype = r.get("type") or ""
    if reason == "NotAvailableForSubscription":
        sys.exit(0)  # blocked
    if rtype == "Location" and reason:
        sys.exit(0)
sys.exit(1)  # not blocked
'
}

# Print first viable size for location.
# Usage: pick_azure_vm_size <location> [preferred_size] [total_cores_needed]
#   total_cores_needed defaults to one VM (2). For primary lab with 1 CP + 1
#   worker of the same size, pass 4.
# Progress lines go to stderr; chosen size to stdout.
pick_azure_vm_size() {
  local location="$1"
  local preferred="${2:-}"
  local total_cores="${3:-}"
  local usage_json size family per_vm need
  local -a sizes=()

  if [[ -n "${preferred}" ]]; then
    sizes+=("${preferred}")
  fi
  # shellcheck disable=SC2207
  sizes+=($(azure_vm_size_candidates))

  usage_json="$(az vm list-usage --location "${location}" -o json)"

  local seen=""
  for size in "${sizes[@]}"; do
    [[ " ${seen} " == *" ${size} "* ]] && continue
    seen+=" ${size}"

    family="$(azure_vm_size_family "${size}" 2>/dev/null || true)"
    if [[ -z "${family}" ]]; then
      continue
    fi
    per_vm="$(azure_vm_size_cores "${size}")"
    need="${total_cores:-${per_vm}}"
    if ! azure_vm_family_has_quota "${usage_json}" "${family}" "${need}"; then
      echo "    skip ${size}: need ${need} ${family} vCPUs in ${location}" >&2
      continue
    fi
    if azure_vm_sku_blocked "${location}" "${size}"; then
      echo "    skip ${size}: SKU restricted in ${location}" >&2
      continue
    fi
    printf '%s\n' "${size}"
    return 0
  done
  return 1
}
