#!/usr/bin/env bash
# Robust setup entrypoint: prefer extras/dev-setup.sh,
# otherwise use the image-provided /home/vllmuser/setup_vllm_dev.sh.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}" )" &>/dev/null && pwd)
EXTRAS_DIR=$(cd -- "${SCRIPT_DIR}/.." &>/dev/null && pwd)

export VLLM_PATCH_ENV=container
BUILD_ENV_FILE="${EXTRAS_DIR}/configs/build.env"
if [[ -f "$BUILD_ENV_FILE" ]]; then
	# shellcheck disable=SC1090
	. "$BUILD_ENV_FILE"
fi

try_exec() {
	local target="$1"
	if [[ -f "$target" ]]; then
		# Normalize CRLF and avoid chmod on mounted FS
		local tmp
		tmp="$(mktemp /tmp/dev-setup-target.XXXX.sh)"
		tr -d '\r' < "$target" > "$tmp" 2>/dev/null || cp "$target" "$tmp"
		chmod +x "$tmp" 2>/dev/null || true
		exec "$tmp" "$@"
	fi
}

prepare_src_overlay() {
    local src_root="/workspace"
    local overlay_root="${SRC_OVERLAY_ROOT:-}"
    # Choose overlay root: prefer /opt/work if available and writable, else /tmp
    if [[ -z "$overlay_root" ]]; then
        if [[ -d /opt/work && -w /opt/work ]]; then
            overlay_root="/opt/work/src-overlay"
        else
            overlay_root="/tmp/src-overlay"
        fi
    fi
    if ! mkdir -p "$overlay_root" 2>/dev/null; then
        overlay_root="/tmp/src-overlay"
        mkdir -p "$overlay_root"
    fi

    # Mirror the workspace into overlay
    if command -v rsync >/dev/null 2>&1; then
        rsync -a --delete \
            --exclude='.git' \
            --exclude='.venv' --exclude='venv' \
            --exclude='__pycache__' \
            --exclude='*.egg-info' \
            --exclude='build' --exclude='dist' \
            "$src_root/" "$overlay_root/"
    else
        ( cd "$src_root" && tar --exclude-vcs \
            --exclude='.venv' --exclude='venv' \
            --exclude='__pycache__' \
            --exclude='*.egg-info' \
            --exclude='build' --exclude='dist' \
            -cf - . ) | ( cd "$overlay_root" && tar -xf - )
    fi

    # Apply repo patches in overlay only
    if [[ -f "$overlay_root/extras/patches/apply_patches_overlay.sh" ]]; then
        (
            cd "$overlay_root"
            # Avoid noisy filemode warnings when applying patches on copied trees
            git config core.filemode false >/dev/null 2>&1 || true
            PYTHON_PATCH_OVERLAY=0 VLLM_PATCH_ENV=container bash ./extras/patches/apply_patches_overlay.sh >&2 || true
        )
    elif [[ -f "$overlay_root/extras/patches/apply_patches.sh" ]]; then
        (
            cd "$overlay_root"
            git config core.filemode false >/dev/null 2>&1 || true
            PYTHON_PATCH_OVERLAY=0 VLLM_PATCH_ENV=container bash ./extras/patches/apply_patches.sh >&2 || true
        )
    fi

    # Sanity check: must look like a Python package root
    if [[ ! -f "$overlay_root/setup.py" && ! -f "$overlay_root/pyproject.toml" ]]; then
        echo "[dev-setup] ERROR: overlay missing setup.py/pyproject at $overlay_root" >&2
        exit 1
    fi

    echo "[dev-setup] Source overlay prepared at $overlay_root" >&2
    printf '%s' "$overlay_root"
}

apply_overlay_transform() {
	local name="$1"
	local root="$2"
	local rel="$3"
	case "$name" in
		cumem-env)
			python - "$root" "$rel" <<'PY'
import io, os, re, sys
root, rel = sys.argv[1], sys.argv[2]
path = os.path.join(root, rel)
try:
    with io.open(path, 'r', encoding='utf-8') as f:
        src = f.read()
except FileNotFoundError:
    raise SystemExit('[overlay] Transform target missing: ' + path)

needle = 'conf = os.environ.get("PYTORCH_CUDA_ALLOC_CONF", "")'
replacement = 'conf = os.environ.get("PYTORCH_ALLOC_CONF",\n                              os.environ.get("PYTORCH_CUDA_ALLOC_CONF", ""))'
if needle in src:
    src = src.replace(needle, replacement)

