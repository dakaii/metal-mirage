# Optional MetalLB (bare-metal ingress VIP)

Not applied by default. Use when `primary.provisioner=bare-metal` and you want a
stable LAN VIP for HTTP instead of curling a node IP `:30080`.

## Steps

1. Set `primary.ingress_ip` in `config/clusters.yaml` to a **free** address on your LAN.
2. Edit `ipaddresspool.yaml` so the pool matches that IP (or a small range).
3. Install MetalLB **CRDs/controllers** (Helm or upstream manifests) so namespace
   `metallb-system` exists — this overlay only ships pool/advertisement samples.
4. `kubectl apply -k gitops/infrastructure/metallb`
5. `kubectl apply -k gitops/apps/demo-loadbalancer` (Service → `LoadBalancer`;
   default Flux `demo/` stays NodePort `30080`).

Do **not** add this path (or `demo-loadbalancer`) to the default Flux
kustomizations until controllers/CRDs are installed, or reconcile will stuck-fail.

Until the Service is `LoadBalancer`, the demo remains NodePort `30080` (metal or Azure lab).
