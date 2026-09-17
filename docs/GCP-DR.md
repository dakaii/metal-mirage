# GCP standby / DR lab path

metal-mirage’s shipped DR lab is **Azure** (AKS + Traffic Manager + witness).
This document is the **GCP parallel**: GKE Autopilot standby + Cloud DNS failover
notes. Prefer it when you want **project-per-lab teardown** or a GCP-shop client.

| Azure (shipped) | GCP (this path) |
|-----------------|-----------------|
| `infra/standby-aks` | `infra/standby-gke` |
| Traffic Manager profile | Cloud DNS **failover** routing policy + health checks |
| Azure Function witness | Same idea later (Cloud Function / Run) — **not in OSS yet** |
| Dedicated Azure subscription pin | Dedicated **GCP project** pin (`gcp.project_id`) |

## Scope (honest)

| In this PR / path | Not yet |
|-------------------|---------|
| GKE Autopilot standby via Pulumi (`infra/standby-gke`) | Full `infra/shared-gcp` Cloud DNS stack |
| `standby.provisioner: gke` + `gcp.project_id` guard in scripts | Witness Function on GCP |
| Operator docs + example `clusters.yaml` | Auto-promote inside Google |

DNS failover is documented below as **gcloud** steps until a Pulumi shared adapter exists.

## 1. Pin a dedicated GCP project

```yaml
# config/clusters.yaml
gcp:
  project_id: metal-mirage-lab   # create a project used ONLY for this lab

standby:
  provisioner: gke
  pulumi_dir: infra/standby-gke
  profile: standby

primary:
  provisioner: bare-metal   # or azure-metal-sim — L1 stays portable
  # …
```

```bash
gcloud config set project metal-mirage-lab
gcloud auth application-default login   # for Pulumi GCP provider
```

Scripts call `require_gcp_project` on GKE standby up/destroy (same idea as
`azure.subscription_id`). Escape: `ALLOW_UNPINNED_GCP_PROJECT=1` /
`SKIP_GCP_PROJECT_CHECK=1`.

## 2. Bring up GKE standby

```bash
cd infra/standby-gke
pulumi stack init dev   # or select
pulumi config set gcp:project metal-mirage-lab
pulumi config set gcp:region us-central1
pulumi config set standby:location us-central1
cd ../..
./scripts/up.sh standby
# exports kubeconfig → .secrets/standby.kubeconfig (via up.sh Flux path)
```

Install Flux against standby the same way as AKS (`./scripts/up.sh standby` /
`flux`). Demo Service should expose a **public** IP for DNS health checks
(LoadBalancer) — use the standby Flux overlay / `demo-loadbalancer` pattern.

## 3. Cloud DNS failover (manual until shared-gcp)

Map of Azure Traffic Manager → Cloud DNS:

1. Health-check **primary** public `/healthz` (metal or metal-sim ingress).
2. Health-check **standby** GKE demo LoadBalancer `/healthz`.
3. Public zone + **A record** with routing policy type **FAILOVER** (primary →
   backup when unhealthy). Keep TTL short for drills (e.g. 30–60s).

Codelab-shaped reference: [Cloud DNS external failover](https://codelabs.developers.google.com/cloudnet-clouddns-external-failover-policy-codelab).

Example sketch (adjust names/IPs):

```bash
# Global HTTP health check used by Cloud DNS (public endpoints only)
gcloud compute health-checks create http metal-mirage-dns-hc \
  --global \
  --port=80 \
  --request-path=/healthz \
  --check-interval=30s

# After zone exists — failover A record (API surface evolves; prefer current gcloud help)
# Primary = metal ingress IP; backup = GKE demo LB IP
```

Promote/failback drills stay **operator-driven** (scale standby demo, shorten TTL),
same honesty as [DR.md](DR.md) / [AUTO-FAILOVER.md](AUTO-FAILOVER.md).

## 4. Tear down

```bash
./scripts/destroy.sh standby
# Then delete leftover project resources or the whole GCP project if it was lab-only.
```

Project delete is the GCP analogue of “nuke the sandbox” — which is why a
**dedicated** `metal-mirage-lab` project matters (do not reuse ZeroClaw/Banjar).

## Mac Mini + GCP?

| Piece | Role |
|-------|------|
| Mac Mini QEMU Talos lab | Local primary **experiment** — [MACOS-TALOS-LAB.md](MACOS-TALOS-LAB.md) |
| GKE standby | Cloud DR |
| Cloud DNS failover | Cutover when Mini/lab primary `/healthz` fails |

That combo is a **portfolio demo**, not a client HA design. Prefer x86 NUC/Talos
metal for real primary + GKE/AKS standby.

## Related

- [COST.md](COST.md) — Azure sub pin; teardown honesty
- [DR.md](DR.md) — Azure TM drill
- [PORTABLE-ARCHITECTURE.md](PORTABLE-ARCHITECTURE.md) — L1 contract
- [CAPABILITY-PORTS.md](CAPABILITY-PORTS.md) — Compute adapters
