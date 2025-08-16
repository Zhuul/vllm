#!/usr/bin/env bash
# Unified lightweight vLLM dev container launcher (bash)
# - Podman-only (no Docker)
# - Minimal flags; environment baked into image/Dockerfile
# - Supports build (-b), GPU check (-g), command (-c), help (-h)

set -euo pipefail

IMAGE_TAG="vllm-dev:latest"
CONTAINER_NAME="vllm-dev"
SOURCE_DIR="$(pwd)"

show_help() {
  cat <<EOF
Usage: ./extras/run-vllm-dev.sh [options]

Options:
  -b, --build        Build (or rebuild) the image first
  -c, --command CMD  Run CMD inside container then exit
  -g, --gpu-check    Run lightweight GPU diagnostics inside container
  -s, --setup        Run ./extras/dev-setup.sh inside container
  -p, --progress     Enable in-place progress display during setup
  -m, --mirror       Copy sources into container (LOCAL_MIRROR=1) for faster build on slow mounts
  --work-volume NAME Mount named volume NAME at /opt/work (preferred over host path for large builds)
  -h, --help         Show this help and exit
  -n, --name NAME    Override container name (default: ${CONTAINER_NAME})

Interactive (shell) is default if no command/gpu-check specified.
Examples:
  ./extras/run-vllm-dev.sh -b
  ./extras/run-vllm-dev.sh -c "python -c 'import torch;print(torch.cuda.is_available())'"
  ./extras/run-vllm-dev.sh -g
EOF
}

BUILD=0
GPU_CHECK=0
SETUP=0
CMD=""
MIRROR=0
PROGRESS=0
WORK_VOLUME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -b|--build) BUILD=1; shift ;;
    -c|--command) CMD="$2"; shift 2 ;;
  -g|--gpu-check) GPU_CHECK=1; shift ;;
  -s|--setup) SETUP=1; shift ;;
  -h|--help) show_help; exit 0 ;;
  -m|--mirror) MIRROR=1; shift ;;
  --work-volume) WORK_VOLUME="$2"; shift 2 ;;
  -n|--name) CONTAINER_NAME="$2"; shift 2 ;;
  -p|--progress) PROGRESS=1; shift ;;
    *) echo "Unknown option: $1" >&2; show_help; exit 1 ;;
  esac
done

# Detect engine
if command -v podman >/dev/null 2>&1; then
  ENGINE=podman
else
  echo "Error: neither podman nor docker found in PATH" >&2
  exit 1
fi

echo "[vLLM] Engine: $ENGINE  Image: $IMAGE_TAG  Container: $CONTAINER_NAME"

if [[ $BUILD -eq 1 ]]; then
  echo "[vLLM] Building image..."
  if ! $ENGINE build -f extras/Dockerfile -t "$IMAGE_TAG" .; then
    echo "[vLLM] Build failed" >&2
    exit 1
  fi
  echo "[vLLM] Build complete"
fi

# If container running, attach / exec
RUNNING=$($ENGINE ps --filter "name=${CONTAINER_NAME}" --format '{{.Names}}' 2>/dev/null || true)

if [[ "$RUNNING" == "$CONTAINER_NAME" ]]; then
  if [[ $GPU_CHECK -eq 1 ]]; then
    echo "[vLLM] GPU check (existing container)";
    $ENGINE exec "$CONTAINER_NAME" bash -lc 'source /home/vllmuser/venv/bin/activate 2>/dev/null || true; which nvidia-smi && nvidia-smi || true; python - <<PY\nimport torch, os\nprint("PyTorch:", getattr(torch, "__version__", "n/a"))\nprint("CUDA available:", torch.cuda.is_available())\nprint("Devices:", torch.cuda.device_count() if torch.cuda.is_available() else 0)\nif torch.cuda.is_available():\n    try: print("GPU 0:", torch.cuda.get_device_name(0))\n    except Exception as e: print("GPU name error:", e)\nPY'
    exit $?
  fi
  if [[ $SETUP -eq 1 ]]; then
    echo "[vLLM] Running dev setup in existing container"
    if [[ $MIRROR -eq 1 ]]; then
      exec $ENGINE exec "$CONTAINER_NAME" bash -lc 'export LOCAL_MIRROR=1; chmod +x ./extras/dev-setup.sh 2>/dev/null || true; ./extras/dev-setup.sh'
    else
      exec $ENGINE exec "$CONTAINER_NAME" bash -lc 'chmod +x ./extras/dev-setup.sh 2>/dev/null || true; ./extras/dev-setup.sh'
    fi
  fi
  if [[ -n "$CMD" ]]; then
    echo "[vLLM] Exec command in existing container"
    $ENGINE exec "$CONTAINER_NAME" bash -lc "source /home/vllmuser/venv/bin/activate 2>/dev/null || true; $CMD"
    exit $?
  fi
  read -r -p "Attach to running container ${CONTAINER_NAME}? [Y/n] " RESP
  if [[ -z "$RESP" || "$RESP" =~ ^[Yy]$ ]]; then
    exec $ENGINE exec -it "$CONTAINER_NAME" bash
  else
    exit 0
  fi
fi

