# Portable Architecture — bare metal preferred, Azure metal-sim as lab

Preferred primary is **bare-metal**. Azure metal-sim is the “lab without hardware”
path. Only Layer 1 changes when you switch. Talos machine config + GitOps stay the
same. There is **no Ansible layer**.

Golden path: [METAL-PRIMARY.md](METAL-PRIMARY.md).

```
┌─────────────────────────────────────────────────────────────┐
│  Layer 4: Failover     infra/shared (Traffic Manager + Fn)  │
├─────────────────────────────────────────────────────────────┤
│  Layer 3: GitOps       gitops/ + Flux                       │
├─────────────────────────────────────────────────────────────┤
│  Layer 2: (removed)    Talos replaces OS/k8s bootstrap      │
├─────────────────────────────────────────────────────────────┤
│  Layer 1: Provision    bare-metal | azure-metal-sim | aks   │
└─────────────────────────────────────────────────────────────┘
```

## Contract: Pulumi stack outputs

Every primary provisioner exports:

| Output | Purpose |
|--------|---------|
| `kubeconfig` | Cluster access (secret; empty string in bare-metal `dryRun`) |
| `apiLoadBalancerIP` | Kubernetes API address (Azure PIP or metal VIP/IP) |
| `ingressIP` | HTTP demo / Traffic Manager target |
| `clusterEndpoint` | `https://<api>:6443` |
| `provisioner` | `azure-metal-sim` \| `bare-metal` \| `aks` |

GitOps and failover scripts consume these outputs — not an Ansible inventory.
`./scripts/up.sh primary` and `./scripts/destroy.sh primary` resolve the stack
directory from `config/clusters.yaml` → `primary.pulumi_dir`.

## Inventory contract (`config/clusters.yaml`)

| Field | Required | Notes |
|-------|----------|-------|
| `primary.provisioner` | yes | `azure-metal-sim` \| `bare-metal` \| `aks` |
| `primary.pulumi_dir` | yes | `infra/primary` or `infra/bare-metal` (must match provisioner) |
| `primary.nodes` | when `bare-metal` | list of `{role, ip}` — **SoT**; synced to Pulumi |
| `primary.nodes[].role` | yes | `controlplane` \| `worker` |
| `primary.nodes[].ip` | yes | IPv4 or IPv6 reachable for Talos apid |
| `primary.dry_run` | no | default `true` offline; synced → `baremetal:dryRun` |
| `primary.install_disk` | no | synced → `baremetal:installDisk` |
| `primary.api_endpoint_ip` / `ingress_ip` | no | default first controlplane IP |

Offline check (no Azure, no hardware):

```bash
./scripts/validate-inventory.sh
```

Default committed inventory is bare-metal + `dry_run: true`. Example copy:
[`config/clusters.bare-metal.example.yaml`](../config/clusters.bare-metal.example.yaml).
Azure lab: [`config/clusters.azure-metal-sim.example.yaml`](../config/clusters.azure-metal-sim.example.yaml).

## Single inventory → Pulumi

Do **not** maintain a second hand-edited `baremetal:nodes` inventory.
`./scripts/sync-baremetal-config.sh` (also invoked by `./scripts/up.sh primary`)
reads `config/clusters.yaml` and writes `baremetal:*` keys.

## Switching primary to real bare metal

1. Install Talos on hardware (ISO / PXE / Omni) so nodes are in maintenance mode.
2. Edit `config/clusters.yaml` (or start from the bare-metal example):

   ```yaml
   primary:
     provisioner: bare-metal
     pulumi_dir: infra/bare-metal
     dry_run: true
     install_disk: /dev/sda   # often /dev/nvme0n1 on real metal
     nodes:
       - role: controlplane
         ip: 192.168.1.10
       - role: worker
         ip: 192.168.1.11
   ```

3. Validate offline, then bring up:

   ```bash
   ./scripts/validate-inventory.sh
   ./scripts/up.sh primary   # syncs inventory, then pulumi up (dryRun by default)
   ```

4. When hardware is ready, set `dry_run: false` in `clusters.yaml` and re-run
   `./scripts/up.sh primary` (applies machine config, bootstraps, real `kubeconfig`).
5. Optional DR: point Traffic Manager at the metal `ingressIP` (`./scripts/up.sh shared`).
6. If you previously ran Azure metal-sim: destroy that stack while
   `clusters.yaml` still points at `infra/primary`, **or** `./scripts/destroy.sh all`.

Unchanged: Flux manifests, demo app. VPN city stack stays opt-in
(`remote_access.provider: wireguard`).

## Hybrid matrix

| Primary | Standby | Failover |
|---------|---------|----------|
| azure-metal-sim | AKS | Traffic Manager priority |
| bare-metal | AKS | Traffic Manager external + Azure endpoints |
| azure-metal-sim | (none) | Portfolio MVP only |
| bare-metal dryRun | (none) | Offline inventory / talk-track demo |
