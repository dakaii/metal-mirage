# Capability ports

metal-mirage is evolving toward a **platform core with swappable adapters**.
WireGuard city exits are **one RemoteAccess implementation example**, not the
product identity.

Contracts live in [`pkg/ports`](../pkg/ports). Config seams live in
[`config/clusters.yaml`](../config/clusters.yaml).

## Ports

| Port | Config / location | OSS adapter today |
|------|-------------------|-------------------|
| **Compute** | `primary.*` / `standby.*` | `infra/primary`, `infra/bare-metal`, `infra/standby-aks` |
| **RemoteAccess** | `remote_access.*` (legacy `vpn.*`) | `infra/vpn-gateways` + `scripts/vpn-*` (**wireguard**) or **none** |
| **Lifecycle** | *(none yet)* | **noop** — BMC / power / PXE not automated |
| **Observability** | `gitops/infrastructure/monitoring` | ConfigMap hints + optional PrometheusRules |

```
config/clusters.yaml
        │
        ├─ Compute.provider ──► Pulumi dir (metal-sim | bare-metal | aks)
        ├─ RemoteAccess.provider ──► wireguard adapter | none
        ├─ Lifecycle ──► not shipped (see “Not possible” below)
        └─ Observability ──► GitOps hints (not a driver API)
```

## RemoteAccess (WireGuard example)

```yaml
remote_access:
  provider: wireguard   # or: none
  pulumi_dir: infra/vpn-gateways
```

| Provider | Effect |
|----------|--------|
| `wireguard` | `./scripts/up.sh vpn` (or `remote_access`) brings up the city-exit VM |
| `none` | Skip the VPN stack — platform / GitOps / DR only |

Client profile minting for WireGuard stays in
[`control-plane/internal/tunnel`](../control-plane/internal/tunnel) — see
[CLIENT-PROFILES.md](CLIENT-PROFILES.md).

## What this re-arch *does*

- Names the seams so VPN is clearly an **adapter**
- Lets you disable RemoteAccess without deleting code
- Keeps Compute provisioner switching (already portable)
- Documents Lifecycle / Observability as future ports
- Leaves room for a **separate commercial repo** to add billing, BMC, other remote-access plugins without rewriting GitOps

## What is **not** possible (in this OSS repo / with this change alone)

Be explicit — these are the hard limits of the current project shape:

### 1. Drop-in “any VPN / any mesh” by flipping a string
Setting `remote_access.provider: tailscale` (or OpenVPN, etc.) is **rejected**.
Each runtime needs a real adapter: IaC + projection scripts + (optionally) a
`tunnel.Protocol` for client exports. The port makes that *pluggable*; it does
not ship infinite providers.

### 2. Overnight BMC / “stop driving to Gangnam at 2am”
**LifecyclePort is a stub (`noop`).** This repo does **not**:

- Talk to iDRAC / iLO / IPMI / Redfish
- Power-cycle hung machines out-of-band
- PXE-install Talos for you (docs still say ISO/PXE/Omni *outside* the stack)
- Replace a failed UPS or broken BMC network path

On-prem “lights-out” ops belong in a **commercial or follow-on adapter**, not
this minimal ports overlay.

### 3. Turn metal-mirage into a billed multi-tenant product in-tree
Billing, Clerk subscriptions, abuse controls, and App Store clients stay **out
of OSS** ([ROADMAP.md](ROADMAP.md), [LEGAL.md](LEGAL.md)). Re-architecting ports
does **not** add tenancy or invoices. Put that in a **separate private repo**
that depends on these contracts.

### 4. One Go process that provisions Azure + metal + VPN
Adapters remain **Pulumi stacks + operator scripts** (separate modules). Ports
are contracts and config validation — not a unified in-process orchestrator.

### 5. Instant L4 failover or automatic DR cutover
Traffic Manager is still **DNS TTL** portfolio DR. Witness / `failover-promote`
are operator tools. Ports do not invent a different failover physics.

### 6. Auto-`wg set` from `POST /api/peers`
Peer minting and VM projection stay split on purpose (abuse / operator control).
`vpn-reconcile-peers.sh` remains the WireGuard projection path.

### 7. Replace Sidero Omni / Tailscale / Kasten by renaming folders
Those are full products. This repo is a **personal/self-host reference platform**.
Ports help *you* extend or commercially wrap it; they are not market replacements.

## Migration notes

| Keep stable | May evolve |
|-------------|------------|
| Primary Pulumi output names | Docs language: “RemoteAccess” vs “VPN product” |
| VPN on its own RG when enabled | `remote_access.provider` / `pulumi_dir` |
| Apache-2.0 personal WG example | Future Lifecycle inventory fields (BMC URL, etc.) |
| GitOps kustomize paths | Commercial adapters out-of-tree |

## Related

- [PORTABLE-ARCHITECTURE.md](PORTABLE-ARCHITECTURE.md) — Compute L1 switch
- [CLIENT-PROFILES.md](CLIENT-PROFILES.md) — WireGuard export registry
- [VPN.md](VPN.md) — WireGuard adapter operator path
- [ROADMAP.md](ROADMAP.md) — OSS vs commercial boundary
