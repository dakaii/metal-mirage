#!/usr/bin/env bash
# Print a kube-prometheus-stack Helm values fragment to scrape VPN node_exporter.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "${ROOT}/scripts/lib.sh"
STACK="${PULUMI_STACK:-dev}"

need pulumi "Install: https://www.pulumi.com/docs/install/"

select_stack infra/vpn-gateways
IP="$(require_stack_output infra/vpn-gateways publicIP "run ./scripts/up.sh vpn first")"
PORT="$(require_stack_output infra/vpn-gateways metricsPort "run ./scripts/up.sh vpn first")"
CITY="$(require_stack_output infra/vpn-gateways city "run ./scripts/up.sh vpn first")"

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
