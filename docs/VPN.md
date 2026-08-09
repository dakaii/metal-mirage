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

## Monitoring

```bash
./scripts/vpn-prometheus-scrape-snippet.sh
```

Alerts live in `gitops/infrastructure/monitoring/prometheus-rules-vpn.yaml`.

## Honesty

- Default demo uses an **Azure public IP**, not home bare metal.
- Home-as-exit needs inbound UDP 51820 (no CGNAT) and DDNS; ISP ToS may forbid hosting.
- Multi-city = another vpn stack/region; clients switch profiles manually (no auto peer failover in V1).
