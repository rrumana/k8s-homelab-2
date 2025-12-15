# OPNsense Unbound + split-DNS + cert-manager DNS-01

When you use OPNsense **Unbound Host Overrides** like `*.k8s.rcrumana.xyz -> 192.168.1.230`, Unbound effectively becomes **authoritative** for that namespace. That’s great for split-DNS A/AAAA answers, but it often breaks **DNS-01 propagation checks** because Unbound will answer `NXDOMAIN`/`NODATA` for TXT records under that zone instead of recursing to the public DNS (Cloudflare).

## Goal

- Keep local A/AAAA overrides for `k8s.rcrumana.xyz` / `*.k8s.rcrumana.xyz` (split DNS).
- Allow arbitrary `_acme-challenge.<anything>.k8s.rcrumana.xyz` **TXT** lookups to recurse to Cloudflare so cert-manager DNS-01 can validate.

## IPv6 gotcha (why curl/browser still hits Cloudflare)

If the public record is **proxied** in Cloudflare, Cloudflare will answer **AAAA** with Cloudflare IPv6 addresses at the edge even if your zone has only A records. Many clients will try IPv6 first.

So it’s not enough for split DNS to override `A`; you must also handle `AAAA` for internal clients or they’ll connect to Cloudflare.

### Why `do-ip6: no` doesn’t prevent AAAA answers

In Unbound, `do-ip6: no` means “don’t use IPv6 for upstream transport / outgoing queries”. It does **not** mean “never return AAAA records”.

If your local zone config is **typetransparent**, Unbound will still recurse for record types you didn’t override locally (including `AAAA`) and it can fetch those AAAA answers over IPv4 just fine.

Quick checks:

```bash
dig +short AAAA argocd.k8s.rcrumana.xyz @192.168.1.1
```

If you see `2606:4700:....`, internal clients are still learning Cloudflare IPv6.

### If `dig @192.168.1.1` looks right but curl/browser still uses Cloudflare

That almost always means the client is **not actually using Unbound** for name resolution (at least not consistently), e.g.:

- Browser “Secure DNS” / DoH enabled (Chrome/Firefox)
- OS resolver using additional upstream DNS servers (systemd-resolved split DNS)
- IPv6 DNS queries not being redirected to Unbound (separate IPv6 rule needed)

Sanity checks:

```bash
# What does the OS resolver think?
getent ahosts argocd.k8s.rcrumana.xyz

# If you have systemd-resolved:
resolvectl status
resolvectl query argocd.k8s.rcrumana.xyz
```

## Reality check: Unbound wildcard support

OPNsense makes `*.k8s.rcrumana.xyz -> 192.168.1.230` work in the UI by generating Unbound **zone-level** config (effectively a redirect for the whole zone). Plain Unbound `local-data:` entries do **not reliably wildcard-match** arbitrary names (for example, `local-data: "*.k8s.rcrumana.xyz. A …"` will not necessarily answer `A foo.k8s.rcrumana.xyz`).

That means you generally have to choose between:

1. **Wildcard split-DNS for everything** (`*.k8s…` always resolves locally), or
2. **Arbitrary DNS-01 TXT recursion** for `_acme-challenge.<anything>.k8s…`

Trying to do both inside Unbound without per-host exceptions usually ends up with one side “winning”.

## Option A (simple): wildcard A override + wildcard cert only

If you only use the single wildcard certificate (`*.k8s.rcrumana.xyz`), the only TXT name you need for ACME is:

- `_acme-challenge.k8s.rcrumana.xyz`

In that case you can keep the wildcard `*.k8s…` split-DNS override and add a **single** transparent exception for the wildcard challenge:

```conf
server:
  # Make the whole zone authoritative and IPv4-only for clients:
  local-zone: "k8s.rcrumana.xyz." redirect
  local-data: "k8s.rcrumana.xyz. A 192.168.1.230"

  # Let cert-manager DNS-01 propagation checks recurse to Cloudflare:
  local-zone: "_acme-challenge.k8s.rcrumana.xyz." typetransparent
```

This works well when you terminate TLS using a single wildcard secret for all apps.

To avoid IPv6 sending clients to Cloudflare, also add an internal AAAA strategy. Practical options:

- Add an explicit **AAAA override** for `argocd.k8s.rcrumana.xyz` (and other apps) to an internal IPv6 address that actually routes to your ingress (if you have IPv6 on your LAN), or
- Disable IPv6 on clients / prefer IPv4 (for testing, `curl -4 ...`), or
- Disable Cloudflare proxy for internal-only names (grey cloud) so Cloudflare doesn’t hand out edge AAAA.

## Option B (scales for many per-host certs): typetransparent zone + per-host A records

If you want to issue many per-host certs (`argocd.k8s…`, `plex.k8s…`, etc) without adding Unbound exceptions per certificate, drop the `*.k8s…` wildcard override and instead:

1. Make the zone typetransparent (so TXT for `_acme-challenge.*` can recurse)
2. Add only the hosts you actually need as explicit A records

```conf
server:
  local-zone: "k8s.rcrumana.xyz." typetransparent
  local-data: "argocd.k8s.rcrumana.xyz. A 192.168.1.230"
  local-data: "plex.k8s.rcrumana.xyz. A 192.168.1.230"
  # …one per app hostname you expose internally
```

With this pattern, `_acme-challenge.argocd.k8s.rcrumana.xyz` is *not* locally defined, so Unbound will recurse and cert-manager DNS-01 propagation checks succeed without any special-case `_acme-challenge.*` zones.

Note: with a typetransparent parent zone, you must either (a) explicitly override `AAAA` per-host too, or (b) accept that internal clients may learn Cloudflare edge AAAA and try IPv6 first.

## Validate Cloudflare -> origin (526 debugging)

Cloudflare `HTTP 526` means: client → Cloudflare edge TLS is fine, but Cloudflare → **your origin** TLS validation failed.

To debug, first confirm what your origin actually is:

- Check the OPNsense **WAN port-forward** for `80/443` for `*.k8s.rcrumana.xyz` and which LAN IP it targets (old HAProxy vs new `192.168.1.230`).

Then test three paths:

1. **Internal direct to origin (bypass Cloudflare)**
   - From a LAN host: `curl -vkI https://argocd.k8s.rcrumana.xyz/`
   - If AAAA still points to Cloudflare, force IPv4 for this check: `curl -4 -vkI https://argocd.k8s.rcrumana.xyz/`

2. **Direct to WAN IP (bypass Cloudflare, emulate Cloudflare-to-origin)**
   - From any host that can reach your WAN IP:
     - `openssl s_client -connect <WAN_IP>:443 -servername argocd.k8s.rcrumana.xyz -showcerts`

3. **Through Cloudflare (what users see)**
   - `curl -vkI https://argocd.k8s.rcrumana.xyz/` should not return `server: cloudflare` + `526` once origin TLS is correct.
