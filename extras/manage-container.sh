#!/bin/bash
# manage-container.sh
# Helper script for managing the vLLM development container

CONTAINER_NAME="vllm-dev-fedora"
IMAGE_NAME="vllm-dev-fedora:latest"
NETWORK="${VLLM_PODMAN_NETWORK:-llm-net}"  # Use env var or default to llm-net

print_usage() {
    echo "Usage: $0 {start|stop|restart|remove|rebuild|logs|exec|status|network|venv|gpu|wsl-gpu|setup-gpu}"
    echo
    echo "Commands:"
    echo "  start      - Start the container"
    echo "  stop       - Stop the container"
    echo "  restart    - Restart the container"
    echo "  remove     - Remove the container (keeps image)"
    echo "  rebuild    - Remove and rebuild the container image"
    echo "  logs       - Show container logs"
    echo "  exec       - Execute bash in running container"
    echo "  status     - Show container status"
    echo "  network    - Show network information"
    echo "  venv       - Check virtual environment status in container"
    echo "  gpu        - Test GPU availability"
    echo "  wsl-gpu    - Comprehensive WSL2 + GPU diagnostics"
    echo "  setup-gpu  - Install NVIDIA Container Toolkit for WSL2"
    echo
    echo "Environment Variables:"
    echo "  VLLM_PODMAN_NETWORK - Override default network (current: $NETWORK)"
}

network_exists() {
    podman network ls --format "{{.Name}}" | grep -q "^$1$"
}

container_running() {
    podman ps --format "{{.Names}}" | grep -q "^$CONTAINER_NAME$"
}

test_gpu() {
    echo "Testing GPU availability..."
    if podman run --rm --device nvidia.com/gpu=all nvidia/cuda:12.9.1-base-ubi9 nvidia-smi 2>/dev/null; then
        echo "✅ GPU is working correctly!"
        return 0
    else
        echo "❌ GPU test failed or not available"
        return 1
    fi
}

check_venv_in_container() {
    if ! container_running; then
        echo "❌ Container '$CONTAINER_NAME' is not running"
        echo "💡 Start it with: $0 start"
        return 1
    fi
    
    echo "Checking virtual environment in container..."
    podman exec "$CONTAINER_NAME" /home/vllmuser/activate_venv.sh 2>/dev/null || \
        podman exec "$CONTAINER_NAME" bash -c "source /home/vllmuser/venv/bin/activate && echo 'Virtual environment: \$VIRTUAL_ENV' && python --version"
}

case "$1" in
    start)
        echo "Starting container $CONTAINER_NAME..."
        podman start -ai "$CONTAINER_NAME"
        ;;
    stop)
        echo "Stopping container $CONTAINER_NAME..."
        podman stop "$CONTAINER_NAME"
        ;;
    restart)
        echo "Restarting container $CONTAINER_NAME..."
        podman restart "$CONTAINER_NAME"
        ;;
    remove)
        echo "Removing container $CONTAINER_NAME..."
        podman rm -f "$CONTAINER_NAME"
        ;;
    rebuild)
        echo "Rebuilding container image..."
        podman rm -f "$CONTAINER_NAME" 2>/dev/null || true
        podman rmi "$IMAGE_NAME" 2>/dev/null || true
        ./extras/run-vllm-dev-fedora.sh
        ;;
    logs)
        echo "Showing logs for $CONTAINER_NAME..."
        podman logs "$CONTAINER_NAME"
        ;;
    exec)
        echo "Executing bash in $CONTAINER_NAME..."
        if container_running; then
            podman exec -it "$CONTAINER_NAME" /bin/bash
        else
            echo "❌ Container is not running. Start it first with: $0 start"
        fi
        ;;
    status)
        echo "Container status:"
        podman ps -a --filter name="$CONTAINER_NAME"
        echo
        echo "Network: $NETWORK"
        if network_exists "$NETWORK"; then
            echo "Network exists: Yes"
        else
            echo "Network exists: No"
        fi
        echo
        if container_running; then
            echo "🟢 Container is running"
        else
            echo "🔴 Container is stopped"
        fi
        ;;
    network)
        echo "Network Configuration:"
        echo "- Current network: $NETWORK"
        echo "- Environment variable: VLLM_PODMAN_NETWORK=${VLLM_PODMAN_NETWORK:-<not set>}"
        echo
        if network_exists "$NETWORK"; then
            echo "Network '$NETWORK' details:"
            podman network inspect "$NETWORK"
        else
            echo "Network '$NETWORK' does not exist."
            echo "It will be created when running the container."
        fi
        ;;
    venv)
        check_venv_in_container
        ;;
    gpu)
        test_gpu
        ;;
    wsl-gpu)
        echo "Running comprehensive WSL2 + GPU diagnostics..."
        if [ -f "extras/check-wsl-gpu.sh" ]; then
            bash extras/check-wsl-gpu.sh
        else
            echo "❌ Diagnostic script not found: extras/check-wsl-gpu.sh"
        fi
        ;;
    setup-gpu)
        echo "Setting up NVIDIA Container Toolkit for WSL2..."
        if [ -f "extras/setup-wsl-gpu.sh" ]; then
            bash extras/setup-wsl-gpu.sh
        else
            echo "❌ Setup script not found: extras/setup-wsl-gpu.sh"
        fi
        ;;
    *)
        print_usage
        exit 1
        ;;
esac