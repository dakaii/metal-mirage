# metal-mirage

Portable Talos Kubernetes on **Azure + Pulumi Go** — no Ansible.

Primary runs Talos on Azure VMs as a **bare-metal simulation**; swap to real metal later without rewriting GitOps. AKS is the standby/DR cluster. WireGuard city exits are an additive plane. Optional Clerk + Neon peer portal lives in `control-plane/`.

Inspired by [fantastic-spoon](https://github.com/dakaii/fantastic-spoon), rebuilt for Azure / Pulumi / Talos.

**Deep dive:** [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)

**Contributing:** [CONTRIBUTING.md](CONTRIBUTING.md) — branch from `main`, open a PR; do not push feature work straight to `main`.

## Architecture

```
Layer 4  infra/shared/         Traffic Manager + witness Function
Layer 3  gitops/               Flux, monitoring, demo app
Layer 2  (none)                Talos replaces Ansible bootstrap
Layer 1  infra/primary|…       azure-metal-sim | bare-metal | aks | vpn
```

```
Primary (Talos on Azure VMs) ──► Traffic Manager ──► users
         │                            │
         │ failover                   ▼
         └──────────── AKS standby ───┘
VPN clients ──► WireGuard exit VM (public IP) ──► internet
```

Only Layer 1 changes when you move from Azure VMs to real hardware. Talos machine config + Flux manifests stay the same. Provisioner switch: [`config/clusters.yaml`](config/clusters.yaml).

| Concern | Choice |
|---------|--------|
| IaC | Pulumi Go (`azure-native` + `pulumi-talos`) |
| Node OS | Talos Linux (API-only, no SSH/Ansible) |
| Primary | Azure VMs as bare-metal simulation |
| Standby | AKS + Velero → Azure Blob |
| GitOps | Flux |
| Failover | Traffic Manager (priority) + Azure Function witness |
| VPN | Dedicated Ubuntu VM + cloud-init WireGuard |
| Auth/DB (optional) | Clerk + Neon |

**Why Talos / no Ansible:** machine secrets and configs are Pulumi resources; there is no SSH playbook layer for the Kubernetes OS. VPN still uses cloud-init on Ubuntu because city exits are ordinary Linux appliances on a separate plane — not Talos nodes.

**VPN vs platform:** WireGuard is an optional **RemoteAccess** adapter (full-tunnel egress on its own stack/RG). Set `remote_access.provider: none` to skip it. Flux / demo apps stay on the Talos (or AKS) path via Azure LB → NodePort (no Traefik in the portfolio path). Standard WireGuard `.conf` profiles (official apps, Shadowrocket, and similar). See [docs/CAPABILITY-PORTS.md](docs/CAPABILITY-PORTS.md).

**Failover honesty:** Traffic Manager follows DNS TTL (profile TTL 30s plus resolver caches) — portfolio DR, not instant L4 cutover.

## Quick start

```bash
# Prerequisites: Azure CLI, Pulumi, Go 1.26.x, azcopy (for Talos image once)
./scripts/login.sh                 # az + pulumi (browser/device-code if needed)
# ./scripts/login.sh --local-pulumi
# ./scripts/login.sh --control-plane   # optional Clerk+Neon .env check

# 1. Register a Talos Azure image (one-time per subscription/region)
./scripts/register-talos-image.sh eastus

# 2. Bring up primary metal-sim cluster
./scripts/up.sh primary

# 3. (Optional) standby AKS + shared failover + VPN city
./scripts/up.sh standby
./scripts/up.sh shared
./scripts/up.sh vpn

# Tear down when idle (stops most billing)
./scripts/destroy.sh all
```

| Doc | Contents |
|-----|----------|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Layers, metal-sim, failover, VPN split, Clerk/Neon |
| [docs/DEPLOY.md](docs/DEPLOY.md) | Full bring-up (Flux, witness, VPN peers) |
| [docs/DR.md](docs/DR.md) | Failover drill (Traffic Manager + witness) |
| [docs/AUTO-FAILOVER.md](docs/AUTO-FAILOVER.md) | Opt-in webhook / GHA promote + RTO honesty |
| [docs/CONFIG.md](docs/CONFIG.md) | Pulumi / env config keys |
| [docs/BEST-PRACTICES.md](docs/BEST-PRACTICES.md) | Operator security / GitOps / teardown checklist |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Branch from `main`, open a PR; CI check names |
| [docs/ROADMAP.md](docs/ROADMAP.md) | Now / Next / Later + OSS commercial boundary |
| [docs/LEGAL.md](docs/LEGAL.md) | Personal/self-host intent + legality research notes |
| [docs/PORTABLE-ARCHITECTURE.md](docs/PORTABLE-ARCHITECTURE.md) | L1 switch contract + hybrid matrix |
| [docs/VPN.md](docs/VPN.md) | City exits, peer reconcile, monitoring, honesty notes |
| [docs/CLIENT-PROFILES.md](docs/CLIENT-PROFILES.md) | Pluggable tunnel exports (WireGuard `.conf` first) |
| [docs/CAPABILITY-PORTS.md](docs/CAPABILITY-PORTS.md) | Swappable Compute / RemoteAccess ports + hard limits |
| [docs/COST.md](docs/COST.md) | Idle billing |
| [docs/PORTFOLIO-DEMO.md](docs/PORTFOLIO-DEMO.md) | Talk track — bring stack up the night before |
| [control-plane/README.md](control-plane/README.md) | Optional Clerk + Neon peer portal (Phase 3) |

## Project layout

```
config/clusters.yaml       ← provisioner switch (+ bare-metal example)
infra/primary/             ← Talos on Azure VMs (metal-sim)
infra/bare-metal/          ← thin Talos L1 for real hardware (dryRun offline)
infra/standby-aks/         ← AKS standby + Velero Blob
infra/shared/              ← Traffic Manager + witness
infra/vpn-gateways/        ← WireGuard city exits (cloud-init)
infra/flux-bootstrap/      ← Flux Helm controllers
gitops/                    ← Flux manifests
control-plane/             ← optional Clerk + Neon peer portal (Phase 3)
scripts/                   ← up / destroy / validate-inventory / vpn helpers
docs/
```

## Honesty notes

- Idle Azure VMs/AKS still bill — destroy when not demoing.
- Home bare-metal VPN exit needs a public IP (or CGNAT workaround); default demo uses Azure public IPs.
- Traffic Manager failover follows DNS TTL — not instant L4.
- Built for **personal / self-host** use (your lab + your WireGuard peers) — not a commercial VPN product.
- Billing, subscriptions, and multi-tenant SaaS features are out of scope — see [docs/ROADMAP.md](docs/ROADMAP.md).
- Intended use & legality notes (not legal advice): [docs/LEGAL.md](docs/LEGAL.md).
