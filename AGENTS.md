# AGENTS.md

## Cursor Cloud specific instructions

This repo is an **Infrastructure-as-Code / GitOps** project (Pulumi Go + Talos on Azure + Flux), not a conventional app. Most of it is not "runnable" locally — the `infra/*` Pulumi programs provision real Azure resources and need Azure credentials + a Pulumi backend (`az login`, `pulumi login`). Even `pulumi preview` needs cloud auth, so treat the infra stacks as build/vet-only in the cloud VM unless Azure secrets are provided.

**`scripts/*.sh` are operator runbooks** (run locally against Azure/Pulumi/VPN VMs). They are **not** GitHub Actions. CI lives in `.github/workflows/ci.yml` and only *checks* those scripts (shellcheck, inventory validation). Bring-up docs: `README.md`, `docs/DEPLOY.md`.

Auth: `./scripts/login.sh` (Azure + Pulumi; `--status`, `--local-pulumi`, optional `--control-plane` / `--clerk-keyless`).

### Toolchain (already provisioned in the VM image)
- **Go 1.26.5** is required — `infra/*` modules pin `go 1.26.5` (control-plane pins `go 1.25.0`) and the base image's Go 1.22 will not build them. Installed at `/usr/local/go` (symlinked into `/usr/local/bin`).
- **Pulumi** (`/usr/local/bin/pulumi`) and **kustomize v5.4.3** (`/usr/local/bin/kustomize`) are installed.
- Every `infra/*` dir and `control-plane/` is a **separate Go module** (no `go.work`); run `go build` / `go vet` / `go test` per-module.

### Primary provisioner switch
- `config/clusters.yaml` → `primary.pulumi_dir` selects `infra/primary` (azure-metal-sim) or `infra/bare-metal`.
- `remote_access.provider` (`wireguard` \| `none`) selects the optional RemoteAccess adapter (`docs/CAPABILITY-PORTS.md`).
- `./scripts/up.sh primary` / `./scripts/destroy.sh primary` resolve that path via `scripts/lib.sh`.
- Offline inventory + ports check (no Azure/hardware): `./scripts/validate-inventory.sh`.
- Bare-metal example: `config/clusters.bare-metal.example.yaml`. Details: `docs/PORTABLE-ARCHITECTURE.md`.

### CI-equivalent checks (see `.github/workflows/ci.yml` and `CONTRIBUTING.md`)
- Per Go module (`infra/primary`, `infra/bare-metal`, `infra/standby-aks`, `infra/shared`, `infra/vpn-gateways`, `infra/flux-bootstrap`, `control-plane`, `pkg/ports`): `go mod tidy` (must leave `go.mod`/`go.sum` clean), `gofmt -l`, `go vet ./...`, `go build ./...`.
- `go test ./...` for `infra/bare-metal`, `control-plane`, and `pkg/ports` when those modules have tests.
- `kustomize build` on `gitops/apps`, `gitops/infrastructure`, `gitops/infrastructure/monitoring`, `gitops/clusters/primary`, `gitops/clusters/standby`.
- From repo root: `shellcheck -x scripts/*.sh` (sourced helpers use `# shellcheck source=scripts/lib.sh`) and `./scripts/validate-inventory.sh`.
- Also: `actionlint` on `.github/workflows`; `gitleaks` secret scan. No `pulumi preview` in CI (needs Azure).

### control-plane (the only locally runnable service)
- `cd control-plane && go run ./cmd/server` — loads `.env` via `godotenv`, connects to Postgres, runs a migration that creates the `peers` table, initializes Clerk, and listens on `:PORT` (default 8080). See `control-plane/README.md` and `control-plane/.env.example`.
- Requires `DATABASE_URL` (a Neon Postgres works) and a **valid** `CLERK_SECRET_KEY`. Public `GET /healthz` boots with any non-empty key string; `/api/peers*` needs a real Clerk instance + Bearer session JWT.
- **Clerk MCP in this environment is snippets-only** (`clerk_sdk_snippet` / `list_clerk_sdk_snippets`) — it cannot mint apps or keys.
- **Do not use the Dashboard for agent setup.** Prefer Homebrew Clerk CLI, then keyless init in a throwaway dir (do **not** run this inside `metal-mirage`):
  ```bash
  # Linux cloud VM: install Homebrew once if missing, then:
  #   NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  #   eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv bash)"
  brew install clerk/stable/clerk
  unset CLERK_SECRET_KEY   # important: see gotcha below
  TMP=$(mktemp -d) && cd "$TMP"
  clerk init --framework next --keyless -y --mode agent --no-skills --pm npm
  # keys land in my-clerk-next-app/.env.local — copy CLERK_SECRET_KEY into control-plane/.env
  ```
  (`npx -y clerk@latest …` is fine if brew isn’t available; same flags.)
  Then mint a short-lived session JWT for HTTP tests (Backend API): create user → `POST /v1/sessions` → `POST /v1/sessions/{id}/tokens` → `Authorization: Bearer <jwt>` on `/api/peers`. Tokens expire ~60s.
- **Gotcha — inherited env wins over `.env`:** `godotenv` does **not** override existing process env. Cloud envs may inject a short invalid placeholder `CLERK_SECRET_KEY` (`clerk_key_invalid`) and/or stale `VPN_*` values. Always start with a clean env for those vars, e.g. `env -u CLERK_SECRET_KEY -u VPN_ENDPOINT -u VPN_SERVER_PUBLIC_KEY -u VPN_CITY go run ./cmd/server` after writing `.env`.
- Gotcha: `DATABASE_URL` contains `&` (query params), so `set -a; . control-plane/.env` mangles it. Prefer letting the app load `.env`, or `export DATABASE_URL='...'` with single quotes.
- `control-plane/.env` is gitignored — never commit real connection strings or Clerk secrets.
- Peer IPs are allocated in Postgres (`10.66.0.2`–`.251`); `vpn-bootstrap.sh` reads live `wg` state. Sync DB → VM with `./scripts/vpn-reconcile-peers.sh` (uses `go run ./cmd/listpeers`; optional `--prune`). Needs a real `vpn` Pulumi stack + SSH.
- DR drill steps: [docs/DR.md](docs/DR.md) (TM `:80/healthz` vs witness `:6443/readyz`; witness is advisory only). Operator cutover helper: `./scripts/failover-promote.sh` (suspend Flux + scale standby; optional `--disable-primary-tm`; `--failback`).
