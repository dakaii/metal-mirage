# metal-mirage

**Metal-first** Talos Kubernetes platform (Pulumi Go + Flux) — on-prem primary preferred, cloud standby optional. No Ansible.

Ship your own services on a portable L1 (bare-metal Talos today, Azure metal-sim as a lab). GitOps stays the same when you switch provisioners. WireGuard is an optional **RemoteAccess** adapter (off by default). Optional Clerk + Neon peer portal lives in `control-plane/`.

Inspired by [fantastic-spoon](https://github.com/dakaii/fantastic-spoon), rebuilt for Talos / Pulumi / portable L1.

**Golden path:** [docs/METAL-PRIMARY.md](docs/METAL-PRIMARY.md) · **Deep dive:** [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)

**Contributing:** [CONTRIBUTING.md](CONTRIBUTING.md) — branch from `main`, open a PR; do not push feature work straight to `main`.

## Architecture

```
Layer 4  infra/shared/         Traffic Manager + witness Function (optional Azure DR)
Layer 3  gitops/               Flux, monitoring, demo app
Layer 2  (none)                Talos replaces Ansible bootstrap
Layer 1  infra/bare-metal|…    bare-metal (preferred) | azure-metal-sim | aks | vpn
```

```
Primary (Talos on metal) ──► users (NodePort / MetalLB / BYO VIP)
         │
         │ optional failover
         └──────────── AKS standby + Traffic Manager ──► users (DNS TTL)
Optional: VPN clients ──► WireGuard exit VM ──► internet
```

Only Layer 1 changes when you move between metal and Azure lab VMs. Switch: [`config/clusters.yaml`](config/clusters.yaml).

| Concern | Choice |
|---------|--------|
| IaC | Pulumi Go (`azure-native` + `pulumi-talos`) |
| Node OS | Talos Linux (API-only, no SSH/Ansible) |
| Primary (default) | Bare-metal Talos (`infra/bare-metal`, `dry_run` safe offline) |
| Lab without hardware | Azure VMs metal-sim — [clusters.azure-metal-sim.example.yaml](config/clusters.azure-metal-sim.example.yaml) |
| Standby | Optional AKS + Velero → Azure Blob |
| GitOps | Flux |
| Failover | Optional Traffic Manager + witness + `failover-promote` |
| RemoteAccess | Off by default; WireGuard adapter when `remote_access.provider: wireguard` |
| Auth/DB (optional) | Clerk + Neon peer demo |

**Failover honesty:** Traffic Manager follows DNS TTL — orchestrated DR, not instant L4 cutover. See [docs/DR.md](docs/DR.md).

## Quick start (metal-first)

```bash
./scripts/login.sh --skip-azure   # or full ./scripts/login.sh if using Azure standby
./scripts/validate-inventory.sh

# Edit config/clusters.yaml IPs/disks for your hardware (default is dry_run: true)
./scripts/fetch-talos-installer.sh              # checksum-verified metal ISO → .secrets/
# Flash USB / boot to maintenance (docs/INSTALL-TALOS.md). Lab PXE: lab/pxe/
./scripts/up.sh primary                         # syncs inventory → Pulumi, then pulumi up
./scripts/export-baremetal-machine-configs.sh   # USB / talosctl apply files

# After Talos is in maintenance mode: set dry_run: false, up again, then:
#   pulumi -C infra/bare-metal stack output kubeconfig --show-secrets > .secrets/primary.kubeconfig
#   ./scripts/install-flux.sh primary
# Details: docs/METAL-PRIMARY.md
```

### Lab on Azure (no home metal)

```bash
cp config/clusters.azure-metal-sim.example.yaml config/clusters.yaml
./scripts/login.sh
./scripts/register-talos-image.sh eastus
./scripts/up.sh primary
# optional: ./scripts/up.sh standby && ./scripts/up.sh shared
# optional WireGuard: set remote_access.provider: wireguard, then ./scripts/up.sh vpn
./scripts/destroy.sh all   # when idle
```

| Doc | Contents |
|-----|----------|
| [docs/METAL-PRIMARY.md](docs/METAL-PRIMARY.md) | **Start here** — metal inventory, ingress, Flux |
| [docs/INSTALL-TALOS.md](docs/INSTALL-TALOS.md) | ISO fetch / lab PXE / Lifecycle noop vs Redfish |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Layers, failover, VPN split |
| [docs/DEPLOY.md](docs/DEPLOY.md) | Full bring-up (Flux, witness, VPN peers) |
| [docs/DR.md](docs/DR.md) | Failover drill (Traffic Manager + witness) |
| [docs/AUTO-FAILOVER.md](docs/AUTO-FAILOVER.md) | Opt-in webhook / GHA promote + RTO honesty |
| [docs/CONFIG.md](docs/CONFIG.md) | Pulumi / env config keys |
| [docs/BEST-PRACTICES.md](docs/BEST-PRACTICES.md) | Operator security / GitOps / teardown checklist |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Branch from `main`, open a PR; CI check names |
| [docs/ROADMAP.md](docs/ROADMAP.md) | Now / Next / Later + OSS commercial boundary |
| [docs/LEGAL.md](docs/LEGAL.md) | Personal/self-host intent + legality research notes |
| [docs/PORTABLE-ARCHITECTURE.md](docs/PORTABLE-ARCHITECTURE.md) | L1 switch contract + hybrid matrix |
| [docs/VPN.md](docs/VPN.md) | City exits (optional RemoteAccess) |
| [docs/CLIENT-PROFILES.md](docs/CLIENT-PROFILES.md) | Pluggable tunnel exports |
| [docs/CAPABILITY-PORTS.md](docs/CAPABILITY-PORTS.md) | Swappable Compute / RemoteAccess ports |
| [docs/COST.md](docs/COST.md) | Idle billing |
| [control-plane/README.md](control-plane/README.md) | Optional Clerk + Neon peer portal |

## Project layout

```
config/clusters.yaml       ← metal-first provisioner switch + inventory SoT
infra/bare-metal/          ← preferred Talos primary (real hardware)
infra/primary/             ← Azure metal-sim lab
infra/standby-aks/         ← optional AKS standby + Velero storage
infra/shared/              ← optional Traffic Manager + witness
infra/vpn-gateways/        ← optional WireGuard RemoteAccess adapter
infra/flux-bootstrap/      ← Flux Helm controllers
gitops/                    ← Flux-managed manifests (+ optional metallb/)
control-plane/             ← optional Clerk + Neon peer portal
scripts/                   ← login / up / destroy / sync-baremetal / vpn helpers
docs/
```

## Honesty notes

- Idle Azure VMs/AKS still bill — destroy when not demoing; metal-primary can stay $0 cloud.
- Home bare-metal needs a reachable API/ingress IP (or CGNAT workaround for remote admin).
- Traffic Manager failover follows DNS TTL — not instant L4.
- Built for **personal / self-host** use — not a commercial VPN product.
- Billing, subscriptions, and multi-tenant SaaS features are out of scope — see [docs/ROADMAP.md](docs/ROADMAP.md).
- Intended use & legality notes (not legal advice): [docs/LEGAL.md](docs/LEGAL.md).
