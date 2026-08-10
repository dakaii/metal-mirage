#!/usr/bin/env bash
# Print a kube-prometheus-stack Helm values fragment to scrape VPN node_exporter.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "${ROOT}/scripts/lib.sh"
STACK="${PULUMI_STACK:-dev}"

need pulumi "Install: https://www.pulumi.com/docs/install/"

VPN_DIR="$(require_remote_access_dir)"
select_stack "${VPN_DIR}"
IP="$(require_stack_output "${VPN_DIR}" publicIP "run ./scripts/up.sh vpn first")"
PORT="$(require_stack_output "${VPN_DIR}" metricsPort "run ./scripts/up.sh vpn first")"
CITY="$(require_stack_output "${VPN_DIR}" city "run ./scripts/up.sh vpn first")"

cat <<EOF
# stack=${STACK}  target=${IP}:${PORT}  city=${CITY}
# Merge under kube-prometheus-stack Helm values, then helm upgrade / Flux reconcile.
#
# Reachability: vpn:adminCidr gates TCP ${PORT}. If it is your laptop /32, in-cluster
# Prometheus cannot scrape the public IP — widen NSG, scrape via an admin jump host,
# or temporarily use 0.0.0.0/0 for demos. Peer/handshake metrics need a WG exporter (not in V1).
prometheus:
  prometheusSpec:
    additionalScrapeConfigs:
      - job_name: vpn-gateway
        metrics_path: /metrics
        static_configs:
          - targets: ['${IP}:${PORT}']
            labels:
              city: ${CITY}
              role: vpn-gateway
EOF
