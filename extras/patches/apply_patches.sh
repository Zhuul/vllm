#!/usr/bin/env bash
set -euo pipefail

# If CRLF detected, re-exec a normalized temp copy to avoid editing mounted files
if grep -q $'\r' "$0" 2>/dev/null; then
  TMP_SELF=$(mktemp /tmp/apply_patches_self.XXXXXX.sh)
  tr -d '\r' < "$0" > "$TMP_SELF" || cp "$0" "$TMP_SELF"
  chmod +x "$TMP_SELF"
  exec "$TMP_SELF" "$@"
fi

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
  # Validate patch looks like a git-format patch and normalize EOL to temp file
  if ! head -n 1 "$p" | grep -q "^From "; then
    echo "[patches] Warning: ${p} is not a git-format patch; trying anyway" >&2
  fi
  TMP_PATCH=$(mktemp /tmp/patch.XXXXXX.diff)
  tr -d '\r' < "$p" > "$TMP_PATCH" || cp "$p" "$TMP_PATCH"
  if ! git apply --check "$TMP_PATCH" 2>/dev/null; then
    echo "[patches] Check failed for ${p}"
    # Fallback: targeted edit for cumem allocator env var change
    case "$(basename "$p")" in
      0001-cumem-alloc-env-fallback.diff)
        echo "[patches] Attempting fallback edit for cumem allocator"
        python - <<'PY'
import io, os, sys
PATH = os.path.join('vllm','device_allocator','cumem.py')
try:
    with io.open(PATH, 'r', encoding='utf-8', newline='') as f:
        src = f.read()
except FileNotFoundError:
    sys.exit(1)

target = 'conf = os.environ.get("PYTORCH_CUDA_ALLOC_CONF", "")'
if 'PYTORCH_ALLOC_CONF' in src:
    print('[patches] cumem already uses PYTORCH_ALLOC_CONF; skipping')
    sys.exit(0)

if target in src:
    indent = ' ' * (len(src.split(target)[0].split('\n')[-1]) - len(src.split(target)[0].split('\n')[-1].lstrip(' ')))
    replacement = (
        f"{indent}# Prefer new env var; fall back to deprecated one for compatibility\n"
        f"{indent}conf = os.environ.get(\"PYTORCH_ALLOC_CONF\",\n"
        f"{indent}                              os.environ.get(\"PYTORCH_CUDA_ALLOC_CONF\", \"\"))"
    )
    new_src = src.replace(target, replacement)
    with io.open(PATH, 'w', encoding='utf-8', newline='\n') as f:
        f.write(new_src)
    print('[patches] Applied cumem allocator fallback edit')
    sys.exit(0)
else:
    print('[patches] Could not find target line in cumem.py; no changes made')
    sys.exit(1)
PY
        status=$?
        if [ $status -ne 0 ]; then
          echo "[patches] Fallback edit failed" >&2; exit 1
        fi
        ;;
      *)
        exit 1
        ;;
    esac
  else
    git apply "$TMP_PATCH"
  fi
done
popd >/dev/null

echo "[patches] Done."
