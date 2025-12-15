# Gateway API (HAProxy) in this repo

This repo explores **Gateway API** resources for north/south traffic, but HAProxy support is currently limited.

For HAProxy Technologies `kubernetes-ingress`, Gateway API support is currently **TCPRoute-only** (no `HTTPRoute`), so HTTP/HTTPS host-based routing is still done with **Ingress** resources.

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

### Wildcard TLS via cert-manager (DNS-01)

- `cluster/platform/base/networking/cert-manager/certificates/wildcard-k8s-rcrumana-xyz.yaml`

This requests:
- `k8s.rcrumana.xyz`
- `*.k8s.rcrumana.xyz`

via the existing `ClusterIssuer/letsencrypt-prod` (Cloudflare DNS-01).

### Example: ArgoCD exposure (Ingress)

- `cluster/apps/shared/ingress/argocd.yaml`

## Notes / prerequisites

- **Gateway API CRDs must exist** in the cluster (`GatewayClass`, `Gateway`, `HTTPRoute`, etc).
- For DNS: create a wildcard record in Cloudflare for `*.k8s.rcrumana.xyz` pointing at the HAProxy `LoadBalancer` IP (and pin that Service to a stable MetalLB IP if desired).