# Ensure image exists if not building
if [[ $BUILD -ne 1 ]]; then
  if ! podman image exists "$IMAGE_TAG"; then
    echo "Image $IMAGE_TAG missing. Use --build." >&2; exit 1
  fi
fi

# Base run args (env baked into image; minimal extras)
RUN_ARGS=(run --rm --device=nvidia.com/gpu=all --security-opt=label=disable --shm-size 8g --name "$CONTAINER_NAME" -v "${SOURCE_DIR}:/workspace:Z" -w /workspace --user vllmuser --env ENGINE=podman)
# Prefer named volume for /opt/work if provided
if [[ -n "$WORK_VOLUME" ]]; then
  RUN_ARGS+=(-v "${WORK_VOLUME}:/opt/work:Z")
fi
# Allow configurable /tmp tmpfs size (default 0=disabled to avoid small tmpfs). Set VLLM_TMPFS_TMP_SIZE to e.g. 64g to enable.
TMPFS_SIZE="${VLLM_TMPFS_TMP_SIZE:-0}"
if [[ -n "$TMPFS_SIZE" && "$TMPFS_SIZE" != "0" ]]; then
  RUN_ARGS+=(--tmpfs "/tmp:size=${TMPFS_SIZE}")
fi

# Ensure sane NVIDIA env defaults inside container to avoid 'void' and missing caps
RUN_ARGS+=(--env "NVIDIA_VISIBLE_DEVICES=${NVIDIA_VISIBLE_DEVICES:-all}" \
          --env "NVIDIA_DRIVER_CAPABILITIES=${NVIDIA_DRIVER_CAPABILITIES:-compute,utility}" \
          --env "NVIDIA_REQUIRE_CUDA=")

if [[ $GPU_CHECK -eq 1 ]]; then
  GPU_SCRIPT=$'echo "=== GPU Check ==="; which nvidia-smi && nvidia-smi || echo "nvidia-smi unavailable"; echo "--- /dev/nvidia* ---"; ls -l /dev/nvidia* 2>/dev/null || echo "no /dev/nvidia* nodes"; echo "--- Environment (NVIDIA_*) ---"; env | grep -E "^NVIDIA_" || echo "no NVIDIA_* env vars"; if [ "$NVIDIA_VISIBLE_DEVICES" = "void" ]; then echo "WARN: NVIDIA_VISIBLE_DEVICES=void (no GPU mapped)"; fi; echo "--- LD_LIBRARY_PATH ---"; echo "LD_LIBRARY_PATH=$LD_LIBRARY_PATH"; source /home/vllmuser/venv/bin/activate 2>/dev/null || true; python - <<PY\nimport json,torch,os\nout={\n \'torch_version\':getattr(torch,\'__version__\',\'n/a\'),\n \'torch_cuda_version\':getattr(getattr(torch,\'version\',None),\'cuda\',\'n/a\'),\n \'cuda_available\':torch.cuda.is_available(),\n \'ld_library_path\':os.environ.get(\'LD_LIBRARY_PATH\')\n}\ntry: out[\'device_count\']=torch.cuda.device_count()\nexcept Exception as e: out[\'device_count_error\']=str(e)\nif out[\'cuda_available\'] and out.get(\'device_count\',0)>0:\n    try:\n        cap=torch.cuda.get_device_capability(0)\n        out[\'device_0\']={\'name\':torch.cuda.get_device_name(0),\'capability\':f"sm_{cap[0]}{cap[1]}"}\n    except Exception as e:\n        out[\'device_0_error\']=str(e)\nelse:\n    out[\'diagnostics\']=[\'Missing /dev/nvidia* or podman machine without GPU passthrough\']\nprint(json.dumps(out,indent=2))\nPY'
  RUN_ARGS+=("$IMAGE_TAG" bash -lc "$GPU_SCRIPT")
elif [[ $SETUP -eq 1 ]]; then
  if [[ $MIRROR -eq 1 ]]; then
    RUN_ARGS+=(--env LOCAL_MIRROR=1)
  fi
  if [[ $PROGRESS -eq 1 ]]; then
    RUN_ARGS+=(--env PROGRESS_WATCH=1)
    RUN_ARGS+=("-it" "$IMAGE_TAG" bash -lc 'chmod +x ./extras/dev-setup.sh 2>/dev/null || true; ./extras/dev-setup.sh')
  else
    RUN_ARGS+=("$IMAGE_TAG" bash -lc 'chmod +x ./extras/dev-setup.sh 2>/dev/null || true; ./extras/dev-setup.sh')
  fi
elif [[ -n "$CMD" ]]; then
  RUN_ARGS+=("$IMAGE_TAG" bash -lc "source /home/vllmuser/venv/bin/activate 2>/dev/null || true; $CMD")
else
  RUN_ARGS+=("-it" "$IMAGE_TAG" bash)
  echo "[vLLM] Interactive shell. Helpful inside container:"
  echo "  ./extras/dev-setup.sh            # Build/install editable vLLM"
  echo "  python -c 'import torch;print(torch.cuda.is_available())'"
  echo "  python -c 'import vllm'"
fi

echo "[vLLM] Command: $ENGINE ${RUN_ARGS[*]}"
exec $ENGINE "${RUN_ARGS[@]}"
