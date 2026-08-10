# metal-mirage roadmap

In-repo tracking for the open-source platform. Prefer this file over a flood of GitHub issues.

**Scope rule:** everything here must keep the stack **usable standalone** (Pulumi + Talos bare-metal preferred / metal-sim lab + Flux + optional VPN + optional peer API). Paid product surfaces stay out of this repo.

## Now (OSS core — must work)

| Area | Status intent |
|------|----------------|
| Pulumi Go stacks: `primary` (Talos metal-sim), `bare-metal` (thin L1), `standby-aks`, `shared` (Traffic Manager + witness), `vpn-gateways` | Ship / harden |
| Scripts: `login`, `register-talos-image`, `up` / `destroy`, `validate-inventory`, `vpn-bootstrap`, `vpn-reconcile-peers`, `failover-promote`, `install-flux`, `deploy-witness` | Documented, runnable |
| GitOps: Flux bootstrap path + demo app + monitoring scrape/alert hints | Kustomize-valid |
| Docs: ARCHITECTURE, DEPLOY, VPN, CLIENT-PROFILES, CAPABILITY-PORTS, COST, PORTABLE, CONFIG, BEST-PRACTICES, LEGAL, this ROADMAP | Honest personal/self-host framing |
| Optional Phase 3 demo: Clerk + Neon peer registry + WireGuard profile exports in `control-plane/` | Minimal API only; clearly optional |
| Capability ports: `pkg/ports` + `remote_access.provider` (`wireguard` \| `none`); WireGuard as RemoteAccess example | Ship / document limits |
| CI: Go build/fmt/vet matrix (incl. `infra/bare-metal` + inventory tests) + kustomize + shellcheck + actionlint + gitleaks; PRs into `main` ([CONTRIBUTING.md](../CONTRIBUTING.md)) | Keep green; no Azure secrets in CI |
| Portable L1: bare-metal default + inventory SoT sync (`sync-baremetal-config`) + dryRun offline demo; Azure metal-sim as lab | Done (live metal still needs hardware + `dry_run=false`) — [METAL-PRIMARY.md](METAL-PRIMARY.md) |

## Next (OSS hardening)

- Live Azure bring-up validation of the full DR path (needs Azure creds in the operator environment)

### Recently landed

- Auth helper: `./scripts/login.sh` (Azure + Pulumi; optional control-plane / Clerk keyless checks)
- Legality / intended-use note: [LEGAL.md](LEGAL.md) (personal self-host framing; not legal advice)
- Failover promote helper: `./scripts/failover-promote.sh` (Flux-aware standby scale + optional TM primary disable/failback); stable TM resource names exported from `infra/shared`
- Contributor UX: secret-scan hygiene — `.gitleaks.toml`, safer `.env.example` placeholders, `credentials-velero` gitignore, local `gitleaks` in CONTRIBUTING
- Witness optional `failoverWebhookURL` — POST JSON once at threshold crossing (still no auto TM/scale inside the Function)
- Contributor UX: clearer script errors (`lib.sh` helpers), bare-metal inventory SoT sync, Go 1.26 prereqs
- Metal-first defaults: `primary.provisioner=bare-metal`, `remote_access.provider=none`, [METAL-PRIMARY.md](METAL-PRIMARY.md), optional MetalLB overlay
- VPN observability: Helm scrape fragment + adminCidr caveat, Grafana dashboard polish, node_exporter disk/memory alerts (no WG exporter)
- DR drill runbook: [DR.md](DR.md) (Traffic Manager `:80/healthz` vs witness `:6443/readyz`)
- Optional peer reconciler: `./scripts/vpn-reconcile-peers.sh` (+ `control-plane/cmd/listpeers`) — DB → `wg set`, optional `--prune`
- Pluggable client profiles: `control-plane/internal/tunnel` registry; WireGuard `wireguard-conf` exports; `GET /api/tunnel/protocols` — [CLIENT-PROFILES.md](CLIENT-PROFILES.md)
- Capability ports overlay: `pkg/ports` + `remote_access` config; WireGuard demoted to RemoteAccess example; documented hard limits — [CAPABILITY-PORTS.md](CAPABILITY-PORTS.md)

## Later — commercial / out of this repo

Do **not** implement these in metal-mirage. Keep them in a separate commercial codebase if pursued:

- Stripe / Clerk Billing, subscriptions, invoices, payment webhooks
- Multi-tenant SaaS abuse prevention, rate limits, entitlement gates, metering
- Proprietary branding, App Store / consumer mobile apps, commercial “unblocker” marketing
- Managed hosted control plane as a paid product
- Hard-coded vendor secrets or license keys

The optional Clerk + Neon peer API in OSS is a **demo**, not a billing surface. Pushing peers onto the VPN VM is an operator step via `./scripts/vpn-reconcile-peers.sh` (not inlined into `POST /api/peers`).

## Boundary checklist (when reviewing PRs)

| In OSS | Out of OSS |
|--------|------------|
| IaC, GitOps, witness, WireGuard city exits | Payments / subscriptions |
| Self-host deploy docs + cost honesty | Multi-tenant product abuse stack |
| Optional peer minting API (no billing) | App Store clients / proprietary branding |
| Apache-2.0 personal/self-host platform ([LEGAL.md](LEGAL.md)) | “Commercial VPN product” / unblocker marketing claims |
| WireGuard client-profile exports + protocol registry hook | Non-WG commercial protocol packs as a paid product |
| Capability ports (`pkg/ports`) + `remote_access: none\|wireguard` | BMC/Lifecycle product, billing, multi-tenant control plane |
