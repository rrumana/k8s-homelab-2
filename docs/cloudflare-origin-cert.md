# Cloudflare Origin Certificate with in-cluster HAProxy

Cloudflare Origin Certificates are trusted by **Cloudflare**, not by browsers. They are useful when you want Cloudflare proxy in front and you do not care about clients connecting directly to your origin.

If you intend to bypass Cloudflare on your LAN via split DNS (`argocd.k8s.rcrumana.xyz -> 192.168.1.230`), do **not** serve a Cloudflare Origin Cert to internal clients (they will see certificate errors). In that case, prefer a publicly trusted cert at the origin (your cert-manager wildcard) and set Cloudflare SSL mode to **Full (strict)**.

## Understand the error codes (523 vs 525/526)

- `523 Origin is unreachable`: Cloudflare cannot connect to your origin IP/port at all (wrong DNS target, missing/incorrect port forward, firewall block, origin not listening).
- `525 SSL handshake failed` / `526 Invalid SSL certificate`: Cloudflare can reach your origin, but TLS validation/handshake fails (certificate/chain/SNI/SSL mode mismatch).

## Port-forward prerequisite (why 526 happens)

Cloudflare connects to your origin on `:443` (and optionally `:80` for redirects). If your firewall forwards `WAN:443` somewhere other than the Kubernetes `LoadBalancer` IP, Cloudflare will be validating the wrong origin.

For the in-cluster HAProxy `LoadBalancer` at `192.168.1.230`, your WAN port forward must be:

- `WAN 80 -> 192.168.1.230:80`
- `WAN 443 -> 192.168.1.230:443`

Forwarding to `8080/8443` will not work when `192.168.1.230` is a Kubernetes `Service` IP; the Service exposes `80/443`.

If your Cloudflare DNS record points to an RFC1918 address (like `192.168.1.230`) and is **proxied** (orange cloud), Cloudflare cannot reach it and you will get `523`.

## Create the Secret

Assuming you have:

- `cloudflare-origin.crt` (PEM cert for `*.k8s.rcrumana.xyz` or the exact hostname)
- `cloudflare-origin.key` (PEM private key)

Create a standard Kubernetes TLS secret:

```bash
kubectl -n ingress-haproxy create secret tls cloudflare-origin-default-cert \
  --cert=cloudflare-origin.crt \
  --key=cloudflare-origin.key
```

Verify:

```bash
kubectl -n ingress-haproxy get secret cloudflare-origin-default-cert -o yaml
```

## Configure HAProxy Ingress to use it

Only do this if you **do not** plan to have LAN clients connect directly to the origin (or you accept certificate errors on LAN when split-DNS bypasses Cloudflare).

The HAProxyTech controller uses `controller.defaultTLSSecret` and `controller.config.default-ssl-certificate` in `cluster/platform/ingress/haproxy/values.yaml`:

- Set `controller.defaultTLSSecret.secret: cloudflare-origin-default-cert` (namespace stays `ingress-haproxy`)
- Set `controller.config.default-ssl-certificate: ingress-haproxy/cloudflare-origin-default-cert`

Then sync the `haproxy` Argo application.

## Validate end-to-end

From a host that can reach your WAN IP directly:

```bash
openssl s_client -connect <WAN_IP>:443 -servername argocd.k8s.rcrumana.xyz -showcerts
```

In Cloudflare dashboard, set:

- `SSL/TLS encryption mode: Full (strict)`
