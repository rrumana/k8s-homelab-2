#!/usr/bin/env bash
set -euo pipefail

ns="${1:-service-mesh}"

echo "Checking Linkerd CNI daemonset in namespace: ${ns}" >&2
kubectl -n "${ns}" get ds linkerd-cni -o wide
echo "" >&2

pod="$(kubectl -n "${ns}" get pods -l k8s-app=linkerd-cni -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -z "${pod}" ]]; then
  echo "No linkerd-cni pods found in ${ns}." >&2
  exit 1
fi

echo "Using pod: ${pod}" >&2
echo "" >&2

echo "Recent install-cni logs:" >&2
kubectl -n "${ns}" logs "${pod}" -c install-cni --tail=200 || true
echo "" >&2

echo "Host CNI config dir contents (mounted in pod):" >&2
kubectl -n "${ns}" exec "${pod}" -c install-cni -- sh -c 'ls -1 /host/etc/cni/net.d 2>/dev/null || true'
echo "" >&2

echo "Show any CNI conflist entries that mention linkerd-cni:" >&2
kubectl -n "${ns}" exec "${pod}" -c install-cni -- sh -c 'set -e; for f in /host/etc/cni/net.d/*; do [ -f "$f" ] || continue; if grep -q "linkerd-cni" "$f"; then echo "--- $f"; sed -n "1,200p" "$f"; fi; done' || true
echo "" >&2

echo "Host CNI bin dir contains linkerd-cni:" >&2
kubectl -n "${ns}" exec "${pod}" -c install-cni -- sh -c 'ls -1 /host/opt/cni/bin 2>/dev/null | grep -E "^linkerd-cni$" || true'

