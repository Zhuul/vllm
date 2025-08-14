#!/usr/bin/env bash
# Unified lightweight vLLM dev container launcher (bash)
# - Auto-detects container engine: podman (preferred) else docker
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
CMD=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -b|--build) BUILD=1; shift ;;
    -c|--command) CMD="$2"; shift 2 ;;
    -g|--gpu-check) GPU_CHECK=1; shift ;;
    -h|--help) show_help; exit 0 ;;
    -n|--name) CONTAINER_NAME="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; show_help; exit 1 ;;
  esac
done

# Detect engine
if command -v podman >/dev/null 2>&1; then
  ENGINE=podman
elif command -v docker >/dev/null 2>&1; then
  ENGINE=docker
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
if [[ "$ENGINE" == "docker" ]]; then
  RUNNING=$($ENGINE ps --filter "name=${CONTAINER_NAME}" --format '{{.Names}}' 2>/dev/null || true)
else
  RUNNING=$($ENGINE ps --filter "name=${CONTAINER_NAME}" --format '{{.Names}}' 2>/dev/null || true)
fi

if [[ "$RUNNING" == "$CONTAINER_NAME" ]]; then
  if [[ $GPU_CHECK -eq 1 ]]; then
    echo "[vLLM] GPU check (existing container)";
    $ENGINE exec "$CONTAINER_NAME" bash -lc 'source /home/vllmuser/venv/bin/activate 2>/dev/null || true; which nvidia-smi && nvidia-smi || true; python - <<PY\nimport torch, os\nprint("PyTorch:", getattr(torch, "__version__", "n/a"))\nprint("CUDA available:", torch.cuda.is_available())\nprint("Devices:", torch.cuda.device_count() if torch.cuda.is_available() else 0)\nif torch.cuda.is_available():\n    try: print("GPU 0:", torch.cuda.get_device_name(0))\n    except Exception as e: print("GPU name error:", e)\nPY'
    exit $?
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
  if [[ "$ENGINE" == "docker" ]]; then
    if ! docker image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
      echo "Image $IMAGE_TAG missing. Use --build." >&2; exit 1
    fi
  else
    if ! podman image exists "$IMAGE_TAG"; then
      echo "Image $IMAGE_TAG missing. Use --build." >&2; exit 1
    fi
  fi
fi

# Base run args (env baked into image; minimal extras)
if [[ "$ENGINE" == "docker" ]]; then
  RUN_ARGS=(run --rm --gpus all --name "$CONTAINER_NAME" -v "${SOURCE_DIR}:/workspace" -w /workspace --user vllmuser)
else
  RUN_ARGS=(run --rm --device=nvidia.com/gpu=all --security-opt=label=disable --name "$CONTAINER_NAME" -v "${SOURCE_DIR}:/workspace:Z" -w /workspace --user vllmuser)
fi

if [[ $GPU_CHECK -eq 1 ]]; then
  GPU_SCRIPT=$'echo "=== GPU Check ==="; which nvidia-smi && nvidia-smi || true; source /home/vllmuser/venv/bin/activate 2>/dev/null || true; python - <<PY\nimport torch, os\nprint("PyTorch:", getattr(torch, "__version__", "n/a"))\nprint("CUDA available:", torch.cuda.is_available())\nprint("Devices:", torch.cuda.device_count() if torch.cuda.is_available() else 0)\nif torch.cuda.is_available():\n    try: print("GPU 0:", torch.cuda.get_device_name(0))\n    except Exception as e: print("GPU name error:", e)\nPY'
  RUN_ARGS+=("$IMAGE_TAG" bash -lc "$GPU_SCRIPT")
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
