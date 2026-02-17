#!/usr/bin/env bash
set -euo pipefail

IMAGE_REF="${1:-${IMAGE_REF:-}}"
DEPLOY_FILE="${2:-cluster/apps/ai/vllm-general/vllm-general-deployment.yaml}"

if [[ -z "$IMAGE_REF" ]]; then
  echo "Usage: $0 <image-ref> [deployment-file]" >&2
  exit 1
fi

if [[ ! -f "$DEPLOY_FILE" ]]; then
  echo "Deployment file not found: $DEPLOY_FILE" >&2
  exit 1
fi

tmp_file="$(mktemp)"
trap 'rm -f "$tmp_file"' EXIT

awk -v image_ref="$IMAGE_REF" '
  BEGIN {
    in_init_target = 0
    in_main_target = 0
    updated_init = 0
    updated_main = 0
  }
  {
    if ($0 ~ /^[[:space:]]*-[[:space:]]*name:[[:space:]]*install-transformers-nightly[[:space:]]*$/) {
      in_init_target = 1
    }
    if ($0 ~ /^[[:space:]]*-[[:space:]]*name:[[:space:]]*vllm[[:space:]]*$/) {
      in_main_target = 1
    }

    if (in_init_target && $0 ~ /^[[:space:]]*image:[[:space:]]*/) {
      sub(/image:[[:space:]]*.*/, "image: " image_ref)
      updated_init = 1
      in_init_target = 0
    } else if (in_main_target && $0 ~ /^[[:space:]]*image:[[:space:]]*/) {
      sub(/image:[[:space:]]*.*/, "image: " image_ref)
      updated_main = 1
      in_main_target = 0
    }

    print
  }
  END {
    if (!updated_init || !updated_main) {
      exit 42
    }
  }
' "$DEPLOY_FILE" > "$tmp_file" || {
  status=$?
  if [[ "$status" -eq 42 ]]; then
    echo "Failed to find both target image lines in ${DEPLOY_FILE}." >&2
  fi
  exit "$status"
}

mv "$tmp_file" "$DEPLOY_FILE"
echo "Updated ${DEPLOY_FILE} to use image ${IMAGE_REF}"
