#!/usr/bin/env bash
# Interactive helper: ensure Azure CLI + Pulumi sessions, optional control-plane checks.
#
# Usage:
#   ./scripts/login.sh                 # az + pulumi (login if needed)
#   ./scripts/login.sh --status        # report only (no browser prompts)
#   ./scripts/login.sh --local-pulumi  # pulumi login --local instead of cloud backend
#   ./scripts/login.sh --control-plane # also check control-plane/.env (Clerk + Neon)
#   ./scripts/login.sh --clerk-keyless # print/run Clerk keyless setup hints
#
# Does not store secrets. Browser / device-code flows belong to az / pulumi / clerk.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "${ROOT}/scripts/lib.sh"

STATUS_ONLY=0
DO_AZURE=1
DO_PULUMI=1
LOCAL_PULUMI=0
CHECK_CP=0
CLERK_KEYLESS=0
FORCE=0

usage() {
  cat <<'EOF' >&2
usage: ./scripts/login.sh [flags]

  (default)         Ensure Azure CLI + Pulumi are logged in (prompts if needed)
  --status          Report auth state only; never open a login flow
  --force           Re-run az/pulumi login even if already authenticated
  --skip-azure      Skip Azure CLI
  --skip-pulumi     Skip Pulumi
  --local-pulumi    Use `pulumi login --local` (file-backed stack state)
  --control-plane   Check control-plane/.env for DATABASE_URL + CLERK_SECRET_KEY
  --clerk-keyless   Guide Clerk keyless init (throwaway dir; see AGENTS.md)
  -h, --help        This help

Env:
  AZURE_LOGIN_FLAGS   Extra flags for `az login` (e.g. --use-device-code)
  PULUMI_LOGIN_URL    Backend URL for `pulumi login` (default: cloud / interactive)
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --status) STATUS_ONLY=1; shift ;;
    --force) FORCE=1; shift ;;
    --skip-azure) DO_AZURE=0; shift ;;
    --skip-pulumi) DO_PULUMI=0; shift ;;
    --local-pulumi) LOCAL_PULUMI=1; shift ;;
    --control-plane) CHECK_CP=1; shift ;;
    --clerk-keyless) CLERK_KEYLESS=1; shift ;;
    -h|--help) usage ;;
    *) echo "unknown arg: $1" >&2; usage ;;
  esac
done

ok() { echo "  OK  $*"; }
warn() { echo "  !!  $*" >&2; }
info() { echo "==> $*"; }

az_logged_in() {
  az account show >/dev/null 2>&1
}

pulumi_logged_in() {
  # whoami fails when no backend / not logged in
  pulumi whoami >/dev/null 2>&1
}

ensure_azure() {
  info "Azure CLI"
  if ! command -v az >/dev/null 2>&1; then
    warn "az not installed — https://learn.microsoft.com/cli/azure/install-azure-cli"
    return 1
  fi
  if [[ "${FORCE}" -eq 0 ]] && az_logged_in; then
    local name sub
    name="$(az account show --query user.name -o tsv 2>/dev/null || echo "?")"
    sub="$(az account show --query name -o tsv 2>/dev/null || echo "?")"
    ok "logged in as ${name} (subscription: ${sub})"
    return 0
  fi
  if [[ "${STATUS_ONLY}" -eq 1 ]]; then
    warn "not logged in — run: ./scripts/login.sh   (or: az login ${AZURE_LOGIN_FLAGS:-})"
    return 1
  fi
  info "Running az login ${AZURE_LOGIN_FLAGS:-}"
  # shellcheck disable=SC2086 # intentional word-split of optional flags
  az login ${AZURE_LOGIN_FLAGS:-}
  if ! az_logged_in; then
    warn "az login finished but account still unavailable"
    return 1
  fi
  ok "Azure session ready ($(az account show --query name -o tsv))"
}

ensure_pulumi() {
  info "Pulumi"
  if ! command -v pulumi >/dev/null 2>&1; then
    warn "pulumi not installed — https://www.pulumi.com/docs/install/"
    return 1
  fi
  if [[ "${FORCE}" -eq 0 ]] && pulumi_logged_in; then
    ok "logged in as $(pulumi whoami 2>/dev/null || echo '?')"
    return 0
  fi
  if [[ "${STATUS_ONLY}" -eq 1 ]]; then
    warn "not logged in — run: ./scripts/login.sh   (or: pulumi login / pulumi login --local)"
    return 1
  fi
  if [[ "${LOCAL_PULUMI}" -eq 1 ]]; then
    info "Running pulumi login --local"
    pulumi login --local
  elif [[ -n "${PULUMI_LOGIN_URL:-}" ]]; then
    info "Running pulumi login ${PULUMI_LOGIN_URL}"
    pulumi login "${PULUMI_LOGIN_URL}"
  else
    info "Running pulumi login (cloud — follow browser / token prompt)"
    pulumi login
  fi
  if ! pulumi_logged_in; then
    warn "pulumi login finished but whoami still fails"
    return 1
  fi
  ok "Pulumi backend ready ($(pulumi whoami))"
}

