#!/usr/bin/env bash
set -euo pipefail

PATCH_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
ROOT_DIR=$(cd -- "${PATCH_DIR}/../.." &>/dev/null && pwd)

shopt -s nullglob
PATCHES=(${PATCH_DIR}/*.diff)
shopt -u nullglob

if [ ${#PATCHES[@]} -eq 0 ]; then
  echo "[patches] No patches found; nothing to apply."
  exit 0
fi

pushd "${ROOT_DIR}" >/dev/null
for p in "${PATCHES[@]}"; do
  echo "[patches] Applying ${p}"
  git apply --check "${p}"
  git apply "${p}"
 done
popd >/dev/null

echo "[patches] Done."
