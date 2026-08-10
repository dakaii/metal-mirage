# Auto-failover modes (best practices + feasibility)

Personal/self-host DR for metal-mirage has **three independent planes**. Only Traffic Manager DNS failover is “automatic” out of the box. Cold-standby promote stays **opt-in** on purpose.

## Feasibility verdict

| Mode | Feasible here? | Best-practice note |
|------|----------------|--------------------|
| **A. Off (default)** | Yes | Witness logs `FAILOVER_CANDIDATE`; operator runs `./scripts/failover-promote.sh`. Safest for demos and cost. |
| **B. Notify webhook** | Yes | POSTs once at threshold. Pair with Slack / Logic App / pager. No Azure ARM from the Function. |
| **C. GitHub promote runner** | Yes (opt-in) | Witness → `repository_dispatch` → `.github/workflows/failover-promote.yml`. Live promote requires `FAILOVER_AUTO_PROMOTE=true` **and** secrets. |
| **D. In-Function ARM promote** | Deferred | Needs MSI + RBAC on AKS + Traffic Manager. Heavier blast radius; not shipped. |
| **E. Warm standby always-on** | Manual | Keep standby `replicas > 0` so TM DNS failover alone is enough (higher idle cost). |
| **F. Auto-failback** | Not recommended | Primary flapping would thrash Flux/TM. Failback stays operator-driven. |

## What is already automatic

Azure **Traffic Manager** priority routing probes demo HTTP `:80/healthz`.

- Interval ~30s × 3 failures ≈ **≥90s** probe time, plus profile **TTL 30s** and recursive DNS caches.
- This is **DNS failover**, not L4/session cutover. Honest RTO for “users follow `$FQDN`” is **minutes**, not seconds.
- Cold standby (`gitops/clusters/standby` → `replicas: 0`) often means the priority-2 endpoint is **unhealthy** until you promote — so DNS alone may not save you until standby `/healthz` is green.

## What is not automatic (by design)

| Signal / action | Actor |
|-----------------|--------|
| Kubernetes API `/readyz` probe | Witness Function (every 1 min, threshold 3) |
| Scale standby demo / suspend Flux | `./scripts/failover-promote.sh` or GHA workflow |
| Disable TM primary (half-dead `/healthz`) | Same script with `--disable-primary-tm` |
| Failback | `--failback` only (manual) |

Witness stays **least-privilege**: it does not call Azure ARM or `kubectl`. That matches common DR practice (detect ≠ act) and keeps Consumption Y1 simple.

## Mode A — Off (default)

```bash
# shared:enableWitness true (default); leave webhook / GitHub unset
# On FAILOVER_CANDIDATE:
./scripts/failover-promote.sh --dry-run
./scripts/failover-promote.sh
./scripts/failover-promote.sh --failback   # when primary is healthy again
```

See [DR.md](DR.md) for full drills.

## Mode B — Generic HTTPS webhook

```bash
pulumi -C infra/shared config set --secret shared:failoverWebhookURL 'https://hooks.example/…'
# optional HMAC (receiver verifies X-Metal-Mirage-Signature: sha256=…)
pulumi -C infra/shared config set --secret shared:failoverWebhookHMACSecret '…'
pulumi -C infra/shared up
./scripts/deploy-witness.sh
```

Payload (`schema_version: 1`), posted **once** when `consecutive_failures == threshold`:

```json
{
  "event": "FAILOVER_CANDIDATE",
  "consecutive_failures": 3,
  "threshold": 3,
  "primary_api_url": "https://…:6443/readyz",
  "source": "metal-mirage-witness",
  "recommended_action": "promote_standby",
  "schema_version": 1
}
```

HMAC: raw body is `json.dumps(..., sort_keys=True, separators=(",", ":"))`, signed with SHA-256, header `X-Metal-Mirage-Signature: sha256=<hex>`.

## Mode C — GitHub Actions promote (recommended opt-in automation)

### 1. Wire the witness to GitHub

