# Contributing

## Workflow

1. Branch from up-to-date `main` (`git checkout -b feat/...` or `fix/...`).
2. Open a pull request into `main`.
3. Wait for **CI** (`.github/workflows/ci.yml`) to pass before merge.
4. Do **not** push feature work straight to `main`.

Use `feat/` for new work and `fix/` for bugfixes. Small docs/chore branches (`chore/...`, `docs/...`) are fine.

## Branch protection (maintainers)

`main` uses GitHub **branch protection**: PRs required, and these **CI** status checks must pass (names must match exactly):

- `go-build (infra/primary)`
- `go-build (infra/standby-aks)`
- `go-build (infra/shared)`
- `go-build (infra/vpn-gateways)`
- `go-build (infra/flux-bootstrap)`
- `go-build (control-plane)`
- `kustomize`
- `scripts`

To (re)configure: Repo → **Settings** → **Branches** → rule for `main` → require a pull request, then require the checks above (they appear after CI has run once on a PR). Optionally leave **Do not allow bypassing the above settings** off so admins can hotfix in an emergency.

If the API or UI rejects protection (plan limits / missing permissions), keep this file as the source of truth and enforce the PR habit manually.
