# Pulumi / control-plane config keys

Copy patterns below into a stack (`pulumi config set …`). Never commit real `Pulumi.*.yaml` secrets (gitignored).

## `infra/primary` (namespace `primary`)

| Key | Required | Default | Notes |
|-----|----------|---------|-------|
| `primary:talosImageId` | yes | — | Gallery image resource ID from `register-talos-image.sh` |
| `primary:location` | no | `eastus` | Azure region |
| `primary:clusterName` | no | `metal-mirage-primary` | Talos cluster name |
| `primary:controlPlaneCount` | no | `1` | Demo-friendly |
| `primary:workerCount` | no | `1` | |
| `primary:vmSize` | no | `Standard_B2s` | |
| `azure-native:location` | recommended | | Also set for the provider |

Example:

```bash
cd infra/primary
pulumi stack init dev
pulumi config set azure-native:location eastus
pulumi config set primary:talosImageId '/subscriptions/<sub>/resourceGroups/talos-images/providers/Microsoft.Compute/galleries/talosgallery/images/talos/versions/1.9.5'
pulumi config set primary:controlPlaneCount 1
pulumi config set primary:workerCount 1
```

## `infra/standby-aks` (namespace `standby`)

| Key | Required | Default |
|-----|----------|---------|
| `standby:location` | no | `eastus` |
| `standby:nodeCount` | no | `1` |
| `standby:vmSize` | no | `Standard_B2s` |
| `standby:kubernetesVersion` | no | (AKS default) |

## `infra/shared` (namespace `shared`)

| Key | Required | Default | Notes |
|-----|----------|---------|-------|
| `shared:primaryIngressIP` | yes | — | Primary **ingress** public IP (not the API PIP) |
| `shared:primaryAPIURL` | if witness enabled | — | e.g. `https://<api-ip>:6443/readyz` |
| `shared:standbyFQDN` | no | — | AKS FQDN for priority-2 endpoint |
| `shared:appDomain` | no | — | Custom domain hint export only |
| `shared:enableWitness` | no | `true` | Set `false` to skip Function App |
| `shared:location` | no | `eastus` | |

`./scripts/up.sh all` wires ingress IP / API URL / standby FQDN from stack outputs when present.

## `infra/vpn-gateways` (namespace `vpn`)

| Key | Required | Default |
|-----|----------|---------|
| `vpn:sshPublicKey` | yes | — |
| `vpn:location` | no | `eastus` |
| `vpn:city` | no | `us` |
| `vpn:vmSize` | no | `Standard_B1s` |
| `vpn:adminCidr` | no | `0.0.0.0/0` (lock down in real use) |

## `infra/flux-bootstrap` (namespace `flux`)

| Key | Required | Default |
|-----|----------|---------|
| `flux:kubeconfig` | yes (secret) | — |
| `flux:repoUrl` | no | `https://github.com/dakaii/metal-mirage` |
| `flux:branch` | no | `main` |
| `flux:clusterPath` | no | `./gitops/clusters/primary` |

After controllers install, run `scripts/install-flux.sh` to create `GitRepository` + root `Kustomization`.

## `control-plane/` (optional Phase 3)

See `.env.example`. No billing keys — Clerk secret + Neon `DATABASE_URL` + VPN endpoint/pubkey only.
