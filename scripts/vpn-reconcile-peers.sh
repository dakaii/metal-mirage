#!/usr/bin/env bash
# Push control-plane (Neon) peers onto the VPN VM's WireGuard interface.
# Desired state = Postgres peers for this city; VM is the projection.
#
# Usage:
#   DATABASE_URL='postgres://…' ./scripts/vpn-reconcile-peers.sh
#   DATABASE_URL='…' ./scripts/vpn-reconcile-peers.sh --dry-run
#   DATABASE_URL='…' ./scripts/vpn-reconcile-peers.sh --prune
#   RECONCILE_I_MEAN_IT=1 … --prune   # required if DB has zero peers for the city
#
# Requires: pulumi, ssh, go (for control-plane/cmd/listpeers); python3 if loading control-plane/.env.
# Does not put Neon credentials on the VPN VM — runs from the operator laptop.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "${ROOT}/scripts/lib.sh"
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

need pulumi "Install: https://www.pulumi.com/docs/install/"
need ssh
need go "Needed for control-plane/cmd/listpeers (Go 1.26.x)."

if [[ -z "${DATABASE_URL:-}" && -f "${ROOT}/control-plane/.env" ]]; then
  need python3 "Needed to load DATABASE_URL from control-plane/.env"
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

select_stack infra/vpn-gateways
PUBLIC_IP="$(require_stack_output infra/vpn-gateways publicIP "run ./scripts/up.sh vpn first")"
SSH_USER="$(require_stack_output infra/vpn-gateways sshUser "run ./scripts/up.sh vpn first")"
CITY="$(require_stack_output infra/vpn-gateways city "run ./scripts/up.sh vpn first")"

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
  if [[ "${DESIRED_COUNT}" -eq 0 && "${RECONCILE_I_MEAN_IT:-}" != "1" ]]; then
    echo "refusing --prune with zero DB peers for city=${CITY} (would remove every WireGuard peer on the VM)" >&2
    echo "re-run with RECONCILE_I_MEAN_IT=1 if that wipe is intentional" >&2
    exit 1
  fi
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
