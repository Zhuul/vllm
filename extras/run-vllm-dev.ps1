#!/usr/bin/env pwsh

# Script to run vLLM development container with GPU support
# Uses vLLM's own requirements for automatic dependency management

param(
    [switch]$Build,
    [switch]$Interactive,
    [string]$Command = "",
    [switch]$Help
)

# Default to interactive mode unless Command is specified
if (!$Interactive -and [string]::IsNullOrEmpty($Command)) {
    $Interactive = $true
}

if ($Help) {
    Write-Host "Usage: run-vllm-dev.ps1 [-Build] [-Interactive] [-Command <cmd>] [-Help]"
    Write-Host ""
    Write-Host "Options:"
    Write-Host "  -Build        Build the container before running"
    Write-Host "  -Interactive  Run in interactive mode (default)"
    Write-Host "  -Command      Run specific command instead of interactive shell"
    Write-Host "  -Help         Show this help message"
    Write-Host ""
    Write-Host "Examples:"
    Write-Host "  .\run-vllm-dev.ps1 -Build                    # Build and run container"
    Write-Host "  .\run-vllm-dev.ps1                           # Run container interactively"
    Write-Host "  .\run-vllm-dev.ps1 -Command 'nvidia-smi'     # Run nvidia-smi"
    Write-Host ""
    Write-Host "Manual container access:"
    Write-Host "  podman exec -it vllm-dev bash               # Connect to running container"
    Write-Host "  podman run --rm -it --device=nvidia.com/gpu=all --name=vllm-dev -v `"`${PWD}:/workspace:Z`" vllm-dev:latest"
    exit 0
}

$ContainerName = "vllm-dev"
$ImageTag = "vllm-dev:latest"
$SourceDir = $PWD

Write-Host "🐋 vLLM Development Container" -ForegroundColor Green
Write-Host "Source directory: $SourceDir"

if ($Build) {
    Write-Host "🔨 Building container..." -ForegroundColor Yellow
    podman build -f extras/Dockerfile -t $ImageTag .
    if ($LASTEXITCODE -ne 0) {
        Write-Host "❌ Build failed!" -ForegroundColor Red
        exit 1
    }
    Write-Host "✅ Build completed successfully!" -ForegroundColor Green
}

# Check if container is already running
$runningContainer = podman ps --filter "name=$ContainerName" --format "{{.Names}}" 2>$null
if ($runningContainer -eq $ContainerName) {
    Write-Host "ℹ️  Container '$ContainerName' is already running" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "To connect to the running container:" -ForegroundColor Yellow
    Write-Host "  podman exec -it $ContainerName bash" -ForegroundColor White
    Write-Host ""
    Write-Host "To stop the running container:" -ForegroundColor Yellow
    Write-Host "  podman stop $ContainerName" -ForegroundColor White
    Write-Host ""
    
    if (![string]::IsNullOrEmpty($Command)) {
        Write-Host "🚀 Running command in existing container: $Command" -ForegroundColor Green
        & podman exec $ContainerName bash -c "source /home/vllmuser/venv/bin/activate && $Command"
        exit $LASTEXITCODE
    } else {
        $response = Read-Host "Connect to running container? [Y/n]"
        if ($response -eq "" -or $response -eq "Y" -or $response -eq "y") {
            & podman exec -it $ContainerName bash
            exit $LASTEXITCODE
        } else {
            Write-Host "Container remains running. Use the commands above to interact with it." -ForegroundColor Gray
            exit 0
        }
    }
}

# Check if image exists
podman image exists $ImageTag
if ($LASTEXITCODE -ne 0) {
    Write-Host "❌ Image $ImageTag not found. Run with -Build to create it." -ForegroundColor Red
    exit 1
}

# Container run arguments
$RunArgs = @(
    "run", "--rm"
    "--device=nvidia.com/gpu=all"
    "--name=$ContainerName"
    "-v", "${SourceDir}:/workspace:Z"
    "-w", "/workspace"
    "--user", "vllmuser"
    "-e", "NVIDIA_VISIBLE_DEVICES=all"
    "-e", "CUDA_VISIBLE_DEVICES=0"
)

if ($Interactive -and [string]::IsNullOrEmpty($Command)) {
    $RunArgs += @("-it", $ImageTag, "bash")
    Write-Host "🚀 Starting interactive container..." -ForegroundColor Green
    Write-Host ""
    Write-Host "Once started, you'll be inside the container. Useful commands:" -ForegroundColor Cyan
    Write-Host "  python /workspace/extras/final_environment_test.py    # Test environment" -ForegroundColor White
    Write-Host "  ./extras/dev-setup.sh                               # Setup vLLM for development" -ForegroundColor White
    Write-Host "  python -c 'import torch; print(torch.__version__)'   # Check PyTorch version" -ForegroundColor White
    Write-Host ""
} elseif (![string]::IsNullOrEmpty($Command)) {
    $RunArgs += @($ImageTag, "bash", "-c", "source /home/vllmuser/venv/bin/activate && $Command")
    Write-Host "🚀 Running command: $Command" -ForegroundColor Green
} else {
    $RunArgs += @($ImageTag)
    Write-Host "🚀 Starting container..." -ForegroundColor Green
}

# Run the container
Write-Host "Running: podman $($RunArgs -join ' ')"
& podman @RunArgs

# Show connection info after container exits
if ($LASTEXITCODE -eq 0 -and $Interactive) {
    Write-Host ""
    Write-Host "Container exited successfully." -ForegroundColor Green
    Write-Host "To reconnect, run: .\extras\run-vllm-dev.ps1" -ForegroundColor Cyan
}
