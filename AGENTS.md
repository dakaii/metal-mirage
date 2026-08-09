# AGENTS.md

## Cursor Cloud specific instructions

This repo is an **Infrastructure-as-Code / GitOps** project (Pulumi Go + Talos on Azure + Flux), not a conventional app. Most of it is not "runnable" locally — the `infra/*` Pulumi programs provision real Azure resources and need Azure credentials + a Pulumi backend (`az login`, `pulumi login`). Even `pulumi preview` needs cloud auth, so treat the infra stacks as build/vet-only in the cloud VM unless Azure secrets are provided.

**`scripts/*.sh` are operator runbooks** (run locally against Azure/Pulumi/VPN VMs). They are **not** GitHub Actions. CI lives in `.github/workflows/ci.yml` and only *checks* those scripts (shellcheck, inventory validation). Bring-up docs: `README.md`, `docs/DEPLOY.md`.

### Toolchain (already provisioned in the VM image)
- **Go 1.26.5** is required — `infra/*` modules pin `go 1.26.5` (control-plane pins `go 1.25.0`) and the base image's Go 1.22 will not build them. Installed at `/usr/local/go` (symlinked into `/usr/local/bin`).
- **Pulumi** (`/usr/local/bin/pulumi`) and **kustomize v5.4.3** (`/usr/local/bin/kustomize`) are installed.
- Every `infra/*` dir and `control-plane/` is a **separate Go module** (no `go.work`); run `go build` / `go vet` / `go test` per-module.

### Primary provisioner switch
- `config/clusters.yaml` → `primary.pulumi_dir` selects `infra/primary` (azure-metal-sim) or `infra/bare-metal`.
- `./scripts/up.sh primary` / `./scripts/destroy.sh primary` resolve that path via `scripts/lib.sh`.
- Offline inventory check (no Azure/hardware): `./scripts/validate-inventory.sh`.
- Bare-metal example: `config/clusters.bare-metal.example.yaml`. Details: `docs/PORTABLE-ARCHITECTURE.md`.

### CI-equivalent checks (see `.github/workflows/ci.yml` and `CONTRIBUTING.md`)
- Per Go module (`infra/primary`, `infra/bare-metal`, `infra/standby-aks`, `infra/shared`, `infra/vpn-gateways`, `infra/flux-bootstrap`, `control-plane`): `go mod tidy` (must leave `go.mod`/`go.sum` clean), `gofmt -l`, `go vet ./...`, `go build ./...`.
- `go test ./...` for `infra/bare-metal` (inventory contract) and `control-plane` (peer IP allocation) when those modules have tests.
- `kustomize build` on `gitops/apps`, `gitops/infrastructure`, `gitops/infrastructure/monitoring`, `gitops/clusters/primary`, `gitops/clusters/standby`.
- From repo root: `shellcheck -x scripts/*.sh` (sourced helpers use `# shellcheck source=scripts/lib.sh`) and `./scripts/validate-inventory.sh`.
- Also: `actionlint` on `.github/workflows`; `gitleaks` secret scan. No `pulumi preview` in CI (needs Azure).

### control-plane (the only locally runnable service)
- `cd control-plane && go run ./cmd/server` — loads `.env` via `godotenv`, connects to Postgres, runs a migration that creates the `peers` table, initializes Clerk, and listens on `:PORT` (default 8080). See `control-plane/README.md` and `control-plane/.env.example`.
- Requires `DATABASE_URL` (a Neon Postgres works) and `CLERK_SECRET_KEY`. A **placeholder `CLERK_SECRET_KEY` is enough to boot and serve the public `GET /healthz`**, but the `/api/peers*` routes require a real Clerk-issued Bearer session JWT — without a Clerk instance they correctly return `401`.
- Gotcha: `DATABASE_URL` contains `&` (query params), so `set -a; . control-plane/.env` mangles it. Let the app load `.env` itself (via `go run ./cmd/server`), or `export DATABASE_URL='...'` with single quotes.
- `control-plane/.env` is gitignored — never commit real connection strings.
- Peer IPs are allocated in Postgres (`10.66.0.2`–`.251`); `vpn-bootstrap.sh` reads live `wg` state. The two can drift until a reconciler exists.
