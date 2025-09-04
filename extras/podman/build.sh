#!/usr/bin/env bash
set -euo pipefail

# Why: Back-compat wrapper that sources central config and builds using the canonical Dockerfile.

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
ROOT_DIR=$(cd -- "${SCRIPT_DIR}/../.." &>/dev/null && pwd)
CONFIG_DIR="${SCRIPT_DIR}/../configs"

# shellcheck source=../configs/build.env
if [ -f "${CONFIG_DIR}/build.env" ]; then
  # shellcheck disable=SC1091
  source "${CONFIG_DIR}/build.env"
fi

CUDA_VERSION=${CUDA_VERSION:-13.0.0}
UBI_VERSION=${UBI_VERSION:-9}
VLLM_IMAGE_TAG=${VLLM_IMAGE_TAG:-"vllm-cuda${CUDA_VERSION}-ubi${UBI_VERSION}"}

CONTEXT="${ROOT_DIR}"
DOCKERFILE_REL="extras/Dockerfile"

echo "[podman/build] Building image ${VLLM_IMAGE_TAG} with CUDA=${CUDA_VERSION}, UBI=${UBI_VERSION}"

podman build \
  --build-arg CUDA_VERSION="${CUDA_VERSION}" \
  --build-arg UBI_VERSION="${UBI_VERSION}" \
  -t "${VLLM_IMAGE_TAG}" \
  -f "${DOCKERFILE_REL}" \
  "${CONTEXT}"

echo "[podman/build] Done -> ${VLLM_IMAGE_TAG}"
