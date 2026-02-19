#!/usr/bin/env bash
set -euo pipefail

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_cmd skopeo
require_cmd python3

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GHCR_USER="${GHCR_USER:-}"
GHCR_TOKEN="${GHCR_TOKEN:-${GHCR_PAT:-${GITHUB_PAT:-}}}"
IMAGE_REGISTRY="${IMAGE_REGISTRY:-ghcr.io}"
IMAGE_NAME="${IMAGE_NAME:-vllm-openai-rocm-gfx1150}"
ROCM_ARCH="${ROCM_ARCH:-gfx1150}"
UPSTREAM_IMAGE="${UPSTREAM_IMAGE:-docker://docker.io/rocm/vllm-dev:nightly}"
TRACK_TAG="${TRACK_TAG:-nightly-gfx1150}"
FORCE_BUILD="${FORCE_BUILD:-0}"
UPDATE_MANIFEST="${UPDATE_MANIFEST:-1}"
DEPLOY_FILE="${DEPLOY_FILE:-cluster/apps/ai/vllm-general/vllm-general-deployment.yaml}"

if [[ -z "$GHCR_USER" ]]; then
  echo "GHCR_USER is required (for example: rrumana)." >&2
  exit 1
fi

if [[ -n "$GHCR_TOKEN" ]]; then
  echo "$GHCR_TOKEN" | skopeo login --username "$GHCR_USER" --password-stdin "$IMAGE_REGISTRY" >/dev/null
fi

target_image="docker://${IMAGE_REGISTRY}/${GHCR_USER}/${IMAGE_NAME}:${TRACK_TAG}"
upstream_digest="$(skopeo inspect --format '{{.Digest}}' "$UPSTREAM_IMAGE")"
digest_short="${upstream_digest#sha256:}"
digest_short="${digest_short:0:12}"
new_tag="${TRACK_TAG}-${digest_short}"

echo "Upstream digest: ${upstream_digest}"

current_tracked_digest=""
if target_inspect="$(skopeo inspect "$target_image" 2>/dev/null)"; then
  current_tracked_digest="$(
    printf '%s' "$target_inspect" \
      | python3 -c 'import json,sys; doc=json.load(sys.stdin); labels=doc.get("Labels") or {}; print(labels.get("io.rrumana.vllm.upstream.digest",""))'
  )"
fi

if [[ "$FORCE_BUILD" != "1" && -n "$current_tracked_digest" && "$current_tracked_digest" == "$upstream_digest" ]]; then
  echo "No upstream digest change detected for ${TRACK_TAG}. Nothing to build."
  exit 0
fi

echo "Building new image tags: ${new_tag} and ${TRACK_TAG}"
GHCR_USER="$GHCR_USER" \
IMAGE_REGISTRY="$IMAGE_REGISTRY" \
IMAGE_NAME="$IMAGE_NAME" \
ROCM_ARCH="$ROCM_ARCH" \
BASE_IMAGE_REF="docker.io/rocm/vllm-dev:nightly" \
UPSTREAM_DIGEST_LABEL="$upstream_digest" \
TAG="$new_tag" \
EXTRA_TAGS="$TRACK_TAG" \
"${SCRIPT_DIR}/build-vllm-gfx1150.sh" \
  "${@}"

if [[ "$UPDATE_MANIFEST" == "1" ]]; then
  image_ref="${IMAGE_REGISTRY}/${GHCR_USER}/${IMAGE_NAME}:${new_tag}"
  "${SCRIPT_DIR}/update-vllm-general-image.sh" "$image_ref" "$DEPLOY_FILE"
fi

echo "Build complete."
echo "Pinned image tag: ${IMAGE_REGISTRY}/${GHCR_USER}/${IMAGE_NAME}:${new_tag}"
