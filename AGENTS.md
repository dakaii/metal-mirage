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
- Requires `DATABASE_URL` (a Neon Postgres works) and a **valid** `CLERK_SECRET_KEY`. Public `GET /healthz` boots with any non-empty key string; `/api/peers*` needs a real Clerk instance + Bearer session JWT.
- **Clerk MCP in this environment is snippets-only** (`clerk_sdk_snippet` / `list_clerk_sdk_snippets`) — it cannot mint apps or keys.
- **Do not use the Dashboard for agent setup.** Provision a real `sk_test_…` without login via Clerk CLI keyless in a throwaway Next app, then copy the secret into gitignored `control-plane/.env`:
  ```bash
  unset CLERK_SECRET_KEY   # important: see gotcha below
  TMP=$(mktemp -d) && cd "$TMP"
  npx -y clerk@latest init --framework next --keyless -y --mode agent --no-skills --pm npm
  # keys land in my-clerk-next-app/.env.local
  ```
  Then mint a short-lived session JWT for HTTP tests (Backend API): create user → `POST /v1/sessions` → `POST /v1/sessions/{id}/tokens` → `Authorization: Bearer <jwt>` on `/api/peers`. Tokens expire ~60s.
- **Gotcha — invalid inherited `CLERK_SECRET_KEY`:** some cloud envs inject a short placeholder `sk_test_…` that Clerk rejects (`clerk_key_invalid`). `godotenv` does **not** override existing process env, so that placeholder wins over `.env` and authenticated routes stay `401`. Always `env -u CLERK_SECRET_KEY go run ./cmd/server` (or export the real key) after writing `.env`.
- Gotcha: `DATABASE_URL` contains `&` (query params), so `set -a; . control-plane/.env` mangles it. Prefer letting the app load `.env`, or `export DATABASE_URL='...'` with single quotes.
- `control-plane/.env` is gitignored — never commit real connection strings or Clerk secrets.
- Peer IPs are allocated in Postgres (`10.66.0.2`–`.251`); `vpn-bootstrap.sh` reads live `wg` state. The two can drift until a reconciler exists.
