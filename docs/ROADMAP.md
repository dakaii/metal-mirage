# metal-mirage roadmap

In-repo tracking for the open-source platform. Prefer this file over a flood of GitHub issues.

**Scope rule:** everything here must keep the stack **usable standalone** (Pulumi + Talos metal-sim + Flux + optional VPN + optional peer API). Paid product surfaces stay out of this repo.

## Now (OSS core — must work)

| Area | Status intent |
|------|----------------|
| Pulumi Go stacks: `primary` (Talos metal-sim), `standby-aks`, `shared` (Traffic Manager + witness), `vpn-gateways` | Ship / harden |
| Scripts: `register-talos-image`, `up` / `destroy`, `vpn-bootstrap`, `install-flux`, `deploy-witness` | Documented, runnable |
| GitOps: Flux bootstrap path + demo app + monitoring scrape/alert hints | Kustomize-valid |
| Docs: ARCHITECTURE, DEPLOY, VPN, COST, PORTABLE, CONFIG, this ROADMAP | Honest portfolio/self-host framing |
| Optional Phase 3 demo: Clerk + Neon peer registry in `control-plane/` | Minimal API only; clearly optional |
| CI: Go build matrix + kustomize smoke | Keep green |

## Next (OSS hardening)

- Portable L1 switch: `azure-metal-sim` → real bare metal with the same Talos machine-config + Flux contract ([PORTABLE-ARCHITECTURE.md](PORTABLE-ARCHITECTURE.md))
- Operator runbooks: DR drill (Traffic Manager + witness), VPN peer lifecycle without a SaaS product
- Deeper VPN observability (Prometheus scrape wiring, dashboard polish) — still single-tenant / self-host
- Contributor UX: config examples, clearer failure messages in scripts, secret-scan hygiene
- Optional: small reconciler that pushes peer pubkeys from the control-plane DB to the VPN VM (operator-grade, not multi-tenant abuse controls)

## Later — commercial / out of this repo

Do **not** implement these in metal-mirage. Keep them in a separate commercial codebase if pursued:

- Stripe / Clerk Billing, subscriptions, invoices, payment webhooks
- Multi-tenant SaaS abuse prevention, rate limits, entitlement gates, metering
- Proprietary branding, App Store / consumer mobile apps, “bypass geo-blocks” marketing
- Managed hosted control plane as a paid product
- Hard-coded vendor secrets or license keys

The optional Clerk + Neon peer API in OSS is a **demo**, not a billing surface. Pushing peers onto the VPN VM remains an operator step unless a thin open reconciler lands under **Next**.

## Boundary checklist (when reviewing PRs)

| In OSS | Out of OSS |
|--------|------------|
| IaC, GitOps, witness, WireGuard city exits | Payments / subscriptions |
| Self-host deploy docs + cost honesty | Multi-tenant product abuse stack |
| Optional peer minting API (no billing) | App Store clients / proprietary branding |
| Apache-2.0 portfolio platform | “Commercial VPN product” claims |
