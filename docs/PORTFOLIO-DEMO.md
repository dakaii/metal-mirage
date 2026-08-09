# Portfolio demo (5–15 min)

Bring the stack up the night before. Do **not** run full `./scripts/up.sh all` live.

## Talk track

1. **Problem** — portable hybrid K8s without Ansible; Azure DR; optional consumer VPN.
2. **Layering** — show `config/clusters.yaml` + `docs/PORTABLE-ARCHITECTURE.md`.
3. **Primary** — `kubectl get nodes` on Talos metal-sim; mention API-only OS.
4. **GitOps** — Flux + `gitops/apps/demo`; standby patches replicas to 0.
5. **Failover** — Traffic Manager priority + witness Function probing `/readyz` (drill: [DR.md](DR.md)).
6. **VPN** — connect WireGuard, `curl ifconfig.me` shows Azure egress; Grafana/Prometheus scrape.
7. **Portable L1** — show `config/clusters.bare-metal.example.yaml` + `./scripts/validate-inventory.sh` (offline); mention `infra/bare-metal` dryRun.
8. **Optional** — Clerk+Neon peer portal in `control-plane/`; sync with `./scripts/vpn-reconcile-peers.sh`.

## Live commands (safe)

```bash
kubectl get nodes
kubectl -n demo get deploy,svc
flux get kustomizations
wg show   # on VPN VM via ssh
```
