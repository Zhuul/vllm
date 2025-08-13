#!/usr/bin/env pwsh

# Docker-based script to run vLLM development container with GPU support
# Uses Docker's native --gpus flag which is more reliable than Podman CDI

param(
    [switch]$Build,
    [switch]$Interactive,
    [string]$Command = "",
    [switch]$Help,
    [switch]$GPUCheck
)

# Default to interactive mode unless Command is specified
if (!$Interactive -and [string]::IsNullOrEmpty($Command) -and !$GPUCheck) {
    $Interactive = $true
}

if ($Help) {
    Write-Host "Usage: run-vllm-dev-docker.ps1 [-Build] [-Interactive] [-Command <cmd>] [-GPUCheck] [-Help]"
    Write-Host ""
    Write-Host "Docker-based vLLM container launcher with native GPU support"
    Write-Host ""
    Write-Host "Options:"
    Write-Host "  -Build        Build the container before running"
    Write-Host "  -Interactive  Run in interactive mode (default)"
    Write-Host "  -Command      Run specific command instead of interactive shell"
    Write-Host "  -GPUCheck     Run GPU diagnostics"
    Write-Host "  -Help         Show this help message"
    Write-Host ""
    Write-Host "Examples:"
    Write-Host "  .\run-vllm-dev-docker.ps1 -Build                    # Build and run container"
    Write-Host "  .\run-vllm-dev-docker.ps1                           # Run container interactively"
    Write-Host "  .\run-vllm-dev-docker.ps1 -GPUCheck                 # Check GPU setup"
    Write-Host ""
    exit 0
}

$ContainerName = "vllm-dev"
$ImageTag = "vllm-dev:latest"
$SourceDir = $PWD

Write-Host "🐋 vLLM Development Container (Docker + Native GPU)" -ForegroundColor Green
Write-Host "Source directory: $SourceDir"

# Check if Docker is available
try {
    $null = docker --version
    Write-Host "✅ Docker detected" -ForegroundColor Green
} catch {
    Write-Host "❌ Docker not found. Please install Docker Desktop with WSL2 backend." -ForegroundColor Red
    Write-Host "Download from: https://www.docker.com/products/docker-desktop/" -ForegroundColor Yellow
    exit 1
}

# Check if NVIDIA Docker runtime is available
try {
    $dockerInfo = docker info 2>$null | Select-String "nvidia"
    if ($dockerInfo) {
        Write-Host "✅ NVIDIA Docker runtime detected" -ForegroundColor Green
    } else {
        Write-Host "⚠️  NVIDIA Docker runtime not detected - will try --gpus flag anyway" -ForegroundColor Yellow
    }
} catch {
    Write-Host "⚠️  Could not check Docker info" -ForegroundColor Yellow
}

if ($Build) {
    Write-Host "🔨 Building container with Docker..." -ForegroundColor Yellow
    docker build -f extras/Dockerfile -t $ImageTag .
    if ($LASTEXITCODE -ne 0) {
        Write-Host "❌ Build failed!" -ForegroundColor Red
        exit 1
    }
    Write-Host "✅ Build completed successfully!" -ForegroundColor Green
}

# Check if container is already running
$runningContainer = docker ps --filter "name=$ContainerName" --format "{{.Names}}" 2>$null
if ($runningContainer -eq $ContainerName) {
    Write-Host "ℹ️  Container '$ContainerName' is already running" -ForegroundColor Cyan
    
    if ($GPUCheck) {
        Write-Host "🔍 Running GPU check in existing container..." -ForegroundColor Yellow
        docker exec $ContainerName bash -c "source /home/vllmuser/venv/bin/activate && python -c 'import torch; print(f`"PyTorch: {torch.__version__}`"); print(f`"CUDA available: {torch.cuda.is_available()}`")'"
        docker exec $ContainerName nvidia-smi
        exit $LASTEXITCODE
    }
    
    if (![string]::IsNullOrEmpty($Command)) {
        Write-Host "🚀 Running command in existing container: $Command" -ForegroundColor Green
        & docker exec $ContainerName bash -c "source /home/vllmuser/venv/bin/activate && $Command"
        exit $LASTEXITCODE
    } else {
        $response = Read-Host "Connect to running container? [Y/n]"
        if ($response -eq "" -or $response -eq "Y" -or $response -eq "y") {
            & docker exec -it $ContainerName bash
            exit $LASTEXITCODE
        } else {
            Write-Host "Container remains running." -ForegroundColor Gray
            exit 0
        }
    }
}

