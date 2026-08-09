# Contributing

## Workflow

1. Branch from up-to-date `main` (`git checkout -b feat/...` or `fix/...`).
2. Open a pull request into `main`.
3. Wait for **CI** (`.github/workflows/ci.yml`) to pass before merge.
4. Do **not** push feature work straight to `main`.

Use `feat/` for new work and `fix/` for bugfixes. Small docs/chore branches (`chore/...`, `docs/...`) are fine.

## Branch protection (maintainers)

Prefer GitHub **branch protection** (or a ruleset) on `main`:

1. Repo → **Settings** → **Branches** → **Add branch protection rule** (pattern `main`).
2. Enable **Require a pull request before merging**.
3. Enable **Require status checks to pass before merging** and select the checks from workflow **CI** (`go-build` matrix jobs, `kustomize`, `scripts`) once they have run at least once on a PR.
4. Optionally leave **Do not allow bypassing the above settings** off so admins can hotfix in an emergency.

If the API or UI rejects protection (plan limits / missing permissions), keep this file as the source of truth and enforce the PR habit manually.
