# DR drill runbook (Traffic Manager + witness)

Operator runbook for portfolio failover. Nothing here is instant L4 cutover — Traffic Manager follows **DNS TTL**, and the witness Function is an **advisory signal** until you act.

## Two health planes (do not confuse)

| Plane | What it probes | Path | Actor |
|-------|----------------|------|--------|
| **User / DNS** | Demo HTTP | `:80` `/healthz` → primary LB → NodePort `30080` (or standby Service) | Azure Traffic Manager |
| **Witness** | Kubernetes API readiness | `https://<apiLoadBalancerIP>:6443/readyz` (TLS verify off) | Consumption Function, every **1 min**, threshold **3** |

TM does **not** use `/readyz`. Witness does **not** flip TM endpoints or scale standby for you.

## Preconditions

```bash
./scripts/up.sh primary
./scripts/up.sh standby
./scripts/up.sh shared          # wires primaryIngressIP + primaryAPIURL + standbyFQDN
./scripts/deploy-witness.sh     # re-run after every shared pulumi up
# Flux on both clusters (standby demo stays replicas: 0 by default)
export KUBECONFIG=$PWD/.secrets/primary.kubeconfig
./scripts/install-flux.sh primary
# standby kubeconfig from: pulumi -C infra/standby-aks stack output kubeconfig --show-secrets
./scripts/install-flux.sh standby
```

Useful outputs:

```bash
pulumi -C infra/shared stack output trafficManagerFQDN
pulumi -C infra/shared stack output primaryAPIURL
pulumi -C infra/shared stack output witnessFunctionName
pulumi -C infra/primary stack output ingressIP
curl -fsS "http://$(pulumi -C infra/primary stack output ingressIP)/healthz"
```

Optional backups: [VELERO.md](VELERO.md).

## Cold standby catch

`gitops/clusters/standby/flux.yaml` patches the demo Deployment to **`replicas: 0`**. With that in place, TM’s priority-2 probe often fails too — so DNS will not usefully fail over until standby `/healthz` is green.

For a drill, either:

1. Temporarily edit the standby Flux patch (replicas `0` → `N`) and let Flux reconcile, or
2. `kubectl --kubeconfig .secrets/standby.kubeconfig -n demo scale deploy/demo --replicas=2` knowing Flux may revert until the patch changes.

## Drill A — Traffic Manager (app `/healthz`)

1. Baseline:
   ```bash
   FQDN="$(pulumi -C infra/shared stack output trafficManagerFQDN)"
   dig +short "$FQDN"
   curl -fsS "http://${FQDN}/healthz"
   ```
2. Make standby healthy (see cold standby catch).
3. Break primary app health (scale demo to 0, block NSG on `:80`, or stop backends serving NodePort `30080`).
4. Wait: TM interval **30s** × tolerated failures **3** (≈90s+) **plus** profile TTL **30s** and resolver cache.
5. Confirm Azure TM endpoint status and that `dig` / `curl` via `$FQDN` hit standby.
6. Recover primary; wait priority 1 to win again; return standby to replicas 0 / restore the Flux patch.

## Drill B — Witness `FAILOVER_CANDIDATE` (API `/readyz`)

1. Confirm `pulumi -C infra/shared stack output primaryAPIURL` is `https://…:6443/readyz`.
2. Stream Function logs (Azure portal Log stream, or `az webapp log tail` against the Function App / shared RG).
3. Break API reachability (stop control-plane nodes, NSG-deny `:6443`, or wrong URL).
4. After **≥3** consecutive minute failures, expect log line `FAILOVER_CANDIDATE`.
5. Optional: inspect blob container `witness-state` / blob `failures.txt` (ETag-backed counter).
6. Optional outbound hook: set `shared:failoverWebhookURL` (secret) so the Function POSTs JSON once when the threshold is crossed (`event=FAILOVER_CANDIDATE`). Still does **not** flip Traffic Manager or scale standby for you.
7. **Manual** operator actions (unless your webhook does them):
   - Scale standby demo (GitOps or kubectl)
   - Optional Velero restore ([VELERO.md](VELERO.md))
   - Optionally disable / deprioritize the primary TM endpoint in Azure if the app is half-dead but still answering `/healthz`
8. Restore primary API — witness should reset the counter and log `primary healthy`.

## Drill C — Portfolio talk track

1. Healthy: TM → primary ingress; witness healthy; standby cold (`replicas: 0`).
2. Warm standby (demo `/healthz` green).
3. Break primary `/healthz`; wait DNS/TM; curl `$FQDN` serves standby.
4. Optionally break `:6443` to show witness `FAILOVER_CANDIDATE` as an **out-of-band** signal (not the TM trigger).
5. Failback; destroy when idle (`./scripts/destroy.sh` — see [BEST-PRACTICES.md](BEST-PRACTICES.md)).

## Honesty

- TM failover is **DNS-TTL**, not L4.
- Witness is advisory by default (logs `FAILOVER_CANDIDATE`). Optional `failoverWebhookURL` POSTs once at threshold crossing — you still own TM/standby actions.
- Leaving `:6443` open for Function egress is intentional when witness is enabled ([BEST-PRACTICES.md](BEST-PRACTICES.md)).
- **VPN city exits are out of this path** — no peer failover in V1 ([VPN.md](VPN.md)). Peer DB→VM sync is `./scripts/vpn-reconcile-peers.sh`, not TM.

## Related

| Doc / script | Role |
|--------------|------|
| [ARCHITECTURE.md](ARCHITECTURE.md) | Failover section |
| [DEPLOY.md](DEPLOY.md) | Bring-up order |
| [VELERO.md](VELERO.md) | Restore on standby |
| `./scripts/deploy-witness.sh` | Zip deploy for the Function |
| `./scripts/up.sh shared` | Wires TM + witness config from stack outputs |