src = re.sub(
    r"\s*assert \"expandable_segments:True\"[\s\S]*?updates\.\)\n\n",
    "\n",
    src,
)

with io.open(path, 'w', encoding='utf-8', newline='\n') as f:
    f.write(src)
print(f"[overlay] Applied cumem-env transform to {rel}")
PY
			;;
		*)
			echo "[overlay] Unknown transform '$name'" >&2
			;;
	esac
}

publish_python_overlays() {
	local list_file="/workspace/extras/patches/python-overrides.txt"
	if [[ ! -f "$list_file" ]]; then
		return
	fi
	local entries=()
	mapfile -t entries < <(grep -vE '^\s*(#|$)' "$list_file") || true
	if [[ ${#entries[@]} -eq 0 ]]; then
		return
	fi

		local overlay_root=""
		local overlay_env="${PYTHON_PATCH_OVERLAY:-}"
		if [[ -n "$overlay_env" ]]; then
			case "$overlay_env" in
				1|[Tt][Rr][Uu][Ee]|[Yy][Ee][Ss]|[Oo][Nn])
					overlay_root=""
					;;
				*)
					overlay_root="$overlay_env"
					;;
			esac
		fi
		if [[ -z "$overlay_root" ]]; then
			if [[ -d /opt/work ]]; then
				overlay_root="/opt/work/python-overrides"
			else
				overlay_root="/tmp/python-overrides"
			fi
		fi

	mkdir -p "$overlay_root" || true
		if command -v git >/dev/null 2>&1; then
			git config --global --add safe.directory /workspace >/dev/null 2>&1 || true
		fi
	local copied=0
	for raw in "${entries[@]}"; do
		local parts=()
		IFS='::' read -r -a parts <<< "$raw"
		local mapping="${parts[0]}"
		local extras=()
		if [[ ${#parts[@]} -gt 1 ]]; then
			extras=(${parts[@]:1})
		fi

		local map_src="$mapping"
		local map_dest="$mapping"
		if [[ "$mapping" == *"->"* ]]; then
			map_src="${mapping%%->*}"
			map_dest="${mapping##*->}"
		fi
		map_src="$(echo "$map_src" | xargs)"
		map_dest="$(echo "$map_dest" | xargs)"
		if [[ -z "$map_src" ]]; then
			continue
		fi
		if [[ -z "$map_dest" ]]; then
			map_dest="$map_src"
		fi
		local src="/workspace/$map_src"
		if [[ ! -f "$src" ]]; then
			echo "[overlay] Skipping $map_src (not found)" >&2
			continue
		fi
		local dest="$overlay_root/$map_dest"
		mkdir -p "$(dirname "$dest")"
		cp -f "$src" "$dest"
		echo "[overlay] Copied $map_src -> $dest"
		((copied++))
		if git ls-files --error-unmatch "$map_dest" >/dev/null 2>&1; then
			if ! git checkout -- "$map_dest" >/dev/null 2>&1; then
				echo "[overlay] Failed to restore $map_dest from Git" >&2
				exit 1
			fi
			if git status --porcelain --untracked-files=no -- "$map_dest" | grep -q '.'; then
				echo "[overlay] $map_dest remains dirty after checkout" >&2
				exit 1
			fi
		fi

		if [[ ${#extras[@]} -gt 0 ]]; then
			for extra in "${extras[@]}"; do
				extra="$(echo "$extra" | xargs)"
				if [[ -z "$extra" ]]; then
					continue
				fi
				if [[ "$extra" == transform=* ]]; then
					local transform_name="${extra#transform=}"
					apply_overlay_transform "$transform_name" "$overlay_root" "$map_dest"
				else
					echo "[overlay] Unsupported directive '$extra'" >&2
				fi
			done
		fi
	done

	if [[ $copied -eq 0 ]]; then
		echo "[overlay] No overlay entries copied"
		return
	fi

	if command -v git >/dev/null 2>&1; then
		if git status --porcelain --untracked-files=no | grep -q '.'; then
			echo "[overlay] ERROR: Tracked files changed during overlay publish" >&2
			git status --short --untracked-files=no >&2 || true
			exit 1
		fi
	fi

	local purelib
	purelib=$(python - <<'PY'
import sysconfig
print(sysconfig.get_paths().get('purelib', ''), end='')
PY
)
	if [[ -n "$purelib" ]]; then
		mkdir -p "$purelib"
		local pth_file="$purelib/vllm_extras_overlay.pth"
		printf '%s\n' "$overlay_root" > "$pth_file"
		echo "[overlay] Registered overlay at $pth_file"
	else
		echo "[overlay] Unable to locate site-packages; overlay not registered" >&2
	fi
}

# 1) Current canonical path
if [[ -f "${EXTRAS_DIR}/dev-setup.sh" ]]; then
	try_exec "${EXTRAS_DIR}/dev-setup.sh" "$@"
fi

# 2) Fallback: perform a minimal editable install inline (avoid chmod on /tmp)
echo "🔧 Setting up vLLM (inline fallback)..."
cd /workspace

if command -v git >/dev/null 2>&1; then
	git config --global --add safe.directory /workspace >/dev/null 2>&1 || true
fi

export SETUPTOOLS_SCM_ROOT=${SETUPTOOLS_SCM_ROOT:-/workspace}
export SETUPTOOLS_SCM_IGNORE_VCS_ERRORS=${SETUPTOOLS_SCM_IGNORE_VCS_ERRORS:-1}

# Prepare container-local patched source copy
SRC_OVERLAY_DIR=$(prepare_src_overlay)
# Point setuptools_scm at the overlay copy for version resolution
export SETUPTOOLS_SCM_ROOT="$SRC_OVERLAY_DIR"

# Prefer /opt/work/tmp (mounted volume) if available, else /tmp
if [[ -d /opt/work ]]; then
	export TMPDIR=/opt/work/tmp
else
	export TMPDIR=/tmp
fi
mkdir -p "$TMPDIR" || true

# Build env knobs
export CMAKE_BUILD_PARALLEL_LEVEL=${CMAKE_BUILD_PARALLEL_LEVEL:-4}
export VLLM_INSTALL_PUNICA_KERNELS=${VLLM_INSTALL_PUNICA_KERNELS:-0}
export MAX_JOBS=${MAX_JOBS:-4}
# CUDA 13 toolchain dropped SM70/75; ensure we don't pass them to nvcc
export TORCH_CUDA_ARCH_LIST=${TORCH_CUDA_ARCH_LIST:-"8.0 8.6 8.9 9.0 12.0 13.0"}
export CUDAARCHS=${CUDAARCHS:-"80;86;89;90;120"}

# Install Python deps from repo (torch stack already in image)
if [[ -f requirements/common.txt ]]; then
	pip install -r requirements/common.txt || true
fi

# Ensure build backend is available when using --no-build-isolation
pip install -U "setuptools>=77,<80" setuptools-scm wheel packaging || true

# Avoid slow git describe during setuptools_scm by providing a pretend version
export SETUPTOOLS_SCM_PRETEND_VERSION=${SETUPTOOLS_SCM_PRETEND_VERSION:-0+local}

# Avoid slow git describe during setuptools_scm by providing a pretend version
export SETUPTOOLS_SCM_PRETEND_VERSION=${SETUPTOOLS_SCM_PRETEND_VERSION:-0+local}

echo "📦 Installing vLLM in editable mode from overlay..."
# Use --no-use-pep517 and proper environment variables to handle filesystem restrictions
# This avoids the need for dangerous monkey patching of core Python modules
export PIP_DISABLE_PIP_VERSION_CHECK=1
install_editable_from_overlay() {
    cd "$SRC_OVERLAY_DIR"
    FETCHCONTENT_BASE_DIR="$TMPDIR/deps" \
        pip install -e . --no-deps --no-build-isolation --verbose \
        --config-settings build-dir="$TMPDIR/vllm-build"
}

if ! install_editable_from_overlay; then
    echo "? Editable install via pip failed; attempting legacy develop fallback" >&2
    (
        cd "$SRC_OVERLAY_DIR"
        python setup.py develop
    ) || {
        echo "? Editable install failed. This may be due to filesystem restrictions." >&2
        echo "?? For WSL/Windows mounts, consider using bind mounts with proper options." >&2
        exit 1
    }
fi
echo "✅ vLLM installed in editable mode (from overlay)."

publish_python_overlays

# No reset needed: host workspace remained clean; overlay keeps patches

if command -v git >/dev/null 2>&1; then
	if git status --porcelain --untracked-files=no | grep -q '.'; then
		echo "[dev-setup] ERROR: repository left dirty after setup" >&2
		git status --short --untracked-files=no >&2 || true
		exit 1
	fi
fi

python - <<'PY'
import os, vllm
print("vLLM version:", getattr(vllm, "__version__", "unknown"))
print("FA3_MEMORY_SAFE_MODE:", os.environ.get("FA3_MEMORY_SAFE_MODE"))
PY
