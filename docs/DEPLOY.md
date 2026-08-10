# Deploy guide

**Prefer metal-first:** [METAL-PRIMARY.md](METAL-PRIMARY.md) (default
`config/clusters.yaml`). This guide covers the full multi-stack path (Azure
metal-sim lab, AKS standby, witness, optional VPN).

Config key reference: [CONFIG.md](CONFIG.md). Operator checklist: [BEST-PRACTICES.md](BEST-PRACTICES.md). Roadmap / OSS boundary: [ROADMAP.md](ROADMAP.md).

## Prerequisites

- [Pulumi](https://www.pulumi.com/docs/install/) 3.x + Go 1.26.x (matches CI / `infra/*/go.mod`; see AGENTS.md)
- `talosctl`, `kubectl`, `flux` (optional until GitOps step)
- Azure CLI + subscription — only for metal-sim lab, AKS standby, Traffic Manager, or WireGuard city VM
- `wg` / WireGuard tools — only when `remote_access.provider: wireguard`
- Domain optional (Traffic Manager gives `*.trafficmanager.net`)

Auth helper (opens vendor login flows only when needed):

```bash
./scripts/login.sh --skip-azure    # Pulumi only (metal dry-run / no Azure)
./scripts/login.sh                 # Azure + Pulumi
./scripts/login.sh --status        # report only
./scripts/login.sh --local-pulumi  # file-backed Pulumi state
./scripts/login.sh --control-plane # check control-plane/.env (Neon + Clerk)
./scripts/login.sh --clerk-keyless # optional Clerk keyless demo keys (AGENTS.md)
```

Headless / no browser: `AZURE_LOGIN_FLAGS=--use-device-code ./scripts/login.sh`

## 1. Register Talos image (once — Azure metal-sim lab only)

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

### 2b. Preferred primary: bare metal (portable L1)

Default `config/clusters.yaml` already points at `infra/bare-metal` with
`dry_run: true`. Inventory SoT is `primary.nodes` (synced to Pulumi — no dual edit).
Full golden path: [METAL-PRIMARY.md](METAL-PRIMARY.md).

```bash
# 1. Edit config/clusters.yaml IPs / install_disk for your hardware
# 2. Offline contract check (no Azure / no nodes required):
./scripts/validate-inventory.sh
# 3. Sync + pulumi up (dry_run generates secrets/configs only)
./scripts/up.sh primary
```

Live apply: install Talos to maintenance mode, set `dry_run: false` in
`clusters.yaml`, re-run `up.sh primary`. Ingress options (NodePort / MetalLB / BYO):
see [METAL-PRIMARY.md](METAL-PRIMARY.md).

Azure metal-sim lab: copy `config/clusters.azure-metal-sim.example.yaml` over
`config/clusters.yaml`, then follow §2 above.

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

## 5. VPN city exit (opt-in RemoteAccess)

Default `remote_access.provider: none` — `./scripts/up.sh vpn` will **skip**
(exit 0) until you set `provider: wireguard` in `config/clusters.yaml`. See
[VPN.md](VPN.md) / [CAPABILITY-PORTS.md](CAPABILITY-PORTS.md).

```bash
# config/clusters.yaml → remote_access.provider: wireguard
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