# Read a KEY=value from control-plane/.env without sourcing (DATABASE_URL may contain &).
env_file_get() {
  local file="$1" key="$2"
  [[ -f "${file}" ]] || return 1
  need python3 "Needed to parse control-plane/.env safely"
  python3 - "$file" "$key" <<'PY'
from pathlib import Path
import sys
path, key = Path(sys.argv[1]), sys.argv[2]
for raw in path.read_text().splitlines():
    line = raw.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    k, _, v = line.partition("=")
    if k.strip() == key:
        print(v.strip().strip("'").strip('"'))
        sys.exit(0)
sys.exit(1)
PY
}

check_control_plane() {
  info "control-plane/.env"
  local envf="${ROOT}/control-plane/.env"
  if [[ ! -f "${envf}" ]]; then
    warn "missing ${envf}"
    echo "  cp control-plane/.env.example control-plane/.env  # then fill DATABASE_URL + CLERK_SECRET_KEY" >&2
    echo "  Neon: https://neon.tech — create a project and copy the connection string" >&2
    echo "  Clerk: ./scripts/login.sh --clerk-keyless   (or see AGENTS.md)" >&2
    return 1
  fi
  local db clerk rc=0
  db="$(env_file_get "${envf}" DATABASE_URL || true)"
  clerk="$(env_file_get "${envf}" CLERK_SECRET_KEY || true)"
  if [[ -z "${db}" || "${db}" == *"USER:PASSWORD"* || "${db}" == *"REPLACE_ME"* ]]; then
    warn "DATABASE_URL missing or still a placeholder"
    rc=1
  else
    ok "DATABASE_URL set (value not printed)"
  fi
  if [[ -z "${clerk}" || "${clerk}" == REPLACE_ME* || "${clerk}" == "clerk_key_invalid" ]]; then
    warn "CLERK_SECRET_KEY missing, placeholder, or invalid short stub"
    echo "  ./scripts/login.sh --clerk-keyless" >&2
    rc=1
  else
    ok "CLERK_SECRET_KEY set (value not printed)"
  fi
  return "${rc}"
}

clerk_keyless_guide() {
  info "Clerk keyless (optional control-plane demo)"
  if [[ "${STATUS_ONLY}" -eq 1 ]]; then
    echo "  Prefer: brew install clerk/stable/clerk"
    echo "  Then (outside this repo): clerk init --framework next --keyless -y --mode agent --no-skills --pm npm"
    echo "  Copy CLERK_SECRET_KEY into control-plane/.env — details in AGENTS.md"
    return 0
  fi
  if ! command -v clerk >/dev/null 2>&1; then
    if command -v brew >/dev/null 2>&1; then
      info "Installing Clerk CLI via Homebrew"
      brew install clerk/stable/clerk
    else
      warn "clerk CLI not found and brew unavailable"
      echo "  Install: brew install clerk/stable/clerk" >&2
      echo "  Or: npx -y clerk@latest init --framework next --keyless -y --mode agent --no-skills --pm npm" >&2
      echo "  Full notes: AGENTS.md" >&2
      return 1
    fi
  fi
  need clerk
  local tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/metal-mirage-clerk.XXXXXX")"
  info "Throwaway dir: ${tmp}"
  echo "  Unsetting CLERK_SECRET_KEY for this process (godotenv / inherited stubs)…"
  (
    cd "${tmp}"
    unset CLERK_SECRET_KEY
    clerk init --framework next --keyless -y --mode agent --no-skills --pm npm
  )
  local envlocal
  envlocal="$(find "${tmp}" -name '.env.local' -type f 2>/dev/null | head -1 || true)"
  if [[ -n "${envlocal}" ]]; then
    ok "keys written under ${envlocal}"
    echo "  Copy CLERK_SECRET_KEY into ${ROOT}/control-plane/.env (do not commit)."
  else
    warn "could not find .env.local under ${tmp} — check clerk output"
    return 1
  fi
}

rc=0

if [[ "${DO_AZURE}" -eq 1 ]]; then
  ensure_azure || rc=1
fi
if [[ "${DO_PULUMI}" -eq 1 ]]; then
  ensure_pulumi || rc=1
fi
if [[ "${CHECK_CP}" -eq 1 ]]; then
  check_control_plane || rc=1
fi
if [[ "${CLERK_KEYLESS}" -eq 1 ]]; then
  clerk_keyless_guide || rc=1
fi

if [[ "${DO_AZURE}" -eq 0 && "${DO_PULUMI}" -eq 0 && "${CHECK_CP}" -eq 0 && "${CLERK_KEYLESS}" -eq 0 ]]; then
  warn "nothing to do (all checks skipped)"
  exit 1
fi

if [[ "${rc}" -eq 0 ]]; then
  info "Ready. Next: ./scripts/register-talos-image.sh eastus   # or ./scripts/up.sh primary"
else
  info "One or more checks failed (see !! above)."
fi
exit "${rc}"
