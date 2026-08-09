# metal-mirage roadmap

In-repo tracking for the open-source platform. Prefer this file over a flood of GitHub issues.

**Scope rule:** everything here must keep the stack **usable standalone** (Pulumi + Talos metal-sim + Flux + optional VPN + optional peer API). Paid product surfaces stay out of this repo.

## Now (OSS core — must work)

| Area | Status intent |
|------|----------------|
| Pulumi Go stacks: `primary` (Talos metal-sim), `bare-metal` (thin L1), `standby-aks`, `shared` (Traffic Manager + witness), `vpn-gateways` | Ship / harden |
| Scripts: `register-talos-image`, `up` / `destroy`, `validate-inventory`, `vpn-bootstrap`, `vpn-reconcile-peers`, `install-flux`, `deploy-witness` | Documented, runnable |
| GitOps: Flux bootstrap path + demo app + monitoring scrape/alert hints | Kustomize-valid |
| Docs: ARCHITECTURE, DEPLOY, VPN, COST, PORTABLE, CONFIG, BEST-PRACTICES, this ROADMAP | Honest portfolio/self-host framing |
| Optional Phase 3 demo: Clerk + Neon peer registry in `control-plane/` | Minimal API only; clearly optional |
| CI: Go build/fmt/vet matrix (incl. `infra/bare-metal` + inventory tests) + kustomize + shellcheck + actionlint + gitleaks; PRs into `main` ([CONTRIBUTING.md](../CONTRIBUTING.md)) | Keep green; no Azure secrets in CI |
| Portable L1 switch: `azure-metal-sim` → `infra/bare-metal` + inventory contract + dryRun offline demo | Done (live metal still needs hardware + `dryRun=false`) — [PORTABLE-ARCHITECTURE.md](PORTABLE-ARCHITECTURE.md) |

## Next (OSS hardening)

- Automate witness hook (Event Grid / scale standby) beyond `FAILOVER_CANDIDATE` logs — still optional
- Contributor UX: secret-scan hygiene polish

### Recently landed

- Contributor UX: clearer script errors (`lib.sh` helpers), bare-metal dual-inventory docs, Go 1.26 prereqs
- VPN observability: Helm scrape fragment + adminCidr caveat, Grafana dashboard polish, node_exporter disk/memory alerts (no WG exporter)
- DR drill runbook: [DR.md](DR.md) (Traffic Manager `:80/healthz` vs witness `:6443/readyz`)
- Optional peer reconciler: `./scripts/vpn-reconcile-peers.sh` (+ `control-plane/cmd/listpeers`) — DB → `wg set`, optional `--prune`

## Later — commercial / out of this repo

Do **not** implement these in metal-mirage. Keep them in a separate commercial codebase if pursued:

- Stripe / Clerk Billing, subscriptions, invoices, payment webhooks
- Multi-tenant SaaS abuse prevention, rate limits, entitlement gates, metering
- Proprietary branding, App Store / consumer mobile apps, “bypass geo-blocks” marketing
- Managed hosted control plane as a paid product
- Hard-coded vendor secrets or license keys

The optional Clerk + Neon peer API in OSS is a **demo**, not a billing surface. Pushing peers onto the VPN VM is an operator step via `./scripts/vpn-reconcile-peers.sh` (not inlined into `POST /api/peers`).

## Boundary checklist (when reviewing PRs)

| In OSS | Out of OSS |
|--------|------------|
| IaC, GitOps, witness, WireGuard city exits | Payments / subscriptions |
| Self-host deploy docs + cost honesty | Multi-tenant product abuse stack |
| Optional peer minting API (no billing) | App Store clients / proprietary branding |
| Apache-2.0 portfolio platform | “Commercial VPN product” claims |
