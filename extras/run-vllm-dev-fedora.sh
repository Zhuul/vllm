#!/bin/bash
# run-vllm-dev-fedora.sh
# Launch a vLLM development container using UBI9 + CUDA base with Podman
# This script sets up a development environment

set -e

# === Configuration ===
NETWORK="${VLLM_PODMAN_NETWORK:-llm-net}"  # Use env var or default to llm-net
CONTAINER_NAME="vllm-dev-fedora"
PORT_MAPPING_API="127.0.0.1:8000:8000"
PORT_MAPPING_SSH="127.0.0.1:2222:22"
# GPU configuration for Linux/WSL2 - try different methods
GPUS=("--device" "nvidia.com/gpu=all" "--security-opt" "label=disable")  # WSL2 + Podman method
# Alternative methods (uncomment as needed):
# GPUS=("--device" "nvidia.com/gpu=all")  # Standard Podman method  
# GPUS=("--gpus" "all")  # Docker-style method

# Adjust these paths to your environment
VLLM_SOURCE_PATH="${HOME}/projects/vllm"  # Your fork path
MODEL_CACHE_VOLUME="${HOME}/.cache/huggingface"
VLLM_CACHE_VOLUME="${HOME}/.cache/vllm"

# Environment variables
ENV_PYTORCH_CUDA="PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True"
ENV_TOKEN="HUGGINGFACE_HUB_TOKEN=${HUGGINGFACE_HUB_TOKEN:-your_token_here}"
ENV_VLLM="VLLM_USE_V1=1"
ENV_DISABLE_FLASH="VLLM_DISABLE_FLASH_ATTN=1"

# Build settings
IMAGE_NAME="vllm-dev-fedora:latest"
DOCKERFILE_PATH="extras/Dockerfile"

# === Functions ===
print_section() {
    echo
    echo "=== $1 ==="
}

check_podman() {
    if ! command -v podman &> /dev/null; then
        echo "Error: Podman is not available. Please install podman."
        exit 1
    fi
}

create_dir_if_missing() {
    local path="$1"
    local description="$2"
    
    if [[ ! -d "$path" ]]; then
        echo "Warning: $description path does not exist: $path"
        echo "Creating directory..."
        mkdir -p "$path"
    fi
}

network_exists() {
    podman network ls --format "{{.Name}}" | grep -q "^$1$"
}

test_gpu_available() {
    echo "Testing GPU availability..."
    if podman run --rm "${GPUS[@]}" nvidia/cuda:12.9.1-base-ubi9 nvidia-smi >/dev/null 2>&1; then
        echo "✅ GPU is available and working!"
        return 0
    else
        echo "⚠️  GPU test failed. GPU might not be available."
        echo "Container will run in CPU-only mode."
        return 1
    fi
}

# === Main Script ===
print_section "vLLM Development Environment Setup (UBI9 + CUDA)"

echo "Using Podman network: $NETWORK"

# Check prerequisites
check_podman

# Validate and create paths
create_dir_if_missing "$VLLM_SOURCE_PATH" "vLLM source"
create_dir_if_missing "$MODEL_CACHE_VOLUME" "Model cache"
create_dir_if_missing "$VLLM_CACHE_VOLUME" "vLLM cache"

# Check if we're in the vLLM repository root
if [[ ! -f "pyproject.toml" ]]; then
    echo "Warning: Not in vLLM repository root. Please run from vLLM root directory."
fi

print_section "Network Configuration"

# Check if network exists, create if it doesn't
if network_exists "$NETWORK"; then
    echo "Network '$NETWORK' already exists, using it."
else
    echo "Creating network '$NETWORK'..."
    if podman network create "$NETWORK" 2>/dev/null; then
        echo "Network '$NETWORK' created successfully."
    else
        echo "Warning: Could not create network '$NETWORK'. Will use default networking."
        NETWORK=""  # Use default networking
    fi
fi

print_section "GPU Configuration"

# Test GPU availability (optional - for diagnostics)
test_gpu_available || true

print_section "Building Development Container"

# Build the container image
echo "Building vLLM development image..."
BUILD_COMMAND="podman build -f $DOCKERFILE_PATH -t $IMAGE_NAME ."
echo "Build command: $BUILD_COMMAND"
eval "$BUILD_COMMAND"

print_section "Starting Development Container"

# Remove existing container if it exists
echo "Removing existing container if present..."
podman rm -f "$CONTAINER_NAME" 2>/dev/null || true

# Inner command for container setup
INNER_COMMAND='whoami && \
dnf install -y openssh-server sudo && \
systemctl enable sshd && \
mkdir -p /var/run/sshd && \
echo "PermitRootLogin yes" >> /etc/ssh/sshd_config && \
echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config && \
usermod -aG wheel vllmuser && \
echo "vllmuser:vllmdev" | chpasswd && \
/usr/sbin/sshd -D & \
runuser -l vllmuser -c "cd /workspace && \
source /home/vllmuser/venv/bin/activate && \
echo \"Python Virtual environment activated: \$VIRTUAL_ENV\" && \
echo \"Setting up vLLM development environment...\" && \
pip install -e . && \
python -c \"import vllm; print(\\\"vLLM version:\\\", vllm.__version__)\" && \
echo \"Development environment ready!\" && \
exec /bin/bash"'

# Build podman run arguments
PODMAN_ARGS=(
    "run" "-it"
    "--name" "$CONTAINER_NAME"
    "-p" "$PORT_MAPPING_API"
    "-p" "$PORT_MAPPING_SSH"
    "${GPUS[@]}"
    "-v" "${VLLM_SOURCE_PATH}:/workspace:Z"
    "-v" "${MODEL_CACHE_VOLUME}:/home/vllmuser/.cache/huggingface:Z"
    "-v" "${VLLM_CACHE_VOLUME}:/home/vllmuser/.cache/vllm:Z"
    "-e" "$ENV_PYTORCH_CUDA"
    "-e" "$ENV_TOKEN"
    "-e" "$ENV_VLLM"
    "-e" "$ENV_DISABLE_FLASH"
    "--ipc=host"
    "--entrypoint" "/bin/bash"
)

# Add network parameter only if network is specified
if [[ -n "$NETWORK" ]]; then
    PODMAN_ARGS=("${PODMAN_ARGS[@]:0:2}" "--network" "$NETWORK" "${PODMAN_ARGS[@]:2}")
fi

# Add image and command
PODMAN_ARGS+=("$IMAGE_NAME" "-c" "$INNER_COMMAND")

# Start the container
podman "${PODMAN_ARGS[@]}"

print_section "Container Started"
echo "Development environment is ready!"
echo "- vLLM API will be available at: http://localhost:8000"
echo "- SSH access available at: localhost:2222"
echo "- Container name: $CONTAINER_NAME"
echo "- Network: $NETWORK"
echo
echo "To reconnect to the container later:"
echo "  podman start -ai $CONTAINER_NAME"