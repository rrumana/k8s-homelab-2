# Ingress + DNS Troubleshooting Bundle (OPNsense + Cloudflare)

If you want someone else to diagnose split-DNS + Cloudflare ingress issues, these are the most useful artifacts to share.

## 1) OPNsense export (preferred)

- `System -> Configuration -> Backups -> Download configuration`
  - Export `config.xml`

Before sharing, redact secrets (search/replace is fine):

- API tokens/keys (`cloudflare`, `token`, `apikey`)
- Private keys and cert PEM blobs
- User passwords (local users, VPN users, etc.)

If you don’t want to share the whole `config.xml`, at minimum share screenshots (or copy/paste) of:

- `Services -> Unbound DNS -> Overrides` (Host + Domain overrides for `k8s.rcrumana.xyz`)
- `Services -> Unbound DNS -> General` (any “custom options” block)
- `Firewall -> NAT -> Port Forward` rules for `80` and `443`
- `Firewall -> Rules -> WAN` entries created by those NAT rules (or any allow/deny rules for 80/443)

## 2) Cloudflare export (minimum required)

- `DNS -> Export zone file` (or paste the relevant records)
  - `k8s.rcrumana.xyz` and any `*.k8s.rcrumana.xyz`/app hostnames
  - Whether the record is proxied (orange cloud) or DNS-only (grey)
- `SSL/TLS` settings screenshot:
  - Encryption mode (Flexible / Full / Full (strict))
  - Any “Origin Server” settings you’ve changed

## 3) Quick command outputs (high signal)

Run these from:

- a LAN client using Unbound
- an off-LAN client (cell hotspot is fine) to test public reachability

```bash
# Internal resolution should return the HAProxy/MetalLB IP
dig +short A argocd.k8s.rcrumana.xyz @<OPNSENSE_LAN_IP>
dig +short AAAA argocd.k8s.rcrumana.xyz @<OPNSENSE_LAN_IP>

# Confirm what the public authoritative answer is (should be WAN IP, not 192.168.x.x)
dig +short A argocd.k8s.rcrumana.xyz @1.1.1.1

# Direct origin check (LAN)
curl -vkI https://argocd.k8s.rcrumana.xyz/

# Bypass DNS and test SNI/Host routing to the LB IP (LAN)
curl -vkI https://192.168.1.230/ -H 'Host: argocd.k8s.rcrumana.xyz'

# Off-LAN: validate port-forward and origin TLS selection (use your WAN IP)
openssl s_client -connect <WAN_IP>:443 -servername argocd.k8s.rcrumana.xyz -showcerts </dev/null
```