```bash
# Token must be able to create repository_dispatch on THIS repo only:
#   Fine-grained PAT: Repository access → only OWNER/metal-mirage;
#     Permissions → Contents: Read and write  (required for POST …/dispatches)
#   Classic PAT: repo scope (broader — prefer fine-grained)
# Do not use a token with admin/org-wide access. Rotate after enablement tests.
pulumi -C infra/shared config set shared:failoverGitHubRepo 'OWNER/metal-mirage'
pulumi -C infra/shared config set --secret shared:failoverGitHubToken 'github_pat_…'
pulumi -C infra/shared up
./scripts/deploy-witness.sh
```

You can combine Modes B and C. Either alone is enough to notify.

The token lives in Function App settings (long-lived). Treat a leak as “attacker can queue `failover-candidate` workflows”; with `FAILOVER_AUTO_PROMOTE=true` that becomes a live promote. Keep auto-promote off until the token is scoped and rotated on a schedule (or replace later with a GitHub App installation token).

### 2. Repository secrets / variables

| Name | Kind | Purpose |
|------|------|---------|
| `STANDBY_KUBECONFIG` | secret | Full AKS standby kubeconfig YAML |
| `AZURE_CREDENTIALS` | secret | `azure/login` JSON — **only** if you disable TM primary |
| `FAILOVER_AUTO_PROMOTE` | variable | Must be exactly `true` for `repository_dispatch` to promote live |
| `FAILOVER_DISABLE_PRIMARY_TM` | variable | `true` → pass `--disable-primary-tm` on auto runs |
| `FAILOVER_REPLICAS` | variable | Default `2` |
| `TM_RESOURCE_GROUP` / `TM_PROFILE_NAME` / `TM_PRIMARY_ENDPOINT` | variables | Skip Pulumi on the runner when disabling TM |

### 3. Safe rollout

1. Leave `FAILOVER_AUTO_PROMOTE` unset → dispatch only **dry-runs** (prints planned kubectl/az).
2. Run **Actions → Failover promote** with `dry_run=true`, then once with `dry_run=false`.
3. Set `FAILOVER_AUTO_PROMOTE=true` only after a successful manual promote.
4. **Never** enable auto-failback in CI.

### 4. Expected RTO (Mode C, cold standby)

| Phase | Typical |
|-------|---------|
| Witness threshold | ~3 minutes (1/min × 3) |
| GitHub queue + runner start | ~1–3 minutes |
| Suspend Flux + scale demo | tens of seconds |
| Pod Ready + TM still on primary `/healthz` | until primary app fails **or** you disable TM primary |
| DNS clients switch after TM marks primary down | TTL + caches (often **1–5+ minutes**) |

End-to-end “API down → users on standby” is commonly **~5–15 minutes**, not sub-minute. For faster app failover without promote automation, use **Mode E** (warm standby) so TM can move traffic as soon as primary `/healthz` fails.

## Security checklist

- Prefer **HMAC** on generic webhooks (`X-Metal-Mirage-Signature`); receivers must verify before acting.
- Prefer a **fine-grained PAT** limited to this repository with **Contents: Read and write** (not “Actions: write” alone — that is insufficient for `repository_dispatch`).
- Store `failoverGitHubToken` / HMAC / webhook URL via `pulumi config set --secret`; rotate periodically and after any suspected leak.
- Keep `FAILOVER_AUTO_PROMOTE` off until secrets and RBAC are correct; stolen dispatch token + auto-promote = unauthorized scale.
- Service principal / `AZURE_CREDENTIALS` needs Traffic Manager endpoint update only when using `--disable-primary-tm`.
- Standby kubeconfig is cluster-admin equivalent — treat like production credentials.
- Workflow logs should not dump full `client_payload` (may include API URLs / IPs).

## Why not promote inside the Function?

- MSI + AKS RBAC + TM Contributor on a Consumption app widens blast radius.
- Retries / dual-fires are harder to reason about than a single GitHub concurrency group (`failover-promote`).
- OSS operators already have GHA; Logic Apps are fine as a Mode B target instead.

## Related

| Doc / path | Role |
|------------|------|
| [DR.md](DR.md) | Manual drills A/B/C |
| [CONFIG.md](CONFIG.md) | `shared:*` keys |
| [BEST-PRACTICES.md](BEST-PRACTICES.md) | Operator checklist |
| `infra/shared/witness/notify.py` | Payload + HMAC + GitHub dispatch |
| `scripts/failover-promote.sh` | Promote / failback |
| `.github/workflows/failover-promote.yml` | Opt-in runner |
