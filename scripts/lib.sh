# Shared helpers for metal-mirage scripts.
# shellcheck shell=bash
# Caller must set ROOT (and STACK when using stack_output) before sourcing.
resolve_pulumi_dir() {
  # resolve_pulumi_dir <profile>  — reads config/clusters.yaml pulumi_dir
  local profile="$1"
  # shellcheck disable=SC2154 # ROOT is required from the sourcing script
  local file="${ROOT}/config/clusters.yaml"
  local dir=""
  dir="$(awk -v profile="${profile}:" '
    $0 ~ "^" profile { in_section=1; next }
    in_section && /^[a-zA-Z]/ { exit }
    in_section && /^[[:space:]]*pulumi_dir:[[:space:]]*/ {
      sub(/^[[:space:]]*pulumi_dir:[[:space:]]*/, "", $0)
      gsub(/["\r]/, "", $0)
      print $0
      exit
    }
  ' "${file}" 2>/dev/null || true)"
  if [[ -n "${dir}" ]]; then
    printf '%s\n' "${dir}"
    return 0
  fi
  case "${profile}" in
    primary) echo "infra/primary" ;;
    standby) echo "infra/standby-aks" ;;
    shared) echo "infra/shared" ;;
    vpn) echo "infra/vpn-gateways" ;;
    *) return 1 ;;
  esac
}

stack_output() {
  # Usage: stack_output <infra-dir> <output-name>
  # Soft-fail: empty string if stack/output unavailable.
  # Requires ROOT and STACK from the sourcing script.
  local dir="$1" name="$2"
  (
    # shellcheck disable=SC2154 # ROOT/STACK required from the sourcing script
    cd "${ROOT}/${dir}" || exit 0
    pulumi stack select "${STACK}" >/dev/null 2>&1 || exit 0
    pulumi stack output "${name}" 2>/dev/null || exit 0
  )
}
