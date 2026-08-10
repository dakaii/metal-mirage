# Metal-primary golden path

On-prem Talos is the **preferred** primary. Azure metal-sim is optional lab mode. RemoteAccess (WireGuard) is **off** by default.

## 0. Prerequisites

- Pulumi + Go 1.26.x (`./scripts/login.sh --skip-azure` or full login if you also use cloud standby)
- Hardware (or VMs) that can boot Talos into **maintenance mode** (ISO / PXE / Omni — outside this repo)
- `kubectl`, `flux` for GitOps
- Optional: MetalLB (or another L2/VIP) so `ingressIP` is a stable HTTP target

Offline contract check (no hardware):

```bash
./scripts/validate-inventory.sh
```

## 1. Inventory (single source of truth)

Edit `config/clusters.yaml`:

```yaml
primary:
  provisioner: bare-metal
  pulumi_dir: infra/bare-metal
  dry_run: true          # flip to false after nodes are in maintenance mode
  install_disk: /dev/nvme0n1
  # api_endpoint_ip / ingress_ip optional — default to first controlplane IP
  nodes:
    - role: controlplane
      ip: 192.168.1.10
    - role: worker
      ip: 192.168.1.11

remote_access:
  provider: none         # set wireguard only if you want a city-exit VM
```

Sync into Pulumi (also done automatically by `./scripts/up.sh primary`):

```bash
./scripts/sync-baremetal-config.sh
```

## 2. Dry-run (offline) then live apply

```bash
./scripts/up.sh primary
# dry_run=true → secrets + machine configs in state; no Talos API calls

# Install Talos on nodes → maintenance mode, then:
#   set dry_run: false in config/clusters.yaml
./scripts/sync-baremetal-config.sh
./scripts/up.sh primary

mkdir -p .secrets
pulumi -C infra/bare-metal stack output kubeconfig --show-secrets > .secrets/primary.kubeconfig
export KUBECONFIG=$PWD/.secrets/primary.kubeconfig
kubectl get nodes
```

## 3. Ingress on metal (pick one)

Azure metal-sim uses an Azure LB → NodePort `30080`. On bare metal you need a reachable `ingressIP` for the demo `/healthz` and for optional Traffic Manager.

| Option | When |
|--------|------|
| **A. Node IP + NodePort** | Simplest lab: set `ingress_ip` to a node IP; curl `http://<ip>:30080/healthz` after Flux |
| **B. MetalLB L2** | Homelab LAN: advertise a VIP (see below) |
| **C. BYO LB / kube-vip / reverse proxy** | You already have a VIP or edge proxy |

### Option B — MetalLB (optional GitOps)

1. Pick a free LAN IP for `primary.ingress_ip` (e.g. `192.168.1.50`) and sync/up.
2. Enable the optional overlay (after Flux is installed):

```bash
# Review/edit the address pool first:
#   gitops/infrastructure/metallb/ipaddresspool.yaml
kubectl apply -k gitops/infrastructure/metallb
# Or add the metallb path to your cluster Flux kustomization when ready.
```

3. Point the demo Service at MetalLB (annotation / `LoadBalancer`) — see comments in `gitops/infrastructure/metallb/README.md`. Until then, NodePort `30080` on any node still works for local drills.

## 4. Flux + demo app

```bash
./scripts/install-flux.sh primary
# After reconcile:
curl -fsS "http://$(pulumi -C infra/bare-metal stack output ingressIP):30080/healthz"
# If you switched the Service to LoadBalancer + MetalLB, use :80 instead of :30080.
```

Ship **your** service: add a directory under `gitops/apps/` and include it from `gitops/apps/kustomization.yaml` (same pattern as `demo/`).

## 5. Optional cloud standby / DR

Not required for metal-primary usefulness:

```bash
./scripts/login.sh                 # Azure + Pulumi when using AKS / TM
./scripts/up.sh standby            # AKS cold standby
./scripts/up.sh shared             # Traffic Manager + witness (Azure)
./scripts/deploy-witness.sh
./scripts/failover-promote.sh --dry-run
```

See [DR.md](DR.md). DNS failover remains TTL-bound; promote stays opt-in.

## 6. Optional WireGuard RemoteAccess

```yaml
remote_access:
  provider: wireguard
```

```bash
./scripts/up.sh vpn
./scripts/vpn-bootstrap.sh laptop
```

## Lab without hardware

Copy [config/clusters.azure-metal-sim.example.yaml](../config/clusters.azure-metal-sim.example.yaml) over `config/clusters.yaml`, register a Talos image, then `./scripts/up.sh primary` (Azure VMs).

## Related

| Doc | Role |
|-----|------|
| [PORTABLE-ARCHITECTURE.md](PORTABLE-ARCHITECTURE.md) | L1 output contract |
| [CAPABILITY-PORTS.md](CAPABILITY-PORTS.md) | Compute / RemoteAccess ports |
| [DEPLOY.md](DEPLOY.md) | Full multi-stack bring-up |
| [COST.md](COST.md) | Idle cloud billing |
