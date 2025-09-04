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

# Unified pattern: handle both method form and functor form
pat = re.compile(
  r"(?P<recv>BlockReduce\([^)]*\))\."
  r"(?:"
  r"Reduce\(\s*(?P<expr>[^,()]+?)\s*,\s*cub::(?P<op1>Sum|Max|Min)\s*(?:\(\)|\{\})\s*(?P<tail1>,[^)]*)?\)"
  r"|"
  r"(?P<method>Sum|Max|Min)\(\s*(?P<mexpr>[^)]+?)\s*\)"
  r")"
)

def lam_for(op: str) -> str:
  if op == 'Sum':
    return '[] __device__ (auto a, auto b) { return a + b; }'
  if op == 'Max':
    return '[] __device__ (auto a, auto b) { return a > b ? a : b; }'
  return '[] __device__ (auto a, auto b) { return a < b ? a : b; }'

changed_any = False
for path in files:
  try:
    with io.open(path, 'r', encoding='utf-8', newline='') as f:
      src = f.read()
  except FileNotFoundError:
    continue

  def repl(m):
    recv = m.group('recv')
    if m.group('op1'):
      op = m.group('op1')
      expr = (m.group('expr') or '').strip()
      tail = m.group('tail1') or ''
    else:
      op = m.group('method')
      expr = (m.group('mexpr') or '').strip()
      tail = ''
    lam = lam_for(op)
    return f"{recv}.Reduce({expr}, {lam}{tail})"

  new_src = pat.sub(repl, src)

  if new_src != src:
    with io.open(path, 'w', encoding='utf-8', newline='\n') as f:
      f.write(new_src)
    print(f"[patches] Rewrote CUB reductions in {path}")
    changed_any = True

if not changed_any:
  print('[patches] Post-pass: no changes (already applied)')
PY

popd >/dev/null

echo "[patches] Done."
