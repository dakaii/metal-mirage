# Pulumi / control-plane config keys

Copy patterns below into a stack (`pulumi config set …`). Never commit real `Pulumi.*.yaml` secrets (gitignored). See also [BEST-PRACTICES.md](BEST-PRACTICES.md).

Use `--secret` for anything that grants cluster or cloud access (kubeconfig, tokens).

## `infra/primary` (namespace `primary`)

| Key | Required | Default | Notes |
|-----|----------|---------|-------|
| `primary:talosImageId` | yes | — | Gallery image resource ID from `register-talos-image.sh` |
| `primary:location` | no | `eastus` | Azure region |
| `primary:clusterName` | no | `metal-mirage-primary` | Talos cluster name |
| `primary:controlPlaneCount` | no | `1` | Demo-friendly |
| `primary:workerCount` | no | `1` | |
| `primary:vmSize` | no | `Standard_B2s` | |
| `primary:installDisk` | no | `/dev/sda` | Talos `machine.install.disk` patch; Azure Gen2 metal-sim default |
| `primary:adminCidr` | no | `0.0.0.0/0` | Source for Talos APIs + etcd; lock to your `/32` in real use |
| `azure-native:location` | recommended | | Also set for the provider |

Example:

```bash
cd infra/primary
pulumi stack init dev
pulumi config set azure-native:location eastus
pulumi config set primary:talosImageId '/subscriptions/<sub>/resourceGroups/talos-images/providers/Microsoft.Compute/galleries/talosgallery/images/talos/versions/1.9.5'
pulumi config set primary:adminCidr "$(curl -fsSL ifconfig.me)/32"
pulumi config set primary:controlPlaneCount 1
pulumi config set primary:workerCount 1
```

Secret outputs: `kubeconfig` (use `--show-secrets` only locally into `.secrets/`).

## `infra/bare-metal` (namespace `baremetal`)

Thin portable L1 provisioner for real hardware. Same output contract as `infra/primary`
(`kubeconfig`, `apiLoadBalancerIP`, `ingressIP`, `clusterEndpoint`, `provisioner=bare-metal`).
Switch via `config/clusters.yaml` (`provisioner: bare-metal`, `pulumi_dir: infra/bare-metal`).
See [PORTABLE-ARCHITECTURE.md](PORTABLE-ARCHITECTURE.md).

| Key | Required | Default | Notes |
|-----|----------|---------|-------|
| `baremetal:nodes` | yes | — | JSON array: `[{"role":"controlplane","ip":"…"},{"role":"worker","ip":"…"}]` |
| `baremetal:apiEndpointIP` | no | first controlplane IP | VIP or CP IP used in `clusterEndpoint` |
| `baremetal:ingressIP` | no | `apiEndpointIP` | Traffic Manager / demo HTTP target |
| `baremetal:clusterName` | no | `metal-mirage-primary` | Talos cluster name |
| `baremetal:installDisk` | no | `/dev/sda` | Often `/dev/nvme0n1` on real metal |
| `baremetal:dryRun` | no | `true` | `true` = offline: secrets + machine configs only; `false` = apply + bootstrap |

```bash
cd infra/bare-metal
pulumi stack init dev
pulumi config set baremetal:nodes '[{"role":"controlplane","ip":"192.168.1.10"},{"role":"worker","ip":"192.168.1.11"}]'
pulumi config set baremetal:apiEndpointIP 192.168.1.10
pulumi config set baremetal:ingressIP 192.168.1.10
pulumi config set baremetal:installDisk /dev/nvme0n1
pulumi config set baremetal:dryRun true    # offline demo
# pulumi config set baremetal:dryRun false # live apply when nodes are in maintenance mode
```

Validate inventory without cloud/hardware: `./scripts/validate-inventory.sh`.

Secret outputs: `kubeconfig` (empty in dryRun), `machineConfigs`.

## `infra/standby-aks` (namespace `standby`)

| Key | Required | Default |
|-----|----------|---------|
| `standby:location` | no | `eastus` |
| `standby:nodeCount` | no | `1` |
| `standby:vmSize` | no | `Standard_B2s` |
| `standby:kubernetesVersion` | no | (AKS default) |

Prefer `./scripts/up.sh standby` with defaults; only set keys to override:

```bash
cd infra/standby-aks
pulumi stack init dev   # or select
# optional overrides:
# pulumi config set standby:location eastus
# pulumi config set standby:nodeCount 1
cd ../..
./scripts/up.sh standby
```

