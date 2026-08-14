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

Downloads `azure-amd64.vhd.xz` from [Talos Image Factory](https://factory.talos.dev)
(GitHub Releases no longer ship Azure VHDs). Override schematic with
`TALOS_SCHEMATIC_ID` or full URL with `TALOS_IMAGE_URL`.

Prefer `--in-azure` on a laptop: a short-lived helper VM downloads/decompresses/uploads
the VHD (no multi-GB copy under `.secrets/`). Default mode still downloads locally.
If a SKU hits `SkuNotAvailable` or `QuotaExceeded` (common on new subs with 0 cores
for a VM family), the script tries several sizes. Override with `TALOS_HELPER_VM_SIZE`
/ `TALOS_HELPER_VM_SIZES`, raise quota in the portal, or use local mode (no helper VM).

```bash
# optional: export PULUMI_CONFIG_PASSPHRASE=…  # avoid retyping the stack passphrase
./scripts/register-talos-image.sh --in-azure eastus
# One-shot: clusters.yaml + Pulumi config + up (discovers gallery image if omitted)
./scripts/init-azure-metal-sim.sh --write-clusters --up
# Already on azure-metal-sim clusters.yaml? omit --write-clusters, or use --force-clusters to replace.
```

Manual equivalent (if you prefer): set `primary:talosImageId`, `adminCidr`, counts under
`infra/primary` — see [CONFIG.md](CONFIG.md).

`./scripts/up.sh primary` **auto-selects** `primary:vmSize` from Azure quota/SKU
(skips the old `Standard_B2s` default when that family has no capacity). Override with
`PRIMARY_VM_SIZE=…`, re-probe with `FORCE_AZURE_VM_SIZE_AUTO=1`, or skip via
`SKIP_AZURE_VM_SIZE_AUTO=1`. Probe alone: `./scripts/pick-azure-vm-size.sh eastus 4`.

Machine config is pinned with `primary:talosVersion` (default `v1.9.5`, must match the
gallery VHD). Azure forbids changing VM `customData` in place; after first create,
config updates go through Talos `ConfigurationApply` (Pulumi ignores `osProfile.customData`
drift). To rewrite first-boot customData, replace the VMs explicitly.

`./scripts/up.sh primary` sets `primary:adminCidr` for azure-metal-sim. The lab
default is **`0.0.0.0/0`**: residential CGNAT often jumps across `/24`s mid-Bootstrap
(e.g. `187.15.98.0/24` → `187.15.91.0/24`), which looks like
`dial tcp …:50000: i/o timeout` even after a “successful” `ConfigurationApply`.
Tighten with `ADMIN_CIDR=…` or `ADMIN_CIDR_PREFIX_LEN=24|32`, or skip via
`SKIP_ADMIN_CIDR_AUTO=1`. Before `pulumi up`, `up.sh` **warns** if `<api>:50000`
is unreachable (skip with `SKIP_TALOS_APID_PREFLIGHT=1`); it does not hard-fail,
because the NSG update is part of the same `up`.
Quick probe: `nc -vz <apiLoadBalancerIP> 6443` (open to `*`) vs `:50000`
(`adminCidr` only) — if 6443 works and 50000 hangs, widen the CIDR.
If preview wants `talos-secrets` **replace** on a half-bootstrapped cluster, stop:
Secrets replace + `IgnoreChanges(customData)` leaves stale first-boot identity —
`--replace` the VMs or destroy/recreate primary.

## 2. Primary (metal-sim)

```bash
./scripts/up.sh primary   # cluster + kubeconfig export + Flux (skip Flux: SKIP_FLUX=1)
export KUBECONFIG=$PWD/.secrets/primary.kubeconfig
kubectl get nodes
# After Flux reconciles the demo app:
curl -fsS "http://$(pulumi -C infra/primary stack output ingressIP)/healthz"
# Re-run GitOps only: ./scripts/up.sh flux          # or: ./scripts/up.sh flux standby
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
./scripts/export-baremetal-machine-configs.sh   # optional USB / talosctl files
```

Live apply: install Talos to maintenance mode (checklist in [METAL-PRIMARY.md](METAL-PRIMARY.md)),
set `dry_run: false` in `clusters.yaml`, re-run `up.sh primary`. Ingress options
(NodePort / MetalLB + `gitops/apps/demo-loadbalancer` / BYO): see METAL-PRIMARY.

Azure metal-sim lab: copy `config/clusters.azure-metal-sim.example.yaml` over
`config/clusters.yaml`, then follow §2 above.

## 3. Flux GitOps

`./scripts/up.sh primary` (and `standby` / `all`) already:
1. Writes `.secrets/<cluster>.kubeconfig`
2. Runs `infra/flux-bootstrap` (Flux Helm controllers)
3. Runs `scripts/install-flux.sh` (GitRepository + root Kustomization)

Needs the `flux` CLI on your PATH. Override repo with `GITOPS_REPO_URL=…`;
skip with `SKIP_FLUX=1`. Re-bootstrap without touching the cluster:

```bash
./scripts/up.sh flux              # primary
./scripts/up.sh flux standby      # separate Pulumi stack: ${PULUMI_STACK}-standby
```

Requires the `flux` CLI (`brew install fluxcd/tap/flux`). Controllers still
come from the Helm chart in `infra/flux-bootstrap`; `install-flux.sh` only
adds the GitRepository + root Kustomization.

## 4. Standby AKS + shared failover

```bash
./scripts/up.sh standby   # probes AKS-capable vmSize; SKIP_FLUX=1 if you only want AKS
./scripts/up.sh shared    # Traffic Manager + optional witness; wires outputs automatically
./scripts/deploy-witness.sh
```

A failed mid-`up` (bad SKU / role GUID) leaves a partial resource group — just
re-run `./scripts/up.sh standby` after fixing config; no destroy needed unless
Pulumi state is wedged. Override node SKU with `STANDBY_VM_SIZE=…`.

**Shared / witness troubleshooting**

- `MismatchingResourceName` on Traffic Manager — fixed when `ProfileName`/`EndpointName`
  match the stable Azure names (`metal-mirage-app` / `primary` / `standby`). A failed
  create usually left **no** profile (API rejected the body); plain re-run
  `./scripts/up.sh shared` is enough. If Portal shows a stray `metal-mirage-app`
  profile in the shared RG, delete it once, then re-`up`.
- `Cannot mix External Endpoints … IPv4Address, DomainName` — primary is an IP; do **not**
  point standby at `aksFqdn`. Unset legacy config and use the demo LB IP:
  `pulumi -C infra/shared config rm shared:standbyFQDN`
  Standby Flux patches demo Service to `LoadBalancer` **after this lands on the
  GitRepository branch Flux tracks** (usually `main` post-merge). Until sync:
  `kubectl --kubeconfig .secrets/standby.kubeconfig -n demo patch svc demo -p '{"spec":{"type":"LoadBalancer"}}'`.
  After EXTERNAL-IP appears: `./scripts/up.sh shared` (or `config set shared:standbyIngressIP <ip>`).
  Primary-only TM (no standby endpoint) is fine until that IP exists.
- `RelativeName` / DNS label `metal-mirage-app` must be **globally unique** on
  `*.trafficmanager.net`. If Azure reports a DNS/name collision, pick another
  relative name (code constant `tmProfileName` in `infra/shared/main.go`) or reclaim
  the label in the other subscription that holds it.
- Witness `Unauthorized` / **Total VMs: 0** — Microsoft.Web regional quota (not Compute
  vCPU). Options:
  1. Portal → Subscription → Usage + quotas → Provider **Microsoft.Web** → request
     Total VMs ≥ 1 in the region, or
  2. `pulumi -C infra/shared config set shared:witnessLocation westus2` (try another
     region), then `./scripts/up.sh shared`. Preview will **replace** an existing
     eastus `witnesssa` / plan / Function (same Pulumi resources, new region) —
     expected; then re-run `./scripts/deploy-witness.sh`, or
  3. TM-only: `pulumi -C infra/shared config set shared:enableWitness false` then
     `./scripts/up.sh shared` (skip Function; skip `deploy-witness.sh`).

After any later `./scripts/up.sh shared` (or `pulumi up` in `infra/shared`), re-run `./scripts/deploy-witness.sh` so the Function zip picks up dependency/code changes (for example `azure-storage-blob` and the durable failure counter). Pulumi alone does not redeploy the zip. The deploy script remote-builds dependencies, sets `EnableWorkerIndexing` via `az` (enough to unblock an existing app), and checks `https://<witnessDefaultHost>/api/health`. Prefer `./scripts/up.sh shared` as well so Pulumi state matches those app settings. Linux Y1 `az webapp log tail` often 404s — use Portal → Functions → Monitor.

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
