#!/usr/bin/env bash
# After vpn stack is up: fetch server pubkey and write a local peer config.
# Usage: ./scripts/vpn-bootstrap.sh [peer-name]
# Client configs land in vpn-clients/ (gitignored). Full-tunnel AllowedIPs.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "${ROOT}/scripts/lib.sh"
PEER="${1:-laptop}"
OUT_DIR="${ROOT}/vpn-clients"
STACK="${PULUMI_STACK:-dev}"
mkdir -p "${OUT_DIR}"

need wg "On macOS: brew install wireguard-tools"
need pulumi "Install: https://www.pulumi.com/docs/install/"
need ssh

select_stack infra/vpn-gateways
PUBLIC_IP="$(require_stack_output infra/vpn-gateways publicIP "run ./scripts/up.sh vpn first")"
SSH_USER="$(require_stack_output infra/vpn-gateways sshUser "run ./scripts/up.sh vpn first")"
CITY="$(require_stack_output infra/vpn-gateways city "run ./scripts/up.sh vpn first")"
cd "${ROOT}/infra/vpn-gateways"

echo "==> Fetching server public key from ${SSH_USER}@${PUBLIC_IP}"
# Wait briefly for cloud-init on fresh VMs.
for _ in $(seq 1 30); do
  if SERVER_PUB="$(ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
      "${SSH_USER}@${PUBLIC_IP}" 'sudo cat /etc/wireguard/server.pub' 2>/dev/null)"; then
    break
  fi
  echo "waiting for WireGuard bootstrap on ${PUBLIC_IP}..."
  sleep 10
done
if [[ -z "${SERVER_PUB:-}" ]]; then
  echo "could not read /etc/wireguard/server.pub — check cloud-init / SSH / adminCidr" >&2
  exit 1
fi

umask 077
PEER_PRIV="$(wg genkey)"
PEER_PUB="$(printf '%s' "${PEER_PRIV}" | wg pubkey)"

# Allocate the lowest free 10.66.0.2–251 by inspecting peers already on the VM.
# Matches control-plane's pool math, but reads live wg state (not the Neon DB).
# After minting peers via control-plane, sync with ./scripts/vpn-reconcile-peers.sh.
USED_OCTETS="$(ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
  "${SSH_USER}@${PUBLIC_IP}" \
  "sudo wg show wg0 allowed-ips 2>/dev/null || true" |
  grep -oE '10\.66\.0\.[0-9]+' | awk -F. '{print $4}' | sort -n | uniq || true)"
OCTET="$(awk '
  BEGIN { for (i = 2; i <= 251; i++) free[i] = 1 }
  NF { free[$1 + 0] = 0 }
  END {
    for (i = 2; i <= 251; i++) if (free[i]) { print i; exit }
  }
' <<< "${USED_OCTETS}")"
if [[ -z "${OCTET}" ]]; then
  echo "peer IP pool exhausted on ${PUBLIC_IP} (10.66.0.2–251)" >&2
  exit 1
fi
PEER_IP="10.66.0.${OCTET}"

CONF="${OUT_DIR}/${CITY}-${PEER}.conf"
cat > "${CONF}" <<EOF
[Interface]
PrivateKey = ${PEER_PRIV}
Address = ${PEER_IP}/32
DNS = 1.1.1.1

[Peer]
PublicKey = ${SERVER_PUB}
Endpoint = ${PUBLIC_IP}:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF

echo "==> Adding peer on server (${PEER_IP})"
# Expand peer vars locally so the remote shell receives concrete values.
# shellcheck disable=SC2029
ssh "${SSH_USER}@${PUBLIC_IP}" \
  "sudo wg set wg0 peer ${PEER_PUB} allowed-ips ${PEER_IP}/32 && sudo wg-quick save wg0"

echo "Client config written to ${CONF} (gitignored)"
echo "Import into the official WireGuard app, then: curl ifconfig.me"
echo "Honesty: AllowedIPs is full-tunnel — all device traffic exits via this city VM."
