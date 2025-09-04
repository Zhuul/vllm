#!/usr/bin/env bash
set -euo pipefail

# Normalize CRLF and re-exec if needed
if grep -q $'\r' "$0" 2>/dev/null; then
  TMP_SELF=$(mktemp /tmp/apply_patches_self.XXXXXX.sh)
  tr -d '\r' < "$0" > "$TMP_SELF" || cp "$0" "$TMP_SELF"
  chmod +x "$TMP_SELF" 2>/dev/null || true
  exec "$TMP_SELF" "$@"
fi

# Resolve paths
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# Treat current working directory as repo root (wrapper cd's to /workspace)
ROOT_DIR=${ROOT_DIR:-$(pwd)}
# Prefer patches from repo under ./extras/patches; fall back to script dir (e.g., /tmp copy)
PRIMARY_PATCH_DIR="${ROOT_DIR}/extras/patches"
PATCH_DIR="$PRIMARY_PATCH_DIR"
if [ ! -d "$PATCH_DIR" ] || ! ls "$PATCH_DIR"/*.diff >/dev/null 2>&1; then
  PATCH_DIR="$SCRIPT_DIR"
fi

pushd "$ROOT_DIR" >/dev/null

shopt -s nullglob
PATCHES=("${PATCH_DIR}"/*.diff)
shopt -u nullglob

echo "[patches] Using ROOT_DIR=$ROOT_DIR"
echo "[patches] Scanning ${PATCH_DIR} for .diff files"
echo "[patches] Found ${#PATCHES[@]} .diff file(s) in ${PATCH_DIR}"
for pp in "${PATCHES[@]}"; do echo "  - $(basename "$pp")"; done

for p in "${PATCHES[@]}"; do
  echo "[patches] Applying ${p}"
  # Normalize EOL to a temp patch file
  TMP_PATCH=$(mktemp /tmp/patch.XXXXXX.diff)
  tr -d '\r' < "$p" > "$TMP_PATCH" 2>/dev/null || cp "$p" "$TMP_PATCH"
  if git apply --check "$TMP_PATCH" 2>/dev/null; then
    git apply "$TMP_PATCH" || true
    continue
  fi
  echo "[patches] git apply check failed for $(basename "$p"); attempting fallback if known"
  case "$(basename "$p")" in
    0001-cumem-alloc-env-fallback.diff)
      echo "[patches] Fallback: update cumem allocator env var preference"
      python - <<'PY'
import io, os
path = os.path.join('vllm','device_allocator','cumem.py')
try:
  with io.open(path, 'r', encoding='utf-8', newline='') as f:
    src = f.read()
except FileNotFoundError:
  raise SystemExit(0)
if 'PYTORCH_ALLOC_CONF' in src:
  print('[patches] cumem already prefers PYTORCH_ALLOC_CONF; skipping')
  raise SystemExit(0)
needle = 'conf = os.environ.get("PYTORCH_CUDA_ALLOC_CONF", "")'
if needle in src:
  new = src.replace(needle,
    'conf = os.environ.get("PYTORCH_ALLOC_CONF",\n'
    '                              os.environ.get("PYTORCH_CUDA_ALLOC_CONF", ""))')
  with io.open(path, 'w', encoding='utf-8', newline='\n') as f:
    f.write(new)
  print('[patches] Applied cumem env var fallback edit')
else:
  print('[patches] cumem pattern not found; skipping')
PY
      ;;
    0002-cub-reduce-to-sum-cuda13.diff)
      echo "[patches] Fallback will be handled by the post-pass rewrite"
      ;;
    *)
      echo "[patches] Unknown patch; skipping fallback"
      ;;
  esac
done

echo "[patches] Post-pass: normalize CUB reductions to device lambdas for CUDA 13"
python - <<'PY'
import io, os, re

files = []
for root, _, names in os.walk('csrc'):
  for n in names:
    if n.endswith(('.cu', '.cuh')):
      files.append(os.path.join(root, n))

def lam_for(op: str) -> str:
  if op == 'Sum':
    return '[] __device__ (auto a, auto b) { return a + b; }'
  if op == 'Max':
    return '[] __device__ (auto a, auto b) { return a > b ? a : b; }'
  return '[] __device__ (auto a, auto b) { return a < b ? a : b; }'

# Patterns
pat_method = re.compile(r'(BlockReduce\([^)]*\))\s*\.\s*(Sum|Max|Min)\(\s*([\s\S]*?)\s*\)', re.DOTALL)
pat_functor = re.compile(r'(BlockReduce\([^)]*\))\s*\.\s*Reduce\(\s*([\s\S]*?)\s*,\s*cub::(Sum|Max|Min)\s*(?:\(\)|\{\})\s*([\s\S]*?)\)', re.DOTALL)

changed_any = False
for path in files:
  try:
    with io.open(path, 'r', encoding='utf-8', newline='') as f:
      src = f.read()
  except FileNotFoundError:
    continue

  new_src = src

  # Replace method form first
  def repl_method(m):
    recv, op, expr = m.group(1), m.group(2), (m.group(3) or '').strip()
    return f"{recv}.Reduce({expr}, {lam_for(op)})"
  new_src = pat_method.sub(repl_method, new_src)

  # Replace functor form
  def repl_functor(m):
    recv, expr, op, tail = m.group(1), (m.group(2) or '').strip(), m.group(3), (m.group(4) or '').rstrip()
    return f"{recv}.Reduce({expr}, {lam_for(op)}{tail})"
  new_src = pat_functor.sub(repl_functor, new_src)

  if new_src != src:
    with io.open(path, 'w', encoding='utf-8', newline='\n') as f:
      f.write(new_src)
    print(f"[patches] Rewrote CUB reductions in {path}")
    changed_any = True

if not changed_any:
  print('[patches] Post-pass: no changes (already applied)')
PY

# Also relax cumem allocator assert to allow user opting into expandable segments
python - <<'PY'
import io, os, re
path = os.path.join('vllm','device_allocator','cumem.py')
try:
  with io.open(path, 'r', encoding='utf-8') as f:
    src = f.read()
except FileNotFoundError:
  print('[patches] cumem.py not found; skipping assert relax')
else:
  new_src = src
  # Remove the multi-line assert block guarding expandable_segments
  new_src = re.sub(
    r"assert\s+\"expandable_segments:True\"\s+not\s+in\s+conf,\s*\\\n\s*\(.*?\)\s*\n",
    "",
    new_src,
    flags=re.DOTALL,
  )
  # If a single-line variant exists, remove it too
  new_src = re.sub(
    r"^\s*assert\s+\"expandable_segments:True\".*$\n",
    "",
    new_src,
    flags=re.MULTILINE,
  )
  if new_src != src:
    with io.open(path, 'w', encoding='utf-8', newline='\n') as f:
      f.write(new_src)
    print('[patches] Relaxed expandable_segments assert in vllm/device_allocator/cumem.py')
  else:
    print('[patches] No expandable_segments assert to relax (already updated)')
PY

popd >/dev/null

echo "[patches] Done."
