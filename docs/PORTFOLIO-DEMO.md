# Portfolio demo (5–15 min)

Bring the stack up the night before. Do **not** run full `./scripts/up.sh all` live.

## Talk track

1. **Problem** — portable hybrid K8s without Ansible; Azure DR; optional consumer VPN.
2. **Layering** — show `config/clusters.yaml` + `docs/PORTABLE-ARCHITECTURE.md`.
3. **Primary** — `kubectl get nodes` on Talos metal-sim; mention API-only OS.
4. **GitOps** — Flux + `gitops/apps/demo`; standby patches replicas to 0.
5. **Failover** — Traffic Manager priority + witness Function probing `/readyz`.
6. **VPN** — connect WireGuard, `curl ifconfig.me` shows Azure egress; Grafana/Prometheus scrape.
7. **Next** — real bare metal provisioner; Clerk+Neon peer portal in `control-plane/`.

## Live commands (safe)

```bash
kubectl get nodes
kubectl -n demo get deploy,svc,ingress
flux get kustomizations
wg show   # on VPN VM via ssh
```
