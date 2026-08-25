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
  # remote_access_provider — none (platform default) | wireguard
  local p=""
  p="$(yaml_section_key remote_access provider)"
  p="$(printf '%s' "${p}" | tr -d '[:space:]')"
  if [[ -z "${p}" ]]; then
    echo "none"
    return 0
  fi
  printf '%s\n' "${p}"
}

require_remote_access_dir() {
  # require_remote_access_dir — prints adapter pulumi dir; exits if RemoteAccess disabled/unresolved
  if [[ "$(remote_access_provider)" == "none" ]]; then
    echo "remote_access.provider=none — enable wireguard (or set remote_access.provider) before using VPN adapter scripts" >&2
    echo "  See docs/CAPABILITY-PORTS.md" >&2
    exit 1
  fi
  local dir=""
  dir="$(resolve_pulumi_dir vpn)"
  if [[ -z "${dir}" ]]; then
    echo "remote_access.pulumi_dir unresolved (set remote_access.pulumi_dir or vpn.pulumi_dir in config/clusters.yaml)" >&2
    exit 1
  fi
  printf '%s\n' "${dir}"
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

# --- Azure subscription pin (config/clusters.yaml → azure.subscription_id) ---

azure_subscription_id_config() {
  # Prefer azure.subscription_id; accept legacy azure.subscription as alias.
  local id=""
  id="$(yaml_section_key azure subscription_id)"
  id="$(printf '%s' "${id}" | tr -d '[:space:]')"
  if [[ -z "${id}" ]]; then
    id="$(yaml_section_key azure subscription)"
    id="$(printf '%s' "${id}" | tr -d '[:space:]')"
  fi
  printf '%s\n' "${id}"
}

# Returns 0 when this up/destroy target talks to Azure ARM.
# Usage: target_needs_azure_subscription <target> [up|destroy]
#   up (default): standby/shared/vpn/all, or primary when azure-metal-sim
#   destroy: same, except "all" on bare-metal without azure.subscription_id
#            skips the pin (offline dry-run teardown); set the pin to verify
#            leftover metal-sim RGs on the correct sub.
target_needs_azure_subscription() {
  local target="$1" mode="${2:-up}"
  local primary_prov=""
  primary_prov="$(yaml_section_key primary provisioner | tr -d '[:space:]')"
  case "${target}" in
    standby | shared | vpn | remote_access) return 0 ;;
    all)
      if [[ "${mode}" == "destroy" ]]; then
        if [[ "${primary_prov}" == "azure-metal-sim" ]]; then
          return 0
        fi
        if [[ "$(remote_access_provider)" == "wireguard" ]]; then
          return 0
        fi
        # bare-metal destroy-all: only enforce when an explicit pin is present
        [[ -n "$(azure_subscription_id_config)" ]]
        return
      fi
      return 0
      ;;
    primary)
      [[ "${primary_prov}" == "azure-metal-sim" ]]
      ;;
    *) return 1 ;;
  esac
}

# Pure check (testable): expected UUID vs actual UUID (case-insensitive).
# Exit 0 on match; 1 on mismatch. Empty expected is caller's problem.
assert_azure_subscription_match() {
  local expected="$1" actual="$2"
  local e a
  e="$(printf '%s' "${expected}" | tr '[:upper:]' '[:lower:]')"
  a="$(printf '%s' "${actual}" | tr '[:upper:]' '[:lower:]')"
  if [[ "${e}" == "${a}" ]]; then
    return 0
  fi
  return 1
}

# Enforce azure.subscription_id against `az account show` for Azure lab paths.
# Env:
#   SKIP_AZURE_SUBSCRIPTION_CHECK=1  — no-op (CI / emergencies)
#   ALLOW_UNPINNED_AZURE_SUB=1       — allow Azure paths when pin unset (loud warn)
require_azure_subscription() {
  local want="" got="" name=""
  if [[ "${SKIP_AZURE_SUBSCRIPTION_CHECK:-0}" == "1" ]]; then
    echo "==> SKIP_AZURE_SUBSCRIPTION_CHECK=1 — not verifying Azure subscription"
    return 0
  fi
  want="$(azure_subscription_id_config)"
  if [[ -z "${want}" ]]; then
    if [[ "${ALLOW_UNPINNED_AZURE_SUB:-0}" == "1" ]]; then
      echo "warn: azure.subscription_id unset — ALLOW_UNPINNED_AZURE_SUB=1 continuing" >&2
      echo "  Pin a dedicated lab sub in config/clusters.yaml (see docs/COST.md)." >&2
      return 0
    fi
    echo "error: azure.subscription_id is required before Azure lab up/destroy" >&2
    echo "  Add to config/clusters.yaml:" >&2
    echo "    azure:" >&2
    echo "      subscription_id: \"$(az account show --query id -o tsv 2>/dev/null || echo '<subscription-guid>')\"" >&2
    echo "  Prefer a dedicated metal-mirage subscription (do not reuse ZeroClaw/Banjar/etc.)." >&2
    echo "  Escape hatch (not recommended): ALLOW_UNPINNED_AZURE_SUB=1" >&2
    echo "  See docs/COST.md · docs/DEPLOY.md" >&2
    exit 1
  fi
  if ! command -v az >/dev/null 2>&1; then
    echo "error: az CLI required to verify azure.subscription_id=${want}" >&2
    echo "  Install: https://learn.microsoft.com/cli/azure/install-azure-cli" >&2
    exit 1
  fi
  if ! az account show >/dev/null 2>&1; then
    echo "error: not logged into Azure — run ./scripts/login.sh (or az login)" >&2
    exit 1
  fi
  got="$(az account show --query id -o tsv 2>/dev/null || true)"
  name="$(az account show --query name -o tsv 2>/dev/null || echo '?')"
  if [[ -z "${got}" ]]; then
    echo "error: could not read current Azure subscription id" >&2
    exit 1
  fi
  if ! assert_azure_subscription_match "${want}" "${got}"; then
    echo "error: Azure subscription mismatch — refusing to continue" >&2
    echo "  config azure.subscription_id: ${want}" >&2
    echo "  az account (current):          ${got} (${name})" >&2
    echo "  Fix: az account set --subscription ${want}" >&2
    echo "  Or update azure.subscription_id in config/clusters.yaml if this lab moved." >&2
    exit 1
  fi
  echo "==> Azure subscription OK (${name} / ${got})"
}
