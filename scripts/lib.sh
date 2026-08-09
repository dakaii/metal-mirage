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
