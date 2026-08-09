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

Every provisioner exports:

| Output | Purpose |
|--------|---------|
| `kubeconfig` | Cluster access (secret) |
| `apiLoadBalancerIP` / `aksFqdn` | API / ingress endpoint |
| `clusterEndpoint` | Talos/K8s API URL |
| `provisioner` | `azure-metal-sim` \| `bare-metal` \| `aks` |

GitOps and failover scripts consume these outputs — not an Ansible inventory.

## Switching primary to real bare metal

1. Install Talos on hardware (ISO / PXE / Omni).
2. Set `config/clusters.yaml` → `provisioner: bare-metal` with node IPs.
3. Point a thin Pulumi stack (or `talosctl`) at those IPs with the **same** machine secrets pattern used in `infra/primary`.
4. Update Traffic Manager primary endpoint to the metal ingress IP.
5. Destroy Azure metal-sim VMs: `./scripts/destroy.sh primary`.

Unchanged: Flux manifests, demo app, VPN city stack (still Azure public IP unless you move exits).

## Hybrid matrix

| Primary | Standby | Failover |
|---------|---------|----------|
| azure-metal-sim | AKS | Traffic Manager priority |
| bare-metal | AKS | Traffic Manager external + Azure endpoints |
| azure-metal-sim | (none) | Portfolio MVP only |
