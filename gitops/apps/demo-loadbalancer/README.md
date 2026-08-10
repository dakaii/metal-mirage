# Demo + LoadBalancer Service

Same demo app as `gitops/apps/demo`, but Service `type: LoadBalancer` for MetalLB
(or another LB) on VIP `:80`.

```bash
# After MetalLB controllers + pool exist:
kubectl apply -k gitops/apps/demo-loadbalancer
curl -fsS "http://<ingress_ip>/healthz"
```

Do not point the default Flux `apps` kustomization here until an LB
implementation exists — otherwise the Service stays `<pending>`.
