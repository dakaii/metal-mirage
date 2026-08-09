# Consumer VPN

Full-tunnel WireGuard exit on a dedicated Azure VM (cloud-init — **no Ansible**).
Stock WireGuard clients only. Not on the Traefik/HTTP path.

## Product vs platform

| Plane | Role |
|-------|------|
| WireGuard gateway | Device traffic → NAT → internet |
| Talos + Flux + Traefik | Operate/monitor the platform |

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
```

Reads Neon directly (not the per-user HTTP API); SSHs like `vpn-bootstrap.sh`. Default is **no prune** so bootstrap-only peers survive.

## Monitoring

```bash
./scripts/vpn-prometheus-scrape-snippet.sh
```

Alert samples: `gitops/infrastructure/monitoring/optional/prometheus-rules-vpn.yaml` (needs PrometheusRule CRD). Hints ship in the default monitoring kustomization.

`vpn:adminCidr` locks SSH and node_exporter; WireGuard UDP `51820` stays open for remote peers.

## Honesty

- Default demo uses an **Azure public IP**, not home bare metal.
- Client configs use **full-tunnel** `AllowedIPs` — all device traffic exits via the city VM.
- `vpn-clients/*.conf` is gitignored (private keys).
- Home-as-exit needs inbound UDP 51820 (no CGNAT) and DDNS; ISP ToS may forbid hosting.
- Multi-city = another vpn stack/region; clients switch profiles manually (no auto peer failover in V1).
