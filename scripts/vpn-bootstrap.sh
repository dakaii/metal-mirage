#!/usr/bin/env bash
# After vpn stack is up: fetch server pubkey and write a local peer config.
# Usage: ./scripts/vpn-bootstrap.sh [peer-name]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PEER="${1:-laptop}"
OUT_DIR="${ROOT}/vpn-clients"
mkdir -p "${OUT_DIR}"

cd "${ROOT}/infra/vpn-gateways"
PUBLIC_IP="$(pulumi stack output publicIP)"
SSH_USER="$(pulumi stack output sshUser)"
CITY="$(pulumi stack output city)"

echo "==> Fetching server public key from ${SSH_USER}@${PUBLIC_IP}"
SERVER_PUB="$(ssh -o StrictHostKeyChecking=accept-new "${SSH_USER}@${PUBLIC_IP}" 'sudo cat /etc/wireguard/server.pub')"

umask 077
PEER_PRIV="$(wg genkey)"
PEER_PUB="$(printf '%s' "${PEER_PRIV}" | wg pubkey)"

# Allocate a simple host octet from peer name hash (demo-quality)
OCTET=$(( ( $(printf '%s' "${PEER}" | cksum | awk '{print $1}') % 250 ) + 2 ))
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

echo "==> Adding peer on server"
ssh "${SSH_USER}@${PUBLIC_IP}" "sudo wg set wg0 peer ${PEER_PUB} allowed-ips ${PEER_IP}/32 && sudo wg-quick save wg0"

echo "Client config written to ${CONF}"
echo "Import into the official WireGuard app, then: curl ifconfig.me"
