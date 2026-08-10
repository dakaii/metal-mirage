# Shared Azure VM size helpers (quota + SKU probe) and admin CIDR detect.
# shellcheck shell=bash
# Source from scripts after ROOT is set.

# Detect operator public IPv4 as x.x.x.x/32 (for NSG adminCidr).
# Prints CIDR on stdout; exits 1 if undetectable.
detect_admin_cidr() {
  local ip="" url
  for url in "https://ifconfig.me" "https://api.ipify.org" "https://icanhazip.com"; do
    ip="$(curl -fsSL --max-time 5 "${url}" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ "${ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      printf '%s/32\n' "${ip}"
      return 0
    fi
  done
  echo "could not detect public IPv4 for adminCidr (tried ifconfig.me / ipify / icanhazip)." >&2
  return 1
}

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

# Returns 0 only if the SKU is location-wide unavailable for this subscription.
# Zone restrictions are ignored: non-zonal creates still work when some AZs are
# restricted. Empty/unknown list-skus must not false-block (that previously
# skipped Standard_D2s_v4 after a successful helper-VM create).
azure_vm_sku_blocked() {
  local location="$1" size="$2"
  local raw
  # --size keeps the query small (full catalog per candidate is very slow).
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
    sys.exit(1)  # unknown → do not block; quota gate + create fallback decide
sku = data[0] if isinstance(data, list) else data
for r in sku.get("restrictions") or []:
    reason = (r.get("reasonCode") or "")
    rtype = (r.get("type") or "")
    # Location-wide NotAvailableForSubscription is a hard no.
    # Zone restrictions often list a subset of AZs and are not fatal.
    if rtype == "Location" and reason == "NotAvailableForSubscription":
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
      echo "    skip ${size}: location-wide SKU restriction in ${location}" >&2
      continue
    fi
    printf '%s\n' "${size}"
    return 0
  done
  return 1
}
