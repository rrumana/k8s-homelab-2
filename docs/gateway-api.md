# Gateway API (HAProxy) in this repo

This repo is moving from **Ingress** resources to **Gateway API** resources for north/south traffic.

## Key resources (what replaces what)

- **IngressClass** (Ingress) ➜ **GatewayClass** (Gateway API)
  - Selects the controller implementation (HAProxy, Envoy, etc).
- **Ingress** ➜ **Gateway** + **HTTPRoute**
  - `Gateway` is the shared L4/L7 entrypoint (listeners on `:80/:443`, TLS termination, where routes are allowed to attach).
  - `HTTPRoute` is per-app/per-host routing that binds to a `Gateway`.

Why this is nicer than Ingress:
- Cleaner separation between **platform-owned entrypoints** (`Gateway`) and **app-owned routing** (`HTTPRoute`).
- Cross-namespace attachment is explicit (`allowedRoutes`) and can be locked down.
- The model extends beyond HTTP (TCP/UDP/TLS routes) when you need it.

## What’s checked into Git

### Shared HAProxy Gateway

- `cluster/platform/ingress/haproxy-gateway/gatewayclass.yaml`
- `cluster/platform/ingress/haproxy-gateway/gateway.yaml`
- `cluster/platform/ingress/haproxy-gateway/httproute-http-to-https-redirect.yaml`

This defines a shared `Gateway` intended to front `*.k8s.rcrumana.xyz`.

### Wildcard TLS via cert-manager (DNS-01)

- `cluster/platform/ingress/haproxy-gateway/certificate-wildcard-k8s-rcrumana-xyz.yaml`

This requests:
- `k8s.rcrumana.xyz`
- `*.k8s.rcrumana.xyz`

via the existing `ClusterIssuer/letsencrypt-prod` (Cloudflare DNS-01).

### Example: ArgoCD route

- `cluster/apps/shared/gateway/routes/argocd.yaml`

Routes `argocd.k8s.rcrumana.xyz` to `Service/argocd-server` and attaches to the shared `Gateway`.

## Notes / prerequisites

- **Gateway API CRDs must exist** in the cluster (`GatewayClass`, `Gateway`, `HTTPRoute`, etc).
- Your HAProxy controller must actually implement Gateway API and use the `GatewayClass.spec.controllerName` you configured.
- For DNS: create a wildcard record in Cloudflare for `*.k8s.rcrumana.xyz` pointing at the Gateway’s `LoadBalancer` IP (and pin that Service to a stable MetalLB IP if desired).
