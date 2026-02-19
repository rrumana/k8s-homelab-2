#!/usr/bin/env bash
set -euo pipefail

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_cmd docker
require_cmd git

GHCR_USER="${GHCR_USER:-}"
GHCR_TOKEN="${GHCR_TOKEN:-${GHCR_PAT:-${GITHUB_PAT:-}}}"
IMAGE_REGISTRY="${IMAGE_REGISTRY:-ghcr.io}"
IMAGE_NAME="${IMAGE_NAME:-vllm-openai-rocm-gfx1150}"
ROCM_ARCH="${ROCM_ARCH:-gfx1150}"
PLATFORM="${PLATFORM:-linux/amd64}"
VLLM_GIT_URL="${VLLM_GIT_URL:-https://github.com/vllm-project/vllm.git}"
VLLM_REF="${VLLM_REF:-main}"
BASE_IMAGE_REF="${BASE_IMAGE_REF:-docker.io/rocm/vllm-dev:nightly}"
UPSTREAM_DIGEST_LABEL="${UPSTREAM_DIGEST_LABEL:-}"
TAG="${TAG:-manual-$(date -u +%Y%m%d-%H%M%S)}"
EXTRA_TAGS="${EXTRA_TAGS:-}"
PUSH="${PUSH:-1}"
KEEP_WORKDIR="${KEEP_WORKDIR:-0}"

if [[ -z "$GHCR_USER" ]]; then
  echo "GHCR_USER is required (for example: rrumana)." >&2
  exit 1
fi

if [[ "$PUSH" == "1" && -z "$GHCR_TOKEN" ]]; then
  echo "GHCR_TOKEN or GHCR_PAT is required when PUSH=1." >&2
  exit 1
fi

IMAGE_REPO="${IMAGE_REGISTRY}/${GHCR_USER}/${IMAGE_NAME}"
WORK_ROOT="$(mktemp -d /tmp/vllm-gfx1150-build.XXXXXX)"

cleanup() {
  if [[ "$KEEP_WORKDIR" != "1" ]]; then
    rm -rf "$WORK_ROOT"
  fi
}
trap cleanup EXIT

ensure_rocm_requirements_compat() {
  local root_req_dir="$1/requirements"
  local pkg_req_dir="$1/vllm/requirements"
  local root_rocm_req="${root_req_dir}/rocm.txt"
  local pkg_rocm_req="${pkg_req_dir}/rocm.txt"

  if [[ -f "$root_rocm_req" || -f "$pkg_rocm_req" ]]; then
    mkdir -p "$root_req_dir" "$pkg_req_dir"
    [[ -f "$root_rocm_req" ]] || cp "$pkg_rocm_req" "$root_rocm_req" || true
    [[ -f "$pkg_rocm_req" ]] || cp "$root_rocm_req" "$pkg_rocm_req" || true
    echo "requirements/rocm.txt already present in repository layout"
    return 0
  fi

  echo "requirements/rocm.txt not found; creating compatibility shims"
  mkdir -p "$root_req_dir" "$pkg_req_dir"
  for candidate in \
    "${root_req_dir}/rocm-dev.txt" \
    "${root_req_dir}/rocm_dev.txt" \
    "${root_req_dir}/rocm-requirements.txt" \
    "${root_req_dir}/build.txt" \
    "${root_req_dir}/common.txt" \
    "${root_req_dir}/cuda.txt" \
    "${pkg_req_dir}/rocm-dev.txt" \
    "${pkg_req_dir}/rocm_dev.txt" \
    "${pkg_req_dir}/rocm-requirements.txt" \
    "${pkg_req_dir}/build.txt" \
    "${pkg_req_dir}/common.txt" \
    "${pkg_req_dir}/cuda.txt"; do
    if [[ -f "$candidate" ]]; then
      cp "$candidate" "$root_rocm_req"
      cp "$candidate" "$pkg_rocm_req"
      echo "Created compatibility rocm.txt from $(basename "$candidate")"
      return 0
    fi
  done

  : > "$root_rocm_req"
  cp "$root_rocm_req" "$pkg_rocm_req"
  echo "No compatible requirements file found; created empty rocm.txt shims"
}

patch_dockerfile_rocm_requirements() {
  local dockerfile="$1/docker/Dockerfile.rocm"
  if [[ ! -f "$dockerfile" ]]; then
    echo "Dockerfile not found at $dockerfile" >&2
    exit 1
  fi

  echo "Patching Dockerfile.rocm to support fallback requirements paths"
  sed -i \
    "s|python3 -m pip install -r requirements/rocm.txt|python3 -m pip install -r requirements/rocm.txt || python3 -m pip install -r requirements/build.txt || python3 -m pip install -r requirements/common.txt || python3 -m pip install -r vllm/requirements/rocm.txt || python3 -m pip install -r vllm/requirements/build.txt || python3 -m pip install -r vllm/requirements/common.txt|g" \
    "$dockerfile"
  grep -n "python3 -m pip install -r" "$dockerfile" | head -n 5 || true
}

echo "Cloning vLLM source (${VLLM_REF}) into ${WORK_ROOT}"
git clone --depth 1 "$VLLM_GIT_URL" "$WORK_ROOT/vllm"
if [[ "$VLLM_REF" != "main" ]]; then
  git -C "$WORK_ROOT/vllm" fetch --depth 1 origin "$VLLM_REF"
  git -C "$WORK_ROOT/vllm" checkout "$VLLM_REF"
fi
ensure_rocm_requirements_compat "$WORK_ROOT/vllm"
patch_dockerfile_rocm_requirements "$WORK_ROOT/vllm"
find "$WORK_ROOT/vllm" -type f -path '*/requirements/rocm.txt' -print || true

if [[ "$PUSH" == "1" ]]; then
  echo "$GHCR_TOKEN" | docker login "$IMAGE_REGISTRY" -u "$GHCR_USER" --password-stdin
fi

build_cmd=(
  docker buildx build
  --platform "$PLATFORM"
  -f docker/Dockerfile.rocm
  --build-arg "ARG_PYTORCH_ROCM_ARCH=${ROCM_ARCH}"
  --build-arg "BASE_IMAGE=${BASE_IMAGE_REF}"
  --label "io.rrumana.vllm.rocm.arch=${ROCM_ARCH}"
  --label "io.rrumana.vllm.upstream.base=${BASE_IMAGE_REF}"
  -t "${IMAGE_REPO}:${TAG}"
)

if [[ -n "$UPSTREAM_DIGEST_LABEL" ]]; then
  build_cmd+=(--label "io.rrumana.vllm.upstream.digest=${UPSTREAM_DIGEST_LABEL}")
fi

if [[ -n "$EXTRA_TAGS" ]]; then
  for extra_tag in $EXTRA_TAGS; do
    build_cmd+=(-t "${IMAGE_REPO}:${extra_tag}")
  done
fi

if [[ "$PUSH" == "1" ]]; then
  build_cmd+=(--push)
else
  build_cmd+=(--load)
fi

build_cmd+=(.)

echo "Building image: ${IMAGE_REPO}:${TAG}"
(
  cd "$WORK_ROOT/vllm"
  "${build_cmd[@]}"
)

echo "Done."
echo "Primary image tag: ${IMAGE_REPO}:${TAG}"
