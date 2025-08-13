#!/usr/bin/env pwsh

# Enhanced Podman launcher with explicit WSL2 NVIDIA library mounting
# Forces correct libcuda.so library selection for PyTorch

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
    Write-Host "Usage: run-vllm-dev-podman-fixed.ps1 [-Build] [-Interactive] [-Command <cmd>] [-GPUCheck] [-Help]"
    Write-Host ""
    Write-Host "Enhanced Podman launcher with explicit WSL2 NVIDIA library mounting"
    Write-Host ""
    Write-Host "Options:"
    Write-Host "  -Build        Build the container before running"
    Write-Host "  -Interactive  Run in interactive mode (default)"
    Write-Host "  -Command      Run specific command instead of interactive shell"
    Write-Host "  -GPUCheck     Run GPU diagnostics"
    Write-Host "  -Help         Show this help message"
    Write-Host ""
    exit 0
}

$ContainerName = "vllm-dev"
$ImageTag = "vllm-dev:latest"
$SourceDir = $PWD

Write-Host "🐋 vLLM Development Container (Podman + Fixed GPU)" -ForegroundColor Green
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
    
    if ($GPUCheck) {
        Write-Host "🔍 Running GPU check in existing container..." -ForegroundColor Yellow
        podman exec $ContainerName bash -c "source /home/vllmuser/venv/bin/activate && python -c 'import torch; print(f`"PyTorch: {torch.__version__}`"); print(f`"CUDA available: {torch.cuda.is_available()}`")'"
        podman exec $ContainerName nvidia-smi
        exit $LASTEXITCODE
    }
    
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
            Write-Host "Container remains running." -ForegroundColor Gray
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

# Enhanced GPU and library mounting for WSL2
$RunArgs = @(
    "run", "--rm"
    "--device=nvidia.com/gpu=all"
    "--security-opt=label=disable"
    "--name=$ContainerName"
    "-v", "${SourceDir}:/workspace:Z"
    "-w", "/workspace"
    "--user", "vllmuser"
)

# Enhanced CUDA environment variables
$CudaEnvVars = @(
    "-e", "NVIDIA_VISIBLE_DEVICES=all"
    "-e", "NVIDIA_DRIVER_CAPABILITIES=compute,utility"
    "-e", "CUDA_VISIBLE_DEVICES=0"
    "-e", "CUDA_HOME=/usr/local/cuda"
    "-e", "PATH=/usr/local/cuda/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    # Force the WSL driver libcuda.so to be found first
    "-e", "LD_LIBRARY_PATH=/usr/lib/wsl/drivers/nv_dispi.inf_amd64_fe5f369669db2f36:/usr/lib/wsl/drivers:/usr/lib/wsl/lib:/usr/lib/x86_64-linux-gnu:/usr/local/cuda/lib64:/usr/local/cuda/lib"
    "-e", "TORCH_CUDA_ARCH_LIST=6.0;6.1;7.0;7.5;8.0;8.6;8.9;9.0+PTX"
    # Disable stub library by setting priority
    "-e", "CUDA_DRIVER_LIBRARY_PATH=/usr/lib/wsl/drivers/nv_dispi.inf_amd64_fe5f369669db2f36/libcuda.so.1"
)

# Add CUDA environment variables
$RunArgs += $CudaEnvVars

if ($GPUCheck) {
    $RunArgs += @($ImageTag, "bash", "-c", @"
echo '=== Enhanced Podman GPU Check ==='
echo 'NVIDIA Driver:'
nvidia-smi || echo 'nvidia-smi failed'
echo ''
echo 'CUDA Environment:'
echo "CUDA_HOME: `$CUDA_HOME"
echo "LD_LIBRARY_PATH: `$LD_LIBRARY_PATH"
echo "CUDA_DRIVER_LIBRARY_PATH: `$CUDA_DRIVER_LIBRARY_PATH"
echo ''
echo 'Available libcuda.so files:'
find /usr -name "libcuda.so*" 2>/dev/null | head -5
echo ''
echo 'Library loading test:'
ldd /usr/local/cuda/lib64/libcudart.so.* 2>/dev/null | grep cuda || echo 'cudart check failed'
echo ''
echo 'PyTorch Check:'
source /home/vllmuser/venv/bin/activate
python -c "
import os
print('Environment:')
print('  LD_LIBRARY_PATH:', os.environ.get('LD_LIBRARY_PATH', 'not set'))
print('  CUDA_DRIVER_LIBRARY_PATH:', os.environ.get('CUDA_DRIVER_LIBRARY_PATH', 'not set'))
print('')
import torch
print(f'PyTorch: {torch.__version__}')
print(f'CUDA available: {torch.cuda.is_available()}')
if torch.cuda.is_available():
    print(f'CUDA devices: {torch.cuda.device_count()}')
    try:
        print(f'GPU: {torch.cuda.get_device_name(0)}')
    except:
        print('GPU name unavailable')
else:
    print('Debugging CUDA unavailability...')
    try:
        torch.cuda._lazy_init()
    except Exception as e:
        print(f'CUDA init error: {e}')
"
"@)
    Write-Host "🔍 Running enhanced GPU diagnostics..." -ForegroundColor Yellow
} elseif ($Interactive -and [string]::IsNullOrEmpty($Command)) {
    $RunArgs += @("-it", $ImageTag, "bash")
    Write-Host "🚀 Starting interactive container with enhanced GPU support..." -ForegroundColor Green
    Write-Host ""
    Write-Host "Enhanced optimizations:" -ForegroundColor Cyan
    Write-Host "  ✅ Explicit WSL driver library path priority" -ForegroundColor White
    Write-Host "  ✅ CUDA driver library path override" -ForegroundColor White  
    Write-Host "  ✅ Enhanced environment variables" -ForegroundColor White
    Write-Host ""
    Write-Host "Once started, useful commands:" -ForegroundColor Cyan
    Write-Host "  python -c 'import torch; print(torch.cuda.is_available())'  # Test CUDA" -ForegroundColor White
    Write-Host "  nvidia-smi                                                  # Check GPU" -ForegroundColor White
    Write-Host "  ./extras/dev-setup.sh                                      # Setup vLLM" -ForegroundColor White
    Write-Host ""
} elseif (![string]::IsNullOrEmpty($Command)) {
    $RunArgs += @($ImageTag, "bash", "-c", "source /home/vllmuser/venv/bin/activate && $Command")
    Write-Host "🚀 Running command with enhanced GPU support: $Command" -ForegroundColor Green
} else {
    $RunArgs += @($ImageTag)
    Write-Host "🚀 Starting container with enhanced GPU support..." -ForegroundColor Green
}

# Show the command being run (for debugging)
Write-Host ""
Write-Host "Command: podman $($RunArgs -join ' ')" -ForegroundColor Gray
Write-Host ""

# Run the container
& podman @RunArgs

# Show results
if ($LASTEXITCODE -eq 0) {
    if ($GPUCheck) {
        Write-Host ""
        Write-Host "✅ GPU check completed" -ForegroundColor Green
    } elseif ($Interactive) {
        Write-Host ""
        Write-Host "Container exited successfully." -ForegroundColor Green
        Write-Host "To reconnect: .\extras\run-vllm-dev-podman-fixed.ps1" -ForegroundColor Cyan
    }
} else {
    Write-Host ""
    Write-Host "❌ Container command failed with exit code: $LASTEXITCODE" -ForegroundColor Red
}
