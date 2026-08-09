# Cost & teardown

Idle resources bill. Prefer destroy between demos.

| Resource | Notes |
|----------|-------|
| Talos VMs (`Standard_B2s`) | Largest ongoing cost for primary |
| Worker Standard public IPs | One PIP per worker so laptop→Talos `ConfigurationApply` reaches the node; NSG still gates Talos API to `adminCidr` |
| AKS system pool | Bill even with replicas=0 apps |
| Traffic Manager | Cheap; keep if you have a domain story |
| Function Consumption (Y1) | Near-zero idle |
| VPN `Standard_B1s` | Small; destroy independently |
| Managed disks / Public IPs | Leftover after failed destroys — check RG |

```bash
./scripts/destroy.sh vpn      # VPN only
./scripts/destroy.sh all      # everything
```

Registering the Talos gallery image is one-time storage; you can delete the VHD storage account after the gallery version exists.