# Check if image exists
$imageExists = docker images --format "{{.Repository}}:{{.Tag}}" | Select-String "^$ImageTag$"
if (!$imageExists) {
    Write-Host "❌ Image $ImageTag not found. Run with -Build to create it." -ForegroundColor Red
    exit 1
}

# Container run arguments with Docker's native GPU support
$RunArgs = @(
    "run", "--rm"
    "--gpus", "all"
    "--name=$ContainerName"
    "-v", "${SourceDir}:/workspace"
    "-w", "/workspace"
    "--user", "vllmuser"
    "-e", "NVIDIA_VISIBLE_DEVICES=all"
    "-e", "CUDA_VISIBLE_DEVICES=0"
)

if ($GPUCheck) {
    $RunArgs += @($ImageTag, "bash", "-c", @"
echo '=== Docker Native GPU Check ==='
echo 'NVIDIA Driver:'
nvidia-smi || echo 'nvidia-smi failed'
echo ''
echo 'CUDA Environment:'
echo "CUDA_HOME: `$CUDA_HOME"
echo "LD_LIBRARY_PATH: `$LD_LIBRARY_PATH"
echo ''
echo 'PyTorch Check:'
source /home/vllmuser/venv/bin/activate
python -c "import torch; print(f'PyTorch: {torch.__version__}'); print(f'CUDA available: {torch.cuda.is_available()}'); print(f'CUDA devices: {torch.cuda.device_count()}')"
"@)
    Write-Host "🔍 Running Docker GPU diagnostics..." -ForegroundColor Yellow
} elseif ($Interactive -and [string]::IsNullOrEmpty($Command)) {
    $RunArgs += @("-it", $ImageTag, "bash")
    Write-Host "🚀 Starting interactive container with Docker native GPU support..." -ForegroundColor Green
    Write-Host ""
    Write-Host "Docker optimizations:" -ForegroundColor Cyan
    Write-Host "  ✅ Native --gpus all support" -ForegroundColor White
    Write-Host "  ✅ Direct GPU device access" -ForegroundColor White  
    Write-Host "  ✅ No CDI complexity" -ForegroundColor White
    Write-Host ""
    Write-Host "Once started, useful commands:" -ForegroundColor Cyan
    Write-Host "  python -c 'import torch; print(torch.cuda.is_available())'  # Test CUDA" -ForegroundColor White
    Write-Host "  nvidia-smi                                                  # Check GPU" -ForegroundColor White
    Write-Host "  ./extras/dev-setup.sh                                      # Setup vLLM" -ForegroundColor White
    Write-Host ""
} elseif (![string]::IsNullOrEmpty($Command)) {
    $RunArgs += @($ImageTag, "bash", "-c", "source /home/vllmuser/venv/bin/activate && $Command")
    Write-Host "🚀 Running command with Docker native GPU support: $Command" -ForegroundColor Green
} else {
    $RunArgs += @($ImageTag)
    Write-Host "🚀 Starting container with Docker native GPU support..." -ForegroundColor Green
}

# Show the command being run (for debugging)
Write-Host ""
Write-Host "Command: docker $($RunArgs -join ' ')" -ForegroundColor Gray
Write-Host ""

# Run the container
& docker @RunArgs

# Show results
if ($LASTEXITCODE -eq 0) {
    if ($GPUCheck) {
        Write-Host ""
        Write-Host "✅ GPU check completed successfully" -ForegroundColor Green
    } elseif ($Interactive) {
        Write-Host ""
        Write-Host "Container exited successfully." -ForegroundColor Green
        Write-Host "To reconnect: .\extras\run-vllm-dev-docker.ps1" -ForegroundColor Cyan
    }
} else {
    Write-Host ""
    Write-Host "❌ Container command failed with exit code: $LASTEXITCODE" -ForegroundColor Red
    Write-Host "Try installing Docker Desktop with NVIDIA GPU support" -ForegroundColor Yellow
}
