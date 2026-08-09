# Consumer VPN

Full-tunnel WireGuard exit on a dedicated Azure VM (cloud-init — **no Ansible**).
Stock WireGuard clients only. Not on the HTTP/demo path (Azure LB → NodePort).

## Product vs platform

| Plane | Role |
|-------|------|
| WireGuard gateway | Device traffic → NAT → internet |
| Talos + Flux + demo LB | Operate/monitor the platform (portfolio path: Azure LB → NodePort `30080`, no Traefik) |

## Deploy

```bash
./scripts/up.sh vpn
./scripts/vpn-bootstrap.sh laptop
```

Import `vpn-clients/us-laptop.conf` into the official WireGuard app.

### Optional: sync control-plane peers → VM

If you mint peers via the Clerk + Neon API (`control-plane/`), project them onto WireGuard:

```bash
DATABASE_URL='…' ./scripts/vpn-reconcile-peers.sh          # upsert
DATABASE_URL='…' ./scripts/vpn-reconcile-peers.sh --prune  # also remove WG peers not in DB
DATABASE_URL='…' ./scripts/vpn-reconcile-peers.sh --dry-run
# Empty DB + --prune refuses unless intentional:
# RECONCILE_I_MEAN_IT=1 DATABASE_URL='…' ./scripts/vpn-reconcile-peers.sh --prune
```

Reads Neon directly (not the per-user HTTP API); SSHs like `vpn-bootstrap.sh`. Default is **no prune** so bootstrap-only peers survive. `--prune` with zero DB peers for the city is refused unless `RECONCILE_I_MEAN_IT=1`.

## Monitoring

Ceiling for V1: **host metrics via node_exporter** (CPU/mem/disk/net). No peer/handshake metrics (no WireGuard exporter).

```bash
./scripts/vpn-prometheus-scrape-snippet.sh   # Helm values fragment for additionalScrapeConfigs
```

Merge into kube-prometheus-stack, then upgrade/reconcile. Grafana dashboard ConfigMap `grafana-dashboard-vpn` (label `grafana_dashboard=1`) loads via the usual sidecar.

Alert samples: `gitops/infrastructure/monitoring/optional/prometheus-rules-vpn.yaml` (needs PrometheusRule CRD) — `VPNGatewayDown` / disk / memory.

`vpn:adminCidr` locks SSH and **TCP 9100** (node_exporter). WireGuard UDP `51820` stays open for remote peers. If `adminCidr` is your laptop `/32`, in-cluster Prometheus cannot scrape the public IP — widen NSG, use a jump host, or temporarily `0.0.0.0/0` for demos.

## Honesty

- Default demo uses an **Azure public IP**, not home bare metal.
- Client configs use **full-tunnel** `AllowedIPs` — all device traffic exits via the city VM.
- `vpn-clients/*.conf` is gitignored (private keys).
- Home-as-exit needs inbound UDP 51820 (no CGNAT) and DDNS; ISP ToS may forbid hosting.
- Multi-city = another vpn stack/region; clients switch profiles manually (no auto peer failover in V1).
