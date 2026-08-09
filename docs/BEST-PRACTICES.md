# metal-mirage best practices

Short, actionable checklist for operators and contributors. Scope is **self-hostable OSS core** only — see [ROADMAP.md](ROADMAP.md) for the commercial boundary.

## Pulumi

| Do | Why |
|----|-----|
| One stack per concern (`primary`, `standby-aks`, `shared`, `vpn-gateways`, `flux-bootstrap`) | Independent destroy / billing control |
| `pulumi config set --secret` for kubeconfigs and credentials | Encrypted in stack state, never plaintext YAML in git |
| Keep `Pulumi.<stack>.yaml` gitignored; commit `Pulumi.yaml` + `*.yaml.example` | No secrets in PRs |
| Export kubeconfig with `pulumi.ToSecret(...)` | Prevents accidental `pulumi stack output` leaks |
| `./scripts/destroy.sh all` when idle | Azure VMs/AKS bill while running — see [COST.md](COST.md) |
| Prefer `azure-native` typed resources + Standard PIP/LB SKUs | Matches current Azure defaults; Basic SKU is legacy |

## Talos (metal-sim)

| Do | Why |
|----|-----|
| Treat `/dev/sda` as the default install disk (`primary:installDisk`) | Azure Gen2 Talos VHD usually maps OS disk here; real metal may differ |
| Bake install-disk into `GetConfiguration` `ConfigPatches` (customData == apply) | Reproducible first boot; matches bare-metal |
| Bootstrap once on the first control-plane; kubeconfig `DependsOn` Bootstrap | Avoid racing etcd/API on first `pulumi up` |
| Give metal-sim workers a public IP for `ConfigurationApply` | Operator laptop cannot reach private-only NICs |
| Lock Talos APIs (`50000`/`50001`) and etcd to `primary:adminCidr` | Least privilege; HTTP/demo stay open for Traffic Manager |
| Leave `:6443` open if using the witness Function | Function egress ≠ your adminCidr |
| Persist witness failure counts in blob storage, not `/tmp` | Consumption Y1 has no sticky local disk |

## Azure networking & DR

| Do | Why |
|----|-----|
| Traffic Manager → **ingress** public IP, path `/healthz` on `:80` | Matches demo nginx + Azure LB → NodePort `30080` |
| Do not point Traffic Manager at the Talos API PIP | API is not the app health surface |
| Treat primary `AdminPassword` as Azure API filler | Talos never uses it; keep the constant for idempotent VM updates |
| VPN: UDP `51820` from `*`; SSH/`9100` from `vpn:adminCidr` | Peers are remote; management plane is not |
| AKS: workload identity + OIDC enabled; Velero identity has **Storage Blob Data Contributor** (`ba92a5b7-b7df-409c-b29b-3a3a5c1f4c5e`) | Correct built-in role GUID for blob backup |
| Destroy stacks in dependency order (vpn → shared → flux → standby → primary) | Avoid dangling endpoints / failed destroys |

## WireGuard

| Do | Why |
|----|-----|
| Keep `vpn-clients/` gitignored | Private keys live only on disk |
| Full-tunnel `AllowedIPs = 0.0.0.0/0, ::/0` is intentional — say so | Honesty for portfolio/self-host |
| cloud-init must be idempotent (reuse `server.key`, preserve `[Peer]` on rewrite) | VM reprovision / script re-runs |
| Mint peers with `scripts/vpn-bootstrap.sh`; do not commit `.conf` files | Operator path, not SaaS onboarding |
| After control-plane `POST /api/peers`, run `scripts/vpn-reconcile-peers.sh` | API writes Neon only; VM is a projection |
| Default reconcile without `--prune` | Keeps bootstrap-only peers; prune only when DB is intentional SoT |
| Practice failover with [DR.md](DR.md) | TM DNS TTL + witness logs ≠ automatic cutover |

## GitOps (Flux)

| Do | Why |
|----|-----|
| Controllers via `infra/flux-bootstrap` (or `flux install`); source + root via `scripts/install-flux.sh` | Clear split |
| Cluster overlays are real kustomize (`kustomization.yaml` → `flux.yaml` CRs) | Flux path must `kustomize build` cleanly |
| `prune: true` on Flux Kustomizations | Drift cleanup |
| Standby patches `replicas: 0` on demo | Cold standby / cost |
| **Do not** apply `PrometheusRule` until kube-prometheus-stack (CRD) exists | Default monitoring ships ConfigMap **hints** only; optional YAML under `monitoring/optional/` |

## Go / CI / license

| Do | Why |
|----|-----|
| Keep each Pulumi program and `control-plane/` as its own module | Independent versioning |
| CI: `go mod tidy` + `gofmt` + `go vet` + `go build` per module, kustomize, shellcheck, actionlint, gitleaks | PR QA without Azure credentials; see [CONTRIBUTING.md](../CONTRIBUTING.md) |
| Prefer PRs into `main` (`feat/` / `fix/`); keep CI green | See [CONTRIBUTING.md](../CONTRIBUTING.md) |
| Apache-2.0 (`LICENSE`) | Explicit OSS terms |
| Ignore local Pulumi binaries (`infra/*/infra-*`) | Huge accidental commits |

## Security hygiene

| Do | Why |
|----|-----|
| Never commit kubeconfigs, talosconfigs, `.env`, `*.key`, `vpn-clients/` | Covered by `.gitignore` |
| Default `adminCidr=0.0.0.0/0` is demo-only — set your `/32` before real use | SSH / Talos APIs / node_exporter |
| No Stripe/billing keys in this repo | OSS boundary |
| README cost + failover TTL honesty | Portfolio claims stay accurate |

## OSS vs commercial

In-repo: IaC, GitOps, witness, WireGuard city exits, optional Clerk+Neon peer **demo** API.

Out of repo: Stripe/Clerk Billing, multi-tenant abuse controls, geo-bypass marketing, managed paid control plane. Details: [ROADMAP.md](ROADMAP.md).
