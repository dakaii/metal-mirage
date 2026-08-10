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
| `primary:vmSize` | no | auto via `up.sh` (else `Standard_B2s`) | Azure metal-sim: `./scripts/up.sh primary` probes quota/SKU; override `PRIMARY_VM_SIZE` |
| `primary:talosVersion` | no | `v1.9.5` | Must match gallery VHD / `register-talos-image`; pins pulumi-talos schema (avoids unknown keys like `grubUseUKICmdline`) |
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

Thin portable L1 provisioner for real hardware (preferred primary). Same output
contract as `infra/primary` (`kubeconfig`, `apiLoadBalancerIP`, `ingressIP`,
`clusterEndpoint`, `provisioner=bare-metal`). See [METAL-PRIMARY.md](METAL-PRIMARY.md)
and [PORTABLE-ARCHITECTURE.md](PORTABLE-ARCHITECTURE.md).

**Inventory SoT:** `config/clusters.yaml` `primary.nodes` (+ optional `dry_run`,
`install_disk`, `api_endpoint_ip`, `ingress_ip`). Prefer
`./scripts/sync-baremetal-config.sh` or `./scripts/up.sh primary` over hand-editing
Pulumi keys.

| Key | Required | Default | Notes |
|-----|----------|---------|-------|
| `baremetal:nodes` | yes | — | JSON array synced from `primary.nodes` |
| `baremetal:apiEndpointIP` | no | first controlplane IP | VIP or CP IP used in `clusterEndpoint` |
| `baremetal:ingressIP` | no | `apiEndpointIP` | Traffic Manager / demo HTTP target |
| `baremetal:clusterName` | no | `metal-mirage-primary` | Talos cluster name |
| `baremetal:installDisk` | no | `/dev/sda` | Often `/dev/nvme0n1` on real metal |
| `baremetal:talosVersion` | no | `v1.9.5` | Pins pulumi-talos schema to match installed nodes |
| `baremetal:dryRun` | no | `true` | `true` = offline: secrets + machine configs only; `false` = apply + bootstrap |

```bash
# Prefer sync from clusters.yaml:
./scripts/sync-baremetal-config.sh
./scripts/up.sh primary
```

Validate inventory without cloud/hardware: `./scripts/validate-inventory.sh`.

Secret outputs: `kubeconfig` (empty in dryRun), `machineConfigs`.
Dump configs for USB/`talosctl`: `./scripts/export-baremetal-machine-configs.sh`
(after `./scripts/up.sh primary`).

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
| `shared:failoverWebhookURL` | no | — | Optional HTTPS webhook; POSTed once at threshold (use `--secret`) — [AUTO-FAILOVER.md](AUTO-FAILOVER.md) |
| `shared:failoverWebhookHMACSecret` | no | — | Optional HMAC for `X-Metal-Mirage-Signature` (`--secret`) |
| `shared:failoverGitHubRepo` | no | — | Optional `owner/repo` for `repository_dispatch` |
| `shared:failoverGitHubToken` | no | — | Optional GitHub token for dispatch (`--secret`); fine-grained PAT on that repo with **Contents: Read and write** (see [AUTO-FAILOVER.md](AUTO-FAILOVER.md)) |
| `shared:location` | no | `eastus` | |

Witness consecutive-failure state is stored in a private blob container (`witness-state`) on the Function storage account — not `/tmp` — so Consumption (Y1) cold starts keep the counter. After changing witness code or failover notify settings, re-run `./scripts/deploy-witness.sh` (and `pulumi up` shared for app settings).

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
| `remote_access.provider` | `none` (default) \| `wireguard` | `none` skips `./scripts/up.sh vpn` |
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
