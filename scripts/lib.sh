# Shared helpers for metal-mirage scripts.
# shellcheck shell=bash
# Caller must set ROOT (and STACK when using stack helpers) before sourcing.

need() {
  # need <binary> [hint]
  local bin="$1" hint="${2:-}"
  if command -v "${bin}" >/dev/null 2>&1; then
    return 0
  fi
  echo "missing required tool: ${bin}" >&2
  if [[ -n "${hint}" ]]; then
    echo "  ${hint}" >&2
  fi
  echo "  Run scripts as ./scripts/<name>.sh from the repo root." >&2
  exit 1
}

yaml_section_key() {
  # yaml_section_key <section> <key> — first matching key under a top-level section
  local section="$1" key="$2"
  # shellcheck disable=SC2154 # ROOT is required from the sourcing script
  local file="${ROOT}/config/clusters.yaml"
  awk -v section="${section}:" -v key="${key}" '
    $0 ~ "^" section { in_section=1; next }
    in_section && /^[a-zA-Z]/ { exit }
    in_section && $0 ~ "^[[:space:]]*" key ":" {
      sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "", $0)
      gsub(/["\r]/, "", $0)
      # strip inline comments
      sub(/[[:space:]]+#.*$/, "", $0)
      print $0
      exit
    }
  ' "${file}" 2>/dev/null || true
}

remote_access_provider() {
  # remote_access_provider — wireguard (default) | none
  local p=""
  p="$(yaml_section_key remote_access provider)"
  p="$(printf '%s' "${p}" | tr -d '[:space:]')"
  if [[ -z "${p}" ]]; then
    echo "wireguard"
    return 0
  fi
  printf '%s\n' "${p}"
}

resolve_pulumi_dir() {
  # resolve_pulumi_dir <profile>  — reads config/clusters.yaml pulumi_dir
  # Profiles: primary | standby | shared | vpn | remote_access
  # For vpn/remote_access: prefer remote_access.pulumi_dir, then vpn.pulumi_dir.
  local profile="$1"
  local dir=""

  case "${profile}" in
    vpn | remote_access)
      if [[ "$(remote_access_provider)" == "none" ]]; then
        # Caller should no-op; empty signals disabled RemoteAccess plane.
        return 0
      fi
      dir="$(yaml_section_key remote_access pulumi_dir)"
      if [[ -z "${dir}" ]]; then
        dir="$(yaml_section_key vpn pulumi_dir)"
      fi
      if [[ -n "${dir}" ]]; then
        printf '%s\n' "${dir}"
        return 0
      fi
      echo "infra/vpn-gateways"
      return 0
      ;;
  esac

  dir="$(yaml_section_key "${profile}" pulumi_dir)"
  if [[ -n "${dir}" ]]; then
    printf '%s\n' "${dir}"
    return 0
  fi
  case "${profile}" in
    primary) echo "infra/primary" ;;
    standby) echo "infra/standby-aks" ;;
    shared) echo "infra/shared" ;;
    *) return 1 ;;
  esac
}

select_stack() {
  # select_stack <infra-dir> — requires ROOT + STACK; friendly error if missing
  local dir="$1"
  # shellcheck disable=SC2154
  if ! (
    cd "${ROOT}/${dir}" || exit 1
    pulumi stack select "${STACK}" >/dev/null 2>&1
  ); then
    echo "pulumi stack '${STACK}' not found in ${dir} — run ./scripts/up.sh … first (or set PULUMI_STACK)" >&2
    exit 1
  fi
}

require_stack_output() {
  # require_stack_output <infra-dir> <output-name> [hint]
  # Prints the output value; exits non-zero if empty/null/missing.
  local dir="$1" name="$2" hint="${3:-}"
  local val=""
  # shellcheck disable=SC2154
  val="$(
    cd "${ROOT}/${dir}" || exit 0
    pulumi stack select "${STACK}" >/dev/null 2>&1 || exit 0
    pulumi stack output "${name}" 2>/dev/null || exit 0
  )"
  if [[ -z "${val}" || "${val}" == "null" ]]; then
    echo "missing stack output ${name} from ${dir} (stack=${STACK})" >&2
    if [[ -n "${hint}" ]]; then
      echo "  ${hint}" >&2
    fi
    exit 1
  fi
  printf '%s\n' "${val}"
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
