#!/usr/bin/env bash
# Push control-plane (Neon) peers onto the VPN VM's WireGuard interface.
# Desired state = Postgres peers for this city; VM is the projection.
#
# Usage:
#   DATABASE_URL='postgres://…' ./scripts/vpn-reconcile-peers.sh
#   DATABASE_URL='…' ./scripts/vpn-reconcile-peers.sh --dry-run
#   DATABASE_URL='…' ./scripts/vpn-reconcile-peers.sh --prune
#
# Requires: pulumi, ssh, go (for control-plane/cmd/listpeers).
# Does not put Neon credentials on the VPN VM — runs from the operator laptop.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STACK="${PULUMI_STACK:-dev}"
DRY_RUN=0
PRUNE=0

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --prune) PRUNE=1 ;;
    -h | --help) usage ;;
    *)
      echo "unknown arg: $1" >&2
      usage
      ;;
  esac
  shift
done

if [[ -z "${DATABASE_URL:-}" && -f "${ROOT}/control-plane/.env" ]]; then
  # Load DSN without `set -a; source` (ampersands in query params break that).
  DATABASE_URL="$(
    python3 - <<PY
from pathlib import Path
p = Path("${ROOT}/control-plane/.env")
for line in p.read_text().splitlines():
    if line.startswith("DATABASE_URL="):
        print(line.split("=", 1)[1].strip().strip("'").strip('"'))
        break
PY
  )"
fi
if [[ -z "${DATABASE_URL:-}" ]]; then
  echo "DATABASE_URL is required (env or control-plane/.env)" >&2
  exit 1
fi
export DATABASE_URL

command -v pulumi >/dev/null || {
  echo "missing pulumi" >&2
  exit 1
}
command -v ssh >/dev/null || {
  echo "missing ssh" >&2
  exit 1
}
command -v go >/dev/null || {
  echo "missing go (needed for control-plane/cmd/listpeers)" >&2
  exit 1
}

cd "${ROOT}/infra/vpn-gateways"
if ! pulumi stack select "${STACK}" >/dev/null 2>&1; then
  echo "pulumi stack '${STACK}' not found in infra/vpn-gateways — run ./scripts/up.sh vpn first (or set PULUMI_STACK)" >&2
  exit 1
fi
PUBLIC_IP="$(pulumi stack output publicIP)"
SSH_USER="$(pulumi stack output sshUser)"
CITY="$(pulumi stack output city)"

if [[ -z "${PUBLIC_IP}" || "${PUBLIC_IP}" == "null" ]]; then
  echo "vpn stack has no publicIP — run ./scripts/up.sh vpn first" >&2
  exit 1
fi

SSH=(ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 "${SSH_USER}@${PUBLIC_IP}")

echo "==> Listing Neon peers for city=${CITY}"
PEERS_TSV="$(
  cd "${ROOT}/control-plane"
  go run ./cmd/listpeers -city "${CITY}"
)"

DESIRED_FILE="$(mktemp)"
WG_DUMP_FILE="$(mktemp)"
trap 'rm -f "${DESIRED_FILE}" "${WG_DUMP_FILE}"' EXIT

# public_key -> allocated_ip
: >"${DESIRED_FILE}"
if [[ -n "${PEERS_TSV}" ]]; then
  while IFS=$'\t' read -r pub ip name id; do
    [[ -z "${pub}" || -z "${ip}" ]] && continue
    printf '%s\t%s\t%s\t%s\n' "${pub}" "${ip}" "${name:-}" "${id:-}" >>"${DESIRED_FILE}"
  done <<<"${PEERS_TSV}"
fi
DESIRED_COUNT="$(wc -l <"${DESIRED_FILE}" | tr -d ' ')"
echo "    desired peers: ${DESIRED_COUNT}"

echo "==> Reading live WireGuard peers on ${SSH_USER}@${PUBLIC_IP}"
# wg show dump: line 1 = interface; remaining = peers (pubkey in field 1).
"${SSH[@]}" 'sudo wg show wg0 dump' >"${WG_DUMP_FILE}" || {
  echo "could not read wg0 dump — is WireGuard up / SSH / adminCidr ok?" >&2
  exit 1
}

