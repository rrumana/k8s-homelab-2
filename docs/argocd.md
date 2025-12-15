# Argo CD notes

## Initial admin password recovery

Argo CD normally stores the one-time initial admin password in `Secret/argocd-initial-admin-secret`:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo
```

If that Secret is missing (or empty), the original initial password is not recoverable; reset it instead.

## Reset the admin password (if needed)

If you have the `argocd` CLI:

```bash
argocd admin initial-password -n argocd
```

Or reset the password by updating `Secret/argocd-secret` with a bcrypt hash:

```bash
NEW_PASSWORD='replace-me'
BCRYPT_HASH="$(htpasswd -bnBC 10 "" "${NEW_PASSWORD}" | tr -d ':\n')"

kubectl -n argocd patch secret argocd-secret -p "{
  \"stringData\": {
    \"admin.password\": \"${BCRYPT_HASH}\",
    \"admin.passwordMtime\": \"$(date -u +%FT%TZ)\"
  }
}"
```

Then restart the server:

```bash
kubectl -n argocd rollout restart deploy/argocd-server
```
