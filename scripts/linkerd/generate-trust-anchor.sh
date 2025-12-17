#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
out_dir="${repo_root}/secrets/linkerd"
tmp_dir="${repo_root}/.tmp/linkerd"

mkdir -p "${out_dir}" "${tmp_dir}"

key_file="${tmp_dir}/trust-anchor.key"
crt_file="${tmp_dir}/trust-anchor.crt"

echo "Generating Linkerd trust anchor (ECDSA P-256)..." >&2

openssl ecparam -name prime256v1 -genkey -noout -out "${key_file}"
openssl req -x509 -new -nodes \
  -key "${key_file}" \
  -sha256 \
  -days 3650 \
  -subj "/CN=linkerd-trust-anchor" \
  -out "${crt_file}"

crt_b64="$(base64 -w0 "${crt_file}" 2>/dev/null || base64 "${crt_file}" | tr -d '\n')"
key_b64="$(base64 -w0 "${key_file}" 2>/dev/null || base64 "${key_file}" | tr -d '\n')"

secret_manifest="${out_dir}/linkerd-trust-anchor-secret.yaml"

cat > "${secret_manifest}" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: linkerd-trust-anchor
  namespace: service-mesh
type: kubernetes.io/tls
data:
  tls.crt: ${crt_b64}
  tls.key: ${key_b64}
EOF

echo "" >&2
echo "Wrote trust-anchor Secret manifest (DO NOT COMMIT):" >&2
echo "  ${secret_manifest}" >&2
echo "" >&2
echo "Next steps:" >&2
echo "  1) Apply it: kubectl apply -f ${secret_manifest}" >&2
echo "  2) Copy the following PEM into:" >&2
echo "       ${repo_root}/cluster/platform/service-mesh/linkerd/control-plane/values.yaml" >&2
echo "     under identityTrustAnchorsPEM:" >&2
echo "" >&2
cat "${crt_file}"