# Build maps via awk for conflict checks.
CONFLICTS="$(
  awk -F'\t' '
    NR==FNR {
      if (NF < 2) next
      pub=$1; ip=$2
      gsub(/\/.*/, "", ip)
      desired_pub[pub]=ip
      if (ip in desired_ip && desired_ip[ip] != pub) {
        print "DB conflict: IP " ip " claimed by multiple pubkeys"
      }
      desired_ip[ip]=pub
      next
    }
    FNR==1 { next } # skip interface line
    {
      pub=$1
      # allowed-ips is field 4 in `wg show dump`
      split($4, a, /,/)
      ip=""
      for (i in a) {
        if (a[i] ~ /^10\.66\.0\.[0-9]+/) {
          ip=a[i]; sub(/\/.*/, "", ip); break
        }
      }
      live_pub[pub]=ip
      if (ip != "") live_ip[ip]=pub
    }
    END {
      for (pub in desired_pub) {
        ip=desired_pub[pub]
        if ((ip in live_ip) && live_ip[ip] != pub) {
          print "conflict: IP " ip " on VM is pubkey " live_ip[ip] " but DB wants " pub
        }
        if ((pub in live_pub) && live_pub[pub] != "" && live_pub[pub] != ip) {
          print "conflict: pubkey " pub " on VM has IP " live_pub[pub] " but DB wants " ip
        }
      }
    }
  ' "${DESIRED_FILE}" "${WG_DUMP_FILE}"
)"
if [[ -n "${CONFLICTS}" ]]; then
  echo "${CONFLICTS}" >&2
  echo "refusing to reconcile with conflicts (fix DB or VM manually)" >&2
  exit 1
fi

apply_one() {
  local pub="$1" ip="$2" name="$3"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo "    [dry-run] wg set peer ${pub:0:16}… allowed-ips ${ip}/32 (${name})"
    return 0
  fi
  # shellcheck disable=SC2029
  "${SSH[@]}" "sudo wg set wg0 peer ${pub} allowed-ips ${ip}/32"
  echo "    upserted ${ip} (${name})"
}

echo "==> Upserting desired peers"
if [[ "${DESIRED_COUNT}" -eq 0 ]]; then
  echo "    (none)"
else
  while IFS=$'\t' read -r pub ip name id; do
    apply_one "${pub}" "${ip}" "${name}"
  done <"${DESIRED_FILE}"
fi

if [[ "${PRUNE}" -eq 1 ]]; then
  echo "==> Pruning WireGuard peers not in DB for city=${CITY}"
  # Peers on VM whose pubkey is absent from desired set.
  EXTRA="$(
    awk -F'\t' '
      NR==FNR { desired[$1]=1; next }
      FNR==1 { next }
      !($1 in desired) { print $1 }
    ' "${DESIRED_FILE}" "${WG_DUMP_FILE}"
  )"
  if [[ -z "${EXTRA}" ]]; then
    echo "    (none)"
  else
    while read -r pub; do
      [[ -z "${pub}" ]] && continue
      if [[ "${DRY_RUN}" -eq 1 ]]; then
        echo "    [dry-run] wg set peer ${pub:0:16}… remove"
        continue
      fi
      # shellcheck disable=SC2029
      "${SSH[@]}" "sudo wg set wg0 peer ${pub} remove"
      echo "    removed ${pub:0:20}…"
    done <<<"${EXTRA}"
  fi
else
  echo "==> Skipping prune (pass --prune to remove VM peers absent from DB)"
  echo "    note: peers created only via vpn-bootstrap.sh are left alone without --prune"
fi

if [[ "${DRY_RUN}" -eq 0 ]]; then
  echo "==> Saving WireGuard config"
  "${SSH[@]}" 'sudo wg-quick save wg0'
fi

echo "Done. DB is source of truth for city=${CITY}; VM projection updated."
echo "Honesty: DELETE /api/peers only removes the DB row — re-run with --prune to drop it from wg."
