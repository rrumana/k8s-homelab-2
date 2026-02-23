# Vault Operations Runbook

This is the canonical operational guide for Vault in this cluster.

## Why Vault Exists

Vault exists to solve a specific problem: avoiding an in-repo secrets folder full of sensitive values.

Without Vault, secrets usually end up in one of these bad places:

- Plaintext in Git
- Encrypted blobs that still need key handling in Git
- Hand-created Kubernetes Secrets with poor rotation discipline

With this setup:

- Vault is the source of truth for runtime secrets
- External Secrets Operator (ESO) syncs Vault values into Kubernetes Secrets
- Apps consume Kubernetes Secrets, but secret authority stays centralized

## Cluster Context

- Namespace: `security`
- Vault pods: `vault-0`, `vault-1`, `vault-2`
- Storage: Raft integrated storage on Ceph-backed PVCs
- ESO store: `ClusterSecretStore/vault`
- Vault path model used by ESO: KV v2 under `kv/`

## Preconditions

```bash
kubectl get nodes
kubectl -n security get pods -l app.kubernetes.io/name=vault -o wide
jq --version
openssl version
```

Expected:

- All three Vault pods are running
- You have `~/vault-init.json` from original `vault operator init`

## Sanity Checks

### 1) Check pod and seal state

```bash
kubectl -n security get pods -o wide

for p in vault-0 vault-1 vault-2; do
  echo "=== $p ==="
  kubectl -n security exec "$p" -- vault status
  echo
done
```

Expected:

- `Initialized: true`
- `Sealed: false`
- One active leader, remaining followers/standby

### 2) Check Raft membership

```bash
ROOT_TOKEN=$(jq -r '.root_token' ~/vault-init.json)
kubectl -n security exec vault-0 -- sh -ec "vault login '$ROOT_TOKEN' >/dev/null && vault operator raft list-peers"
unset ROOT_TOKEN
```

### 3) Check ESO can talk to Vault

```bash
kubectl get clustersecretstore vault -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.message}{"\n"}{end}'
kubectl -n security get pods -l app.kubernetes.io/name=external-secrets
```

## Unseal And Recovery Procedure

Run after full-cluster restart or any event where Vault becomes sealed.

```bash
# 0) Preconditions:
# - ~/vault-init.json exists from a successful `vault operator init`
# - vault-0/1/2 pods are running in namespace security

# 1) Load keys + root token from init file
KEY1=$(jq -r '.unseal_keys_b64[0]' ~/vault-init.json)
KEY2=$(jq -r '.unseal_keys_b64[1]' ~/vault-init.json)
ROOT_TOKEN=$(jq -r '.root_token' ~/vault-init.json)

# 2) Unseal vault-0 (active/bootstrap node)
kubectl -n security exec vault-0 -- vault operator unseal "$KEY1"
kubectl -n security exec vault-0 -- vault operator unseal "$KEY2"

# 3) Join followers to raft (safe to run every time; may say already joined)
kubectl -n security exec vault-1 -- vault operator raft join http://vault-0.vault-internal:8200 || true
kubectl -n security exec vault-2 -- vault operator raft join http://vault-0.vault-internal:8200 || true

# 4) Unseal followers
kubectl -n security exec vault-1 -- vault operator unseal "$KEY1"
kubectl -n security exec vault-1 -- vault operator unseal "$KEY2"
kubectl -n security exec vault-2 -- vault operator unseal "$KEY1"
kubectl -n security exec vault-2 -- vault operator unseal "$KEY2"

# 5) Verify all nodes are unsealed
for p in vault-0 vault-1 vault-2; do
  echo "=== $p ==="
  kubectl -n security exec "$p" -- vault status
done

# 6) Verify raft membership (requires login)
kubectl -n security exec vault-0 -- sh -ec "vault login '$ROOT_TOKEN' >/dev/null && vault operator raft list-peers"

# 7) Cleanup shell variables
unset KEY1 KEY2 ROOT_TOKEN
```

If any pod says Vault is not initialized, re-run step 3 for that pod, then step 4 for that pod.

## Common Operations

### Read a Vault value (example)

```bash
ROOT_TOKEN=$(jq -r '.root_token' ~/vault-init.json)
kubectl -n security exec vault-0 -- sh -ec "vault login '$ROOT_TOKEN' >/dev/null && vault kv get -field=MONGO_PASS kv/apps/productivity/unifi-db-credentials"
unset ROOT_TOKEN
```

### Write/update a Vault value (example)

```bash
ROOT_TOKEN=$(jq -r '.root_token' ~/vault-init.json)
NEW_PASS=$(openssl rand -base64 32 | tr -d '\n')

kubectl -n security exec vault-0 -- sh -ec "vault login '$ROOT_TOKEN' >/dev/null && \
  vault kv put kv/apps/productivity/unifi-db-credentials MONGO_PASS='$NEW_PASS'"

unset ROOT_TOKEN NEW_PASS
```

### Force ESO refresh for one secret

```bash
kubectl -n productivity delete secret unifi-db-credentials
kubectl -n productivity get secret unifi-db-credentials -w
# Ctrl+C after it reappears
```

### Inspect ExternalSecret status

```bash
kubectl -n productivity get externalsecret unifi-db-credentials \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason} {.message}{"\n"}{end}'
```

## Emergency Operations

### Seal a node intentionally

```bash
kubectl -n security exec vault-0 -- vault operator seal
```

### Restart Vault StatefulSet

```bash
kubectl -n security rollout restart statefulset/vault
kubectl -n security rollout status statefulset/vault --timeout=300s
```

Then run the full unseal procedure.

## Troubleshooting

### Vault command returns permission errors

- Check root token source (`~/vault-init.json`)
- Re-run login inside `vault-0` pod and retry command

### Secret does not appear in app namespace

1. Check ExternalSecret conditions.
2. Confirm Vault path and property names match manifest.
3. Confirm `ClusterSecretStore/vault` is `Ready=True`.
4. Delete target Kubernetes Secret to force quick ESO reconcile.

### Vault pods are up but still sealed after restart

- Run full unseal flow for all three pods.
- Verify Raft peers from `vault-0`.