AKS enables OIDC + workload identity. Velero storage uses a user-assigned identity with Storage Blob Data Contributor on the backup account. Secret output: `kubeconfig`.

## `infra/shared` (namespace `shared`)

| Key | Required | Default | Notes |
|-----|----------|---------|-------|
| `shared:primaryIngressIP` | yes | — | Primary **ingress** public IP (not the API PIP) |
| `shared:primaryAPIURL` | if witness enabled | — | e.g. `https://<api-ip>:6443/readyz` |
| `shared:standbyFQDN` | no | — | AKS FQDN for priority-2 endpoint |
| `shared:appDomain` | no | — | Custom domain hint export only |
| `shared:enableWitness` | no | `true` | Set `false`/`0`/`no` to skip Function App |
| `shared:witnessFailureThreshold` | no | `3` | Consecutive failed `/readyz` probes before `FAILOVER_CANDIDATE` |
| `shared:failoverWebhookURL` | no | — | Optional HTTPS webhook; POSTed once when the threshold is crossed (use `pulumi config set --secret`) |
| `shared:location` | no | `eastus` | |

Witness consecutive-failure state is stored in a private blob container (`witness-state`) on the Function storage account — not `/tmp` — so Consumption (Y1) cold starts keep the counter. After changing witness code or `failoverWebhookURL`, re-run `./scripts/deploy-witness.sh` (and `pulumi up` shared for app settings).

`./scripts/up.sh shared` and `./scripts/up.sh all` wire ingress IP / API URL / standby FQDN from stack outputs when present.

Traffic Manager monitor: HTTP `:80` path `/healthz` (demo nginx).

Stable TM names (for `./scripts/failover-promote.sh`): profile / DNS relative name `metal-mirage-app`, endpoints `primary` / `standby`. Stack exports: `trafficManagerProfileName`, `trafficManagerPrimaryEndpoint`, `trafficManagerStandbyEndpoint`, `resourceGroupName`.

After a `FAILOVER_CANDIDATE` (or for Drill A), operators warm standby with:

```bash
./scripts/failover-promote.sh
# optional: ./scripts/failover-promote.sh --disable-primary-tm
./scripts/failover-promote.sh --failback
```

## `config/clusters.yaml` — RemoteAccess port

| Key | Values | Notes |
|-----|--------|-------|
| `remote_access.provider` | `wireguard` (default) \| `none` | `none` skips `./scripts/up.sh vpn` |
| `remote_access.pulumi_dir` | e.g. `infra/vpn-gateways` | Adapter stack for `wireguard` |
| `vpn.pulumi_dir` | legacy alias | Used if `remote_access.pulumi_dir` omitted |

See [CAPABILITY-PORTS.md](CAPABILITY-PORTS.md). Offline check: `./scripts/validate-inventory.sh`.

## `infra/vpn-gateways` (namespace `vpn`)

WireGuard **RemoteAccess** example adapter (only when `remote_access.provider=wireguard`).

| Key | Required | Default |
|-----|----------|---------|
| `vpn:sshPublicKey` | yes | — |
| `vpn:location` | no | `eastus` |
| `vpn:city` | no | `us` |
| `vpn:vmSize` | no | `Standard_B1s` |
| `vpn:adminCidr` | no | `0.0.0.0/0` | SSH + node_exporter only; WireGuard UDP stays `*` |

```bash
pulumi config set vpn:sshPublicKey "$(cat ~/.ssh/id_ed25519.pub)"
pulumi config set vpn:adminCidr "$(curl -fsSL ifconfig.me)/32"
```

Peer configs are written under `vpn-clients/` (gitignored).

## `infra/flux-bootstrap` (namespace `flux`)

| Key | Required | Default |
|-----|----------|---------|
| `flux:kubeconfig` | yes (**secret**) | — | `pulumi config set --secret flux:kubeconfig "$(cat …)"` |
| `flux:repoUrl` | no | `https://github.com/dakaii/metal-mirage` |
| `flux:branch` | no | `main` |
| `flux:clusterPath` | no | `./gitops/clusters/primary` | Documented next-step path |

After controllers install, run `scripts/install-flux.sh` to create `GitRepository` + root `Kustomization`.

## `control-plane/` (optional Phase 3)

See `.env.example`. No billing keys — Clerk secret + Neon `DATABASE_URL` + VPN endpoint/pubkey only. Keep `.env` gitignored.
