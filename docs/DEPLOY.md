# Deploy guide

Config key reference: [CONFIG.md](CONFIG.md). Operator checklist: [BEST-PRACTICES.md](BEST-PRACTICES.md). Roadmap / OSS boundary: [ROADMAP.md](ROADMAP.md).

## Prerequisites

- Azure CLI with a subscription
- [Pulumi](https://www.pulumi.com/docs/install/) 3.x
- Go 1.26.x (matches CI / `infra/*/go.mod`; see AGENTS.md)
- `talosctl`, `kubectl`, `flux` (optional until GitOps step)
- `wg` / WireGuard tools (for VPN peer scripts)
- Domain optional (Traffic Manager gives `*.trafficmanager.net`)

Auth helper (opens vendor login flows only when needed):

```bash
./scripts/login.sh                 # Azure + Pulumi
./scripts/login.sh --status        # report only
./scripts/login.sh --local-pulumi  # file-backed Pulumi state
./scripts/login.sh --control-plane # check control-plane/.env (Neon + Clerk)
./scripts/login.sh --clerk-keyless # optional Clerk keyless demo keys (AGENTS.md)
```

Headless / no browser: `AZURE_LOGIN_FLAGS=--use-device-code ./scripts/login.sh`

## 1. Register Talos image (once)

```bash
./scripts/register-talos-image.sh eastus
cd infra/primary
pulumi stack init dev
pulumi config set azure-native:location eastus
pulumi config set primary:talosImageId '/subscriptions/.../galleries/.../versions/...'
pulumi config set primary:adminCidr "$(curl -fsSL ifconfig.me)/32"
pulumi config set primary:controlPlaneCount 1
pulumi config set primary:workerCount 1
```

## 2. Primary (metal-sim)

```bash
./scripts/up.sh primary
mkdir -p .secrets
pulumi -C infra/primary stack output kubeconfig --show-secrets > .secrets/primary.kubeconfig
export KUBECONFIG=$PWD/.secrets/primary.kubeconfig
kubectl get nodes
# After Flux reconciles the demo app:
#   curl -fsS "http://$(pulumi -C infra/primary stack output ingressIP)/healthz"
```

Primary exposes the demo via an Azure Load Balancer on the `ingressIP` → NodePort `30080` (no cloud-controller / Traefik required for the portfolio path). First `up` after upgrading an existing primary stack will drop the unused NSG `:443` rule (portfolio path is HTTP `:80` only) — expected churn.

Workers get a public IP so Pulumi’s Talos `ConfigurationApply` (from your laptop) can reach them; control-plane node 0 uses the API PIP. Install disk is baked into machine config before VM customData.

### 2b. Alternate primary: bare metal (portable L1)

`./scripts/up.sh primary` follows `config/clusters.yaml` → `primary.pulumi_dir`.
To switch off Azure metal-sim without rewriting GitOps:

```bash
# 1. Point inventory at hardware (see config/clusters.bare-metal.example.yaml)
# 2. Offline contract check (no Azure / no nodes required):
./scripts/validate-inventory.sh
# 3. Also set Pulumi inventory (YAML nodes ≠ Pulumi config):
cd infra/bare-metal && pulumi stack select dev  # or init
pulumi config set baremetal:nodes '[{"role":"controlplane","ip":"192.168.1.10"},{"role":"worker","ip":"192.168.1.11"}]'
pulumi config set baremetal:apiEndpointIP 192.168.1.10
pulumi config set baremetal:dryRun true   # offline default
cd ../..
# 4. Bring up (dryRun generates secrets/configs only)
./scripts/up.sh primary
```

Live apply: install Talos to maintenance mode, set `baremetal:dryRun false`, re-run `up.sh primary`.

## 3. Flux GitOps

```bash
cd infra/flux-bootstrap
pulumi stack init dev
pulumi config set --secret flux:kubeconfig "$(cat ../../.secrets/primary.kubeconfig)"
pulumi config set flux:repoUrl https://github.com/dakaii/metal-mirage
pulumi up --yes
cd ../..
# GitRepository + root Kustomization → gitops/clusters/primary:
export KUBECONFIG=$PWD/.secrets/primary.kubeconfig
GITOPS_REPO_URL=https://github.com/dakaii/metal-mirage ./scripts/install-flux.sh primary
```

## 4. Standby AKS + shared failover

```bash
./scripts/up.sh standby
./scripts/up.sh shared   # up.sh all wires outputs automatically
./scripts/deploy-witness.sh
```

After any later `./scripts/up.sh shared` (or `pulumi up` in `infra/shared`), re-run `./scripts/deploy-witness.sh` so the Function zip picks up dependency/code changes (for example `azure-storage-blob` and the durable failure counter). Pulumi alone does not redeploy the zip.

## 5. VPN city exit

```bash
cd infra/vpn-gateways
pulumi stack init dev
pulumi config set vpn:sshPublicKey "$(cat ~/.ssh/id_ed25519.pub)"
pulumi config set vpn:adminCidr "$(curl -fsSL ifconfig.me)/32"   # lock down when possible
cd ../..
./scripts/up.sh vpn
./scripts/vpn-bootstrap.sh laptop
./scripts/vpn-prometheus-scrape-snippet.sh
# Optional: after control-plane minting
# DATABASE_URL='…' ./scripts/vpn-reconcile-peers.sh
```

Failover drills (Traffic Manager + witness): [DR.md](DR.md).

## Tear down

```bash
./scripts/destroy.sh all
```

See [COST.md](COST.md) for idle-billing notes.
