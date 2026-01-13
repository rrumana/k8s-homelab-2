#!/usr/bin/env bash
set -euo pipefail

# Extremely insecure: prints secret values to stdout.
# Usage:
#   scripts/print-manual-secrets.sh
#     - filtered (likely manual) secrets
#     - defaults to app namespaces from cluster/platform/base/namespaces/application.yaml
#   scripts/print-manual-secrets.sh --all
#     - print all non-service-account secrets (still respects namespace filter)
#   scripts/print-manual-secrets.sh --all-namespaces
#     - disable namespace filtering
#   scripts/print-manual-secrets.sh --namespaces media,productivity
#     - override namespace filter explicitly

usage() {
  cat <<'USAGE'
Usage: scripts/print-manual-secrets.sh [--all] [--all-namespaces] [--namespaces ns1,ns2]
USAGE
}

all_mode=0
no_ns_filter=0
namespace_filter=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all)
      all_mode=1
      ;;
    --all-namespaces)
      no_ns_filter=1
      ;;
    --namespaces)
      namespace_filter="${2:-}"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

if [[ -z "$namespace_filter" && "$no_ns_filter" -eq 0 ]]; then
  ns_file="$repo_root/cluster/platform/base/namespaces/application.yaml"
  if [[ -f "$ns_file" ]]; then
    namespace_filter="$(awk '/^[[:space:]]*name:[[:space:]]*/{print $2}' "$ns_file" | paste -sd, -)"
  else
    namespace_filter="media,productivity,ai,web,other"
  fi
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
if [[ -n "$namespace_filter" ]]; then
  export PRINT_SECRETS_NAMESPACES="$namespace_filter"
fi

python3 - "$tmp" <<'PY'
import base64
import json
import os
import sys

path = sys.argv[1]
use_all = os.environ.get("PRINT_SECRETS_ALL") == "1"
ns_filter_raw = os.environ.get("PRINT_SECRETS_NAMESPACES", "")
ns_filter = {ns.strip() for ns in ns_filter_raw.split(",") if ns.strip()}

with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)

items = data.get("items", [])
skip_label_keys = {"argocd.argoproj.io/instance", "helm.sh/chart"}
skip_annot_prefixes = ("external-secrets.io/", "cert-manager.io/")

for s in items:
    meta = s.get("metadata", {})
    if s.get("type") == "kubernetes.io/service-account-token":
        continue
    if ns_filter and meta.get("namespace") not in ns_filter:
        continue
    if not use_all:
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
