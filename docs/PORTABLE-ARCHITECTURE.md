# Portable Architecture — Azure metal-sim today, bare metal later

Only Layer 1 changes when you move from Azure VMs to real hardware. Talos machine
config + GitOps stay the same. There is **no Ansible layer**.

```
┌─────────────────────────────────────────────────────────────┐
│  Layer 4: Failover     infra/shared (Traffic Manager + Fn)  │
├─────────────────────────────────────────────────────────────┤
│  Layer 3: GitOps       gitops/ + Flux                       │
├─────────────────────────────────────────────────────────────┤
│  Layer 2: (removed)    Talos replaces OS/k8s bootstrap      │
├─────────────────────────────────────────────────────────────┤
│  Layer 1: Provision    azure-metal-sim | bare-metal | aks   │
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
| `primary.nodes` | when `bare-metal` | list of `{role, ip}` |
| `primary.nodes[].role` | yes | `controlplane` \| `worker` |
| `primary.nodes[].ip` | yes | IPv4 or IPv6 reachable for Talos apid |

Offline check (no Azure, no hardware):

```bash
./scripts/validate-inventory.sh
```

Example inventory: [`config/clusters.bare-metal.example.yaml`](../config/clusters.bare-metal.example.yaml).

## Switching primary to real bare metal

1. Install Talos on hardware (ISO / PXE / Omni) so nodes are in maintenance mode.
2. Copy the example inventory into `config/clusters.yaml`:

   ```yaml
   primary:
     provisioner: bare-metal
     pulumi_dir: infra/bare-metal
     nodes:
       - role: controlplane
         ip: 192.168.1.10
       - role: worker
         ip: 192.168.1.11
   ```

3. Validate offline, then configure the thin stack:

   ```bash
   ./scripts/validate-inventory.sh
   cd infra/bare-metal
   pulumi stack init dev   # or select
   pulumi config set baremetal:nodes '[{"role":"controlplane","ip":"192.168.1.10"},{"role":"worker","ip":"192.168.1.11"}]'
   pulumi config set baremetal:apiEndpointIP 192.168.1.10
   pulumi config set baremetal:ingressIP 192.168.1.10
   pulumi config set baremetal:installDisk /dev/nvme0n1
   # Offline demo (default): generates secrets + machine configs, no node contact
   pulumi config set baremetal:dryRun true
   cd ../..
   ./scripts/up.sh primary
   ```

4. When hardware is ready, set `baremetal:dryRun false` and re-run `./scripts/up.sh primary`
   (applies machine config, bootstraps, exports a real `kubeconfig`).
5. Point Traffic Manager at the metal `ingressIP` (`./scripts/up.sh shared` wires it).
6. Destroy Azure metal-sim spend: `./scripts/destroy.sh primary` while
   `clusters.yaml` still points at `infra/primary`, **or** `./scripts/destroy.sh all`
   (also tries the sibling primary stack).

Unchanged: Flux manifests, demo app, VPN city stack (still Azure public IP unless you move exits).

## Hybrid matrix

| Primary | Standby | Failover |
|---------|---------|----------|
| azure-metal-sim | AKS | Traffic Manager priority |
| bare-metal | AKS | Traffic Manager external + Azure endpoints |
| azure-metal-sim | (none) | Portfolio MVP only |
| bare-metal dryRun | (none) | Offline inventory / talk-track demo |
