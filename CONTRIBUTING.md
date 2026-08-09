# Contributing

## Workflow

1. Branch from up-to-date `main` (`git checkout -b feat/...` or `fix/...`).
2. Open a pull request into `main`.
3. Wait for **CI** (`.github/workflows/ci.yml`) to pass before merge.
4. Do **not** push feature work straight to `main`.

Use `feat/` for new work and `fix/` for bugfixes. Small docs/chore branches (`chore/...`, `docs/...`) are fine.

## Local checks (optional)

Need **Go 1.26.x** (CI matrix / infra modules). After `go mod tidy`, `go.mod`/`go.sum` must stay clean or CI fails.

```bash
# Go modules (same gates as CI matrix)
for d in infra/*/ control-plane; do
  (
    cd "$d" || exit 1
    go mod tidy
    git diff --exit-code -- go.mod go.sum || {
      echo "go mod tidy dirty in $d — commit the result" >&2
      exit 1
    }
    unformatted="$(gofmt -l .)"
    if [ -n "$unformatted" ]; then
      echo "gofmt needed in $d:" >&2
      echo "$unformatted" >&2
      exit 1
    fi
    go vet ./... && go build ./...
  )
done

shellcheck -x scripts/*.sh   # -x follows sourced helpers (e.g. lib.sh)
actionlint                   # if installed: brew install actionlint
./scripts/validate-inventory.sh
```

There is **no** `pulumi preview` in CI (needs Azure credentials). Run previews locally when changing stacks:

```bash
cd infra/primary && pulumi preview
```

## Branch protection (maintainers)

`main` uses GitHub **branch protection**: PRs required, and these **CI** status checks must pass (names must match exactly):

- `go-build (infra/primary)`
- `go-build (infra/bare-metal)`
- `go-build (infra/standby-aks)`
- `go-build (infra/shared)`
- `go-build (infra/vpn-gateways)`
- `go-build (infra/flux-bootstrap)`
- `go-build (control-plane)`
- `kustomize`
- `scripts`
- `actionlint`
- `gitleaks`

To (re)configure: Repo → **Settings** → **Branches** → rule for `main` → require a pull request, then require the checks above (they appear after CI has run once on a PR). Optionally leave **Do not allow bypassing the above settings** off so admins can hotfix in an emergency.

After the first green CI run that introduces a new job, add that check name via UI or:

```bash
# Example: append new required contexts (replace with full desired list)
gh api repos/dakaii/metal-mirage/branches/main/protection/required_status_checks \
  --method PATCH \
  -f strict=true \
  -f 'contexts[]=go-build (infra/primary)' \
  -f 'contexts[]=go-build (infra/bare-metal)' \
  -f 'contexts[]=go-build (infra/standby-aks)' \
  -f 'contexts[]=go-build (infra/shared)' \
  -f 'contexts[]=go-build (infra/vpn-gateways)' \
  -f 'contexts[]=go-build (infra/flux-bootstrap)' \
  -f 'contexts[]=go-build (control-plane)' \
  -f 'contexts[]=kustomize' \
  -f 'contexts[]=scripts' \
  -f 'contexts[]=actionlint' \
  -f 'contexts[]=gitleaks'
```

If the API or UI rejects protection (plan limits / missing permissions), keep this file as the source of truth and enforce the PR habit manually.

## CI scope (intentionally skipped)

| Check | Why skipped |
|-------|-------------|
| `pulumi preview` / deploy | Needs Azure secrets; keep OSS CI credential-free |
| Path-filtered jobs | Small monorepo; skipped required checks complicate branch protection |
| Markdown link check | Noisy / flaky on external docs links |
| Full golangci-lint | `gofmt` + `go vet` cover the high-signal bar without a lint config |
