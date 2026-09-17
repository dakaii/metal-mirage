# Cost & teardown

Idle resources bill. Prefer destroy between demos.

## Isolate the lab (subscription pin)

Azure does **not** give you GCP-style “one project folder → delete project.” Closest
equivalents:

| Approach | Pros | Cons |
|----------|------|------|
| **Dedicated Azure subscription** for metal-mirage (recommended) | Hard isolation; `az account set` + pin in config | Extra sub to create/manage |
| Shared sub + careful RG deletes | Works if disciplined | Easy to mix with other products (ZeroClaw/Banjar) |
| GCP project-per-lab | Nuke-by-project is simple | Not what this repo provisions today |

**Enforced in scripts:** set `azure.subscription_id` in `config/clusters.yaml` to the
dedicated lab subscription GUID (`az account show --query id -o tsv`).  
`./scripts/up.sh` / `./scripts/destroy.sh` (Azure paths), `register-talos-image.sh`,
`init-azure-metal-sim.sh`, `deploy-witness.sh`, and TM changes in `failover-promote.sh`
refuse to continue if `az account` does not match.

```yaml
azure:
  subscription_id: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

Escape hatches (not for routine use): `ALLOW_UNPINNED_AZURE_SUB=1`,
`SKIP_AZURE_SUBSCRIPTION_CHECK=1`.

Resource groups for this lab are Pulumi-named (`primary-rg…`, `standby-rg…`,
`shared-rg…`, `vpn-rg…`, plus `talos-images`). After destroy, confirm with
`az group list` on the **pinned** subscription. If Pulumi cannot see stacks
(wrong backend), delete leftover RGs with `az group delete` on that same sub.

## Idle cost notes

| Resource | Notes |
|----------|-------|
| Talos VMs (`Standard_D2s_v4` typical; auto-picked) | Largest ongoing cost for primary metal-sim |
| Worker Standard public IPs | One PIP per worker so laptop→Talos `ConfigurationApply` reaches the node; NSG still gates Talos API to `adminCidr` |
| AKS system pool (`standby:vmSize`, default `Standard_D2s_v4`) | Bills even with replicas=0 apps; `Standard_B2s` often blocked on new subs |
| AKS demo Service `LoadBalancer` (standby Flux patch) | Standard LB + public IP for TM priority-2; small ongoing cost even while demo replicas=0 |
| Traffic Manager | Cheap; keep if you have a domain story |
| Function Consumption (Y1) | Near-zero idle |
| VPN (default `Standard_B1s`; often probed up to `Standard_D2s_v4`) | B-series frequently capacity-blocked in eastus — expect D-family after `./scripts/pick-azure-vm-size.sh`. Destroy independently: `./scripts/destroy.sh vpn` |
| Managed disks / Public IPs | Leftover after failed destroys — check RG |

```bash
./scripts/destroy.sh vpn      # VPN only
./scripts/destroy.sh all      # everything
```

Registering the Talos gallery image is one-time storage; you can delete the VHD storage account after the gallery version exists.
