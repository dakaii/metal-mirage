# Cost & teardown

Idle resources bill. Prefer destroy between demos.

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
