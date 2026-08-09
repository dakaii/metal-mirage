# Deploy guide

Config key reference: [CONFIG.md](CONFIG.md). Operator checklist: [BEST-PRACTICES.md](BEST-PRACTICES.md). Roadmap / OSS boundary: [ROADMAP.md](ROADMAP.md).

## Prerequisites

- Azure CLI (`az login`) with a subscription
- [Pulumi](https://www.pulumi.com/docs/install/) 3.x
- Go 1.22+
- `talosctl`, `kubectl`, `flux` (optional until GitOps step)
- `wg` / WireGuard tools (for VPN peer scripts)
- Domain optional (Traffic Manager gives `*.trafficmanager.net`)

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

Primary exposes the demo via an Azure Load Balancer on the `ingressIP` → NodePort `30080` (no cloud-controller / Traefik required for the portfolio path).

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
```

## Tear down

```bash
./scripts/destroy.sh all
```

See [COST.md](COST.md) for idle-billing notes.
