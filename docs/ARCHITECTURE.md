# metal-mirage architecture

Portable hybrid Kubernetes platform: **Talos Linux** on Azure VMs today (bare-metal simulation), **AKS** as standby, **Flux** GitOps, **Traffic Manager** failover, and an additive **WireGuard** city-exit plane. Optional **Clerk + Neon** peer portal for productizing VPN onboarding.

Successor ideas from [fantastic-spoon](https://github.com/dakaii/fantastic-spoon), rebuilt for Azure + Pulumi Go with **no Ansible**.

## Goals

1. **Portability** — swap Azure metal-sim for real bare metal by changing Layer 1 only.
2. **API-driven bootstrap** — Talos machine config via Pulumi; no SSH playbooks for the K8s OS.
3. **Honest DR story** — primary + AKS standby behind priority Traffic Manager + a witness Function.
4. **Split planes** — consumer VPN is not on the Traefik/HTTP path; platform ops stay on Talos/Flux.
5. **Demoable cost** — destroy stacks when idle; see [COST.md](COST.md).

## Layer model

```
┌──────────────────────────────────────────────────────────────┐
│  Layer 4  Failover     infra/shared                          │
│           Traffic Manager (priority) + witness Azure Function│
├──────────────────────────────────────────────────────────────┤
│  Layer 3  GitOps       gitops/ + infra/flux-bootstrap        │
│           Flux controllers → cluster kustomizations          │
├──────────────────────────────────────────────────────────────┤
│  Layer 2  (removed)    Talos replaces Ansible OS/k8s bootstrap│
├──────────────────────────────────────────────────────────────┤
│  Layer 1  Provision    config/clusters.yaml → Pulumi stacks  │
│           azure-metal-sim | bare-metal | aks | vpn-gateways  │
└──────────────────────────────────────────────────────────────┘
```

| Layer | Path | Responsibility |
|-------|------|----------------|
| L1 primary | `infra/primary` | Talos secrets, machine config, Azure VMs, API PIP + ingress LB (→ NodePort 30080) |
| L1 standby | `infra/standby-aks` | AKS + Velero Blob storage + identity |
| L1 VPN | `infra/vpn-gateways` | Ubuntu city-exit VM, cloud-init WireGuard |
| L3 | `infra/flux-bootstrap`, `gitops/` | Helm Flux install; GitRepository/Kustomizations in-repo |
| L4 | `infra/shared` | Traffic Manager profile + optional witness Function App |
| Product (Phase 3) | `control-plane/` | Clerk auth + Neon peers API (optional) |

Provisioner switch lives in [`config/clusters.yaml`](../config/clusters.yaml). Layers above L1 do not care whether primary nodes are Azure VMs or hardware.

## Data-plane sketch

```
                    ┌─────────────────────┐
   users ──────────►│  Traffic Manager    │
                    │  priority routing   │
                    └──────────┬──────────┘
               priority 1      │      priority 2
                    ┌──────────▼──────────┐
                    │                     │
           Primary (Talos / metal-sim)   AKS standby
           ingress PIP :443              aks FQDN
                    │
                    │  Flux reconciles gitops/
                    ▼
              demo app + monitoring

   VPN clients ──UDP 51820──► WireGuard city VM (public IP) ──NAT──► internet
                              (separate RG / stack; not Traefik)
```

Witness Function (when enabled) probes cluster readiness (`/readyz`-style checks via deploy scripts) so operators have an out-of-band signal beyond Traffic Manager’s HTTP `/healthz` monitor.

## Stack choices

| Concern | Choice | Why |
|---------|--------|-----|
| IaC | Pulumi Go (`azure-native`, `pulumi-talos`, `pulumi-kubernetes`) | Typed programs; same language as control-plane |
| Node OS (primary) | Talos Linux | Immutable, API-only; eliminates Ansible layer |
| Primary compute | Azure VMs + custom Talos gallery image | Bare-metal *simulation* without home public IP |
| Standby | AKS | Managed DR target; Velero → Azure Blob |
| GitOps | Flux (Helm chart `flux2` + in-repo kustomize) | Declarative apps/infra; primary vs standby patches |
| Failover | Traffic Manager priority, TTL 30s, HTTP `/healthz` | Simple DNS DR; not instant L4 |
| VPN | Ubuntu 22.04 + cloud-init WireGuard | Stock clients; city tag per stack |
| Auth/DB (optional) | Clerk + Neon | Peer minting API without building IdP/DB |

## Why Talos / no Ansible

fantastic-spoon-style stacks often need a bootstrap layer (OS packages, kubeadm, SSH). Talos collapses that:

- Machine secrets and configs are first-class Pulumi resources (`pulumiverse/pulumi-talos`).
- Nodes expose Talos APIs (e.g. 50000/50001) and Kubernetes API (6443); no SSH to “fix the OS.”
- Layer 2 in the portable model is intentionally empty — GitOps starts after the cluster exists.

VPN still uses cloud-init on Ubuntu because WireGuard city exits are ordinary Linux appliances, not Talos nodes. That is deliberate plane separation, not a regression to Ansible for the platform.

## Metal-sim vs real metal

**Today (`provisioner: azure-metal-sim`):**

- Register a Talos Azure image once (`scripts/register-talos-image.sh`).
- `infra/primary` creates VNet/NSG, static API + ingress public IPs, control-plane/worker VMs (`Standard_B2s` by default), applies Talos config, bootstraps the cluster.
- Machine config patch sets `machine.install.disk` (default `/dev/sda` for Azure Gen2 metal-sim; override with `primary:installDisk`).
- Exports follow the portable contract: `kubeconfig` (secret), `apiLoadBalancerIP` / ingress IP, `clusterEndpoint`, `provisioner`.

**Later (`provisioner: bare-metal`):**

1. Install Talos on hardware (ISO / PXE / Omni).
2. Point `config/clusters.yaml` at node IPs; reuse the same machine-secrets pattern.
3. Retarget Traffic Manager primary endpoint to the metal ingress IP.
4. `./scripts/destroy.sh primary` to drop Azure metal-sim spend.

Unchanged: Flux manifests, demo app, monitoring rules, VPN city stack (unless you also move exits off Azure).

See [PORTABLE-ARCHITECTURE.md](PORTABLE-ARCHITECTURE.md) for the output contract and hybrid matrix.

## VPN vs platform split

| Plane | Stack | Role |
|-------|-------|------|
| Platform | primary / standby / shared / gitops | Operate Kubernetes, ingress, failover, observability |
| Consumer VPN | `infra/vpn-gateways` | Device traffic → NAT → internet |

VPN gateways:

- Own resource group and VNet (`10.66.0.0/16`).
- cloud-init installs WireGuard; `scripts/vpn-bootstrap.sh` mints peer configs.
- NSG allows UDP 51820 from anywhere (peers); SSH / node-exporter from `adminCidr` only.
- Not fronted by Traefik; clients use official WireGuard apps only.

Multi-city = another stack/region with a `city` tag; clients switch profiles manually (no auto peer failover in V1). Details: [VPN.md](VPN.md).

## Failover

`infra/shared` builds a Traffic Manager profile (`TrafficRoutingMethodPriority`):

- **Primary** external endpoint → primary ingress IP (priority 1).
- **Standby** external endpoint → AKS FQDN when configured (priority 2).
- Monitor: HTTP `:80` path `/healthz`, 30s interval, 3 tolerated failures (metal-sim Azure LB → demo NodePort `30080`; no TLS required for portfolio DR).
- DNS relative name `metal-mirage-app` → `*.trafficmanager.net` (custom domain optional via config).

Optional witness Function App (Python 3.11, Consumption Y1) provides an additional readiness signal; wire it with `scripts/deploy-witness.sh` after `./scripts/up.sh shared`.

**Limits:** failover is DNS-TTL bound (profile TTL 30s plus resolver caches) — not stateful L4 cutover. Suitable for portfolio DR narrative, not zero-RTO production.

## GitOps

1. Export primary kubeconfig from Pulumi secrets.
2. `infra/flux-bootstrap` installs Flux controllers via Helm into `flux-system`.
3. `scripts/install-flux.sh` (or manual apply) creates GitRepository + root Kustomization pointing at `gitops/clusters/<primary|standby>`.
4. Cluster overlays (`gitops/clusters/<name>/kustomization.yaml` → `flux.yaml`) pull `gitops/apps` (demo Deployment/Service/Ingress) and `gitops/infrastructure` (monitoring hints + Grafana dashboard ConfigMap).

PrometheusRule samples live under `gitops/infrastructure/monitoring/optional/` — apply only after kube-prometheus-stack (CRD) is installed. Default Flux path ships ConfigMap hints so reconcile stays green without that stack.

Standby overlays keep demo replicas at 0 until failover — keep cost and blast radius low during idle demos.

## Clerk + Neon (Phase 3)

`control-plane/` is an optional productization layer on the VPN plane:

- **Clerk** — Bearer session JWT on `/api/peers*`.
- **Neon** — Postgres for device peer records.
- `POST /api/peers` mints a WireGuard keypair + client config JSON.

Pushing the peer public key onto the VPN VM (`wg set` / reconciler) remains an operator step in V1. Runbook: [control-plane/README.md](../control-plane/README.md).

## Repo map

```
config/clusters.yaml     provisioner + city locations
infra/primary/           Talos metal-sim (Pulumi Go)
infra/standby-aks/       AKS + Velero storage
infra/shared/            Traffic Manager + witness
infra/vpn-gateways/      WireGuard city exits
infra/flux-bootstrap/    Flux Helm bootstrap
gitops/                  Flux-managed manifests
control-plane/           Clerk + Neon peer portal
scripts/                 up / destroy / vpn / flux helpers
docs/                    deploy, cost, VPN, portfolio talk track
```

## Related docs

- [DEPLOY.md](DEPLOY.md) — step-by-step bring-up
- [PORTABLE-ARCHITECTURE.md](PORTABLE-ARCHITECTURE.md) — L1 switch contract
- [VPN.md](VPN.md) — city exits and monitoring
- [VELERO.md](VELERO.md) — backup storage notes
- [COST.md](COST.md) — idle billing / teardown
- [PORTFOLIO-DEMO.md](PORTFOLIO-DEMO.md) — talk track
