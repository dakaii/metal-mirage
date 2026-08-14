# Self-host WireGuard (personal exit)

Full-tunnel WireGuard exit on a dedicated Azure VM (cloud-init — **no Ansible**).
Standard WireGuard profiles for **your** devices — not a multi-tenant commercial VPN.
Compatible with any client that imports stock WireGuard `.conf` (official apps, Shadowrocket, and similar).
Not on the HTTP/demo path (Azure LB → NodePort). Legality / intended use: [LEGAL.md](LEGAL.md).
Client profile architecture: [CLIENT-PROFILES.md](CLIENT-PROFILES.md).
Capability ports (VPN as optional adapter): [CAPABILITY-PORTS.md](CAPABILITY-PORTS.md).

## Exit vs platform

| Plane | Role |
|-------|------|
| WireGuard gateway | Your device traffic → NAT → internet |
| Talos + Flux + demo LB | Operate/monitor the platform (lab path: Azure LB → NodePort `30080`, no Traefik) |

## Deploy

RemoteAccess is **off by default** (`remote_access.provider: none`). With that
default, `./scripts/up.sh vpn` exits 0 and **skips** the stack — enable the
adapter first:

```yaml
# config/clusters.yaml
remote_access:
  provider: wireguard
  pulumi_dir: infra/vpn-gateways
```

```bash
# Stack name matches primary/shared (default PULUMI_STACK=dev)
cd infra/vpn-gateways
pulumi stack select dev 2>/dev/null || pulumi stack init dev
pulumi config set vpn:sshPublicKey "$(cat ~/.ssh/id_ed25519.pub)"
pulumi config set vpn:adminCidr "$(curl -fsSL ifconfig.me)/32"
cd ../..

# Default vpn:vmSize is Standard_B1s — often SkuNotAvailable in eastus.
# Probe and set before up (same helper as standby):
./scripts/pick-azure-vm-size.sh eastus 1
pulumi -C infra/vpn-gateways config set vpn:vmSize Standard_D2s_v4   # use probe output

./scripts/up.sh vpn
./scripts/vpn-bootstrap.sh laptop
```

If eastus keeps failing capacity restrictions, try another region:
`pulumi -C infra/vpn-gateways config set vpn:location westus2` then re-probe that location.

Import `vpn-clients/us-laptop.conf` into the official WireGuard app (or any client that accepts standard WireGuard profiles, e.g. Shadowrocket). Confirm exit IP with `curl ifconfig.me` (should match `pulumi -C infra/vpn-gateways stack output publicIP`).

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
