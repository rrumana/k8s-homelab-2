#!/usr/bin/env bash
set -euo pipefail

# Extremely insecure: prints secret values to stdout.
# Usage:
#   scripts/print-manual-secrets.sh         # filtered (likely manual) secrets only
#   scripts/print-manual-secrets.sh --all   # print all non-service-account secrets

all_mode=0
if [[ "${1:-}" == "--all" ]]; then
  all_mode=1
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

if ! kubectl get secrets -A -o json >"$tmp"; then
  echo "ERROR: kubectl failed; check kubeconfig/context and permissions." >&2
  exit 1
fi

if [[ ! -s "$tmp" ]]; then
  echo "ERROR: kubectl returned empty output." >&2
  exit 1
fi

if [[ "$all_mode" -eq 1 ]]; then
  export PRINT_SECRETS_ALL=1
fi

python3 - "$tmp" <<'PY'
import base64
import json
import os
import sys

path = sys.argv[1]
use_all = os.environ.get("PRINT_SECRETS_ALL") == "1"

with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)

items = data.get("items", [])
skip_label_keys = {"argocd.argoproj.io/instance", "helm.sh/chart"}
skip_annot_prefixes = ("external-secrets.io/", "cert-manager.io/")

for s in items:
    meta = s.get("metadata", {})
    if not use_all:
        if s.get("type") == "kubernetes.io/service-account-token":
            continue
        if meta.get("ownerReferences"):
            continue
        labels = meta.get("labels") or {}
        ann = meta.get("annotations") or {}
        if any(k in labels or k in ann for k in skip_label_keys):
            continue
        if any(k.startswith(skip_annot_prefixes) for k in ann.keys()):
            continue

    ns = meta.get("namespace", "unknown")
    name = meta.get("name", "unknown")
    typ = s.get("type", "Opaque")
    print(f"### {ns}/{name} ({typ})")

    data_items = s.get("data") or {}
    if not data_items:
        print("(no data)")
    for k, v in data_items.items():
        try:
            val = base64.b64decode(v).decode("utf-8", "replace")
        except Exception:
            val = "<decode-error>"
        print(f"{k}={val}")
    print()
PY
