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

# Map VM size → Compute quota name.value candidates (az vm list-usage).
# Prints one or more family names (first match with quota wins).
azure_vm_size_families() {
  case "$1" in
    # Bs + Bms share "Standard B Family" (standardBSFamily) on most subs.
    Standard_B2s | Standard_B2ms) echo standardBSFamily; echo standardBmsFamily ;;
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

# Returns 0 if usage JSON allows allocating +cores on any of the family names.
# Also enforces Total Regional vCPUs ("cores") when that metric is present.
azure_vm_family_has_quota() {
  local usage_json="$1" cores="$2"
  shift 2
  local families=("$@")
  local fam_json
  fam_json="$(printf '%s\n' "${families[@]}" | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')"
  printf '%s' "${usage_json}" | python3 -c '
import json, sys
cores = int(sys.argv[1])
families = {f.lower() for f in json.loads(sys.argv[2])}
usage = json.load(sys.stdin)

def entry(name_value: str):
    for u in usage:
        name = ((u.get("name") or {}).get("value") or "")
        if name.lower() == name_value.lower():
            return int(u.get("limit") or 0), int(u.get("currentValue") or 0)
    return None

regional = entry("cores")
if regional is not None:
    limit, current = regional
    if limit > 0 and current + cores > limit:
        sys.exit(1)

for fam in families:
    got = entry(fam)
    if got is None:
        continue
    limit, current = got
    if limit > 0 and current + cores <= limit:
        sys.exit(0)
sys.exit(1)
' "${cores}" "${fam_json}"
}

# Returns 0 if SKU is missing or restricted for this subscription in the location.
azure_vm_sku_blocked() {
  local location="$1" size="$2"
  local raw
  raw="$(az vm list-skus \
    --location "${location}" \
    --size "${size}" \
    --resource-type virtualMachines \
    --query "[?name=='${size}']" \
    -o json 2>/dev/null || echo '[]')"
  printf '%s' "${raw}" | python3 -c '
import json, sys
data = json.load(sys.stdin)
if not data:
    sys.exit(0)  # unknown / not offered → treat as blocked
sku = data[0] if isinstance(data, list) else data
restrictions = sku.get("restrictions") or []
for r in restrictions:
    reason = r.get("reasonCode") or ""
    rtype = r.get("type") or ""
    if reason == "NotAvailableForSubscription":
        sys.exit(0)
    if rtype == "Location" and reason:
        sys.exit(0)
sys.exit(1)  # not blocked
'
}

# Print first viable size for location.
# Usage: pick_azure_vm_size <location> [preferred_size] [total_cores_needed]
# Progress lines go to stderr; chosen size to stdout.
pick_azure_vm_size() {
  local location="$1"
  local preferred="${2:-}"
  local total_cores="${3:-}"
  local usage_json size per_vm need
  local -a sizes=() families=()

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

    families=()
    while IFS= read -r fam; do
      [[ -n "${fam}" ]] && families+=("${fam}")
    done < <(azure_vm_size_families "${size}" 2>/dev/null || true)
    if [[ "${#families[@]}" -eq 0 ]]; then
      continue
    fi
    per_vm="$(azure_vm_size_cores "${size}")"
    need="${total_cores:-${per_vm}}"
    if ! azure_vm_family_has_quota "${usage_json}" "${need}" "${families[@]}"; then
      echo "    skip ${size}: need ${need} vCPUs (${families[*]}) in ${location}" >&2
      continue
    fi
    if azure_vm_sku_blocked "${location}" "${size}"; then
      echo "    skip ${size}: SKU missing/restricted in ${location}" >&2
      continue
    fi
    printf '%s\n' "${size}"
    return 0
  done
  return 1
}
