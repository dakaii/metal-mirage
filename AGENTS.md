# AGENTS.md

## Cursor Cloud specific instructions

This repo is an **Infrastructure-as-Code / GitOps** project (Pulumi Go + Talos on Azure + Flux), not a conventional app. Most of it is not "runnable" locally — the `infra/*` Pulumi programs provision real Azure resources and need Azure credentials + a Pulumi backend (`az login`, `pulumi login`). Even `pulumi preview` needs cloud auth, so treat the infra stacks as build/vet-only in the cloud VM unless Azure secrets are provided. Standard bring-up commands live in `README.md`, `docs/DEPLOY.md`, and `scripts/` (`up.sh`, `destroy.sh`).

### Toolchain (already provisioned in the VM image)
- **Go 1.26.5** is required — the `infra/*` modules pin `go 1.26.5` and the base image's Go 1.22 will not build them. Installed at `/usr/local/go` (symlinked into `/usr/local/bin`).
- **Pulumi** (`/usr/local/bin/pulumi`) and **kustomize v5.4.3** (`/usr/local/bin/kustomize`) are installed.
- Every `infra/*` dir and `control-plane/` is a **separate Go module** (no `go.work`); run `go build` / `go vet` per-module.

### CI-equivalent checks (see `.github/workflows/ci.yml`)
- Per Go module (`infra/primary`, `infra/bare-metal`, `infra/standby-aks`, `infra/shared`, `infra/vpn-gateways`, `infra/flux-bootstrap`, `control-plane`): `go mod tidy` (must leave `go.mod`/`go.sum` clean), `gofmt -l`, `go vet ./...`, `go build ./...`.
- `go test ./...` for `infra/bare-metal` (inventory contract tests). Run `go test ./...` in any other module that has `_test.go` files.
- `kustomize build` on `gitops/apps`, `gitops/infrastructure`, `gitops/infrastructure/monitoring`, `gitops/clusters/primary`, `gitops/clusters/standby`.
- `shellcheck -x scripts/*.sh` and `./scripts/validate-inventory.sh`.
- `actionlint` on `.github/workflows`; `gitleaks` secret scan.

### control-plane (the only locally runnable service)
- `cd control-plane && go run ./cmd/server` — loads `.env` via `godotenv`, connects to Postgres, runs a migration that creates the `peers` table, initializes Clerk, and listens on `:PORT` (default 8080). See `control-plane/README.md` and `control-plane/.env.example`.
- Requires `DATABASE_URL` (a Neon Postgres works) and `CLERK_SECRET_KEY`. A **placeholder `CLERK_SECRET_KEY` is enough to boot and serve the public `GET /healthz`**, but the `/api/peers*` routes require a real Clerk-issued Bearer session JWT — without a Clerk instance they correctly return `401`, so the authenticated peer-mint flow cannot be exercised end-to-end without Clerk credentials.
- Gotcha: `DATABASE_URL` contains `&` (query params), so `set -a; . control-plane/.env` mangles it. Let the app load `.env` itself (via `go run ./cmd/server`), or `export DATABASE_URL='...'` with single quotes.
- `control-plane/.env` is gitignored — never commit real connection strings.
