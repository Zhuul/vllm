#!/usr/bin/env pwsh

# WSL2-optimized script to run vLLM development container with GPU support
# Includes proper CUDA library mounting for WSL2 environment

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
    Write-Host "Usage: run-vllm-dev-wsl2.ps1 [-Build] [-Interactive] [-Command <cmd>] [-GPUCheck] [-Help]"
    Write-Host ""
    Write-Host "WSL2-optimized vLLM container launcher with proper CUDA support"
    Write-Host ""
    Write-Host "Options:"
    Write-Host "  -Build        Build the container before running"
    Write-Host "  -Interactive  Run in interactive mode (default)"
    Write-Host "  -Command      Run specific command instead of interactive shell"
    Write-Host "  -GPUCheck     Run GPU diagnostics"
    Write-Host "  -Help         Show this help message"
    Write-Host ""
    Write-Host "Examples:"
    Write-Host "  .\run-vllm-dev-wsl2.ps1 -Build                      # Build and run container"
    Write-Host "  .\run-vllm-dev-wsl2.ps1                             # Run container interactively"
    Write-Host "  .\run-vllm-dev-wsl2.ps1 -GPUCheck                   # Check GPU setup"
    Write-Host "  .\run-vllm-dev-wsl2.ps1 -Command 'python -c `"import torch; print(torch.cuda.is_available())`"'"
    Write-Host ""
    exit 0
}

$ContainerName = "vllm-dev"
$ImageTag = "vllm-dev:latest"
$SourceDir = $PWD

Write-Host "🐋 vLLM Development Container (WSL2 Optimized)" -ForegroundColor Green
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
        podman exec $ContainerName bash -c "source /home/vllmuser/venv/bin/activate && python -c 'import torch; print(f`"PyTorch version: {torch.__version__}`"); print(f`"CUDA available: {torch.cuda.is_available()}`"); print(f`"CUDA devices: {torch.cuda.device_count()}`")'"
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

# WSL2-specific CUDA environment variables with RTX 5090 support
$CudaEnvVars = @(
    "-e", "NVIDIA_VISIBLE_DEVICES=all"
    "-e", "NVIDIA_DRIVER_CAPABILITIES=compute,utility"
    "-e", "CUDA_VISIBLE_DEVICES=0"
    "-e", "CUDA_HOME=/usr/local/cuda"
    "-e", "PATH=/usr/local/cuda/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    "-e", "LD_LIBRARY_PATH=/usr/lib/wsl/drivers:/usr/lib/wsl/lib:/usr/lib/x86_64-linux-gnu:/usr/local/cuda/lib64:/usr/local/cuda/lib"
    "-e", "TORCH_CUDA_ARCH_LIST=7.0;7.5;8.0;8.6;8.9;9.0;12.0"
    "-e", "CMAKE_ARGS=-DENABLE_MACHETE=OFF"
)

# WSL2-specific volume mounts for NVIDIA libraries
$WSLVolumes = @()

# Try to detect WSL2 NVIDIA driver paths from host
try {
    $WSLDistro = wsl -l -q | Select-Object -First 1
    if ($WSLDistro) {
        Write-Host "🔍 Detecting WSL2 NVIDIA paths..." -ForegroundColor Yellow
        
        # Common WSL2 NVIDIA paths to mount
        $NVIDIAPaths = @(
            "/usr/lib/wsl/drivers"
            "/usr/lib/wsl/lib" 
            "/usr/lib/wsl"
        )
        
        foreach ($path in $NVIDIAPaths) {
            $checkPath = wsl -d $WSLDistro -e test -d $path 2>$null
            if ($LASTEXITCODE -eq 0) {
                $WSLVolumes += @("-v", "${path}:${path}:ro")
                Write-Host "  ✅ Will mount: $path" -ForegroundColor Green
            }
        }
    }
} catch {
    Write-Host "⚠️  Could not detect WSL2 paths automatically" -ForegroundColor Yellow
}

# Container run arguments
$RunArgs = @(
    "run", "--rm"
    "--device=nvidia.com/gpu=all"
    "--security-opt=label=disable"
    "--name=$ContainerName"
    "-v", "${SourceDir}:/workspace:Z"
    "-w", "/workspace"
    "--user", "vllmuser"
)

# Add CUDA environment variables
$RunArgs += $CudaEnvVars

# Add WSL2 volume mounts
$RunArgs += $WSLVolumes

if ($GPUCheck) {
    $RunArgs += @($ImageTag, "bash", "-c", @"
echo '=== WSL2 GPU Check ==='
echo 'NVIDIA Driver:'
nvidia-smi || echo 'nvidia-smi failed'
echo ''
echo 'CUDA Environment:'
echo "CUDA_HOME: `$CUDA_HOME"
echo "LD_LIBRARY_PATH: `$LD_LIBRARY_PATH"
echo ''
echo 'CUDA Libraries:'
find /usr/lib/wsl -name 'libcuda.so*' 2>/dev/null | head -3 || echo 'No WSL CUDA libs found'
ldconfig -p | grep cuda | head -3 || echo 'No CUDA libs in ldconfig'
echo ''
echo 'PyTorch Check:'
source /home/vllmuser/venv/bin/activate
python -c "import torch; print(f'PyTorch version: {torch.__version__}'); print(f'CUDA available: {torch.cuda.is_available()}'); print(f'CUDA devices: {torch.cuda.device_count()}')"
"@)
    Write-Host "🔍 Running WSL2 GPU diagnostics..." -ForegroundColor Yellow
} elseif ($Interactive -and [string]::IsNullOrEmpty($Command)) {
    $RunArgs += @("-it", $ImageTag, "bash")
    Write-Host "🚀 Starting interactive container with WSL2 GPU support..." -ForegroundColor Green
    Write-Host ""
    Write-Host "WSL2 optimizations:" -ForegroundColor Cyan
    Write-Host "  ✅ CUDA environment variables configured" -ForegroundColor White
    Write-Host "  ✅ WSL2 NVIDIA library paths mounted" -ForegroundColor White  
    Write-Host "  ✅ GPU device access enabled" -ForegroundColor White
    Write-Host ""
    Write-Host "Once started, useful commands:" -ForegroundColor Cyan
    Write-Host "  python -c 'import torch; print(torch.cuda.is_available())'  # Test CUDA" -ForegroundColor White
    Write-Host "  nvidia-smi                                                  # Check GPU" -ForegroundColor White
    Write-Host "  ./extras/dev-setup.sh                                      # Setup vLLM" -ForegroundColor White
    Write-Host ""
} elseif (![string]::IsNullOrEmpty($Command)) {
    $RunArgs += @($ImageTag, "bash", "-c", "source /home/vllmuser/venv/bin/activate && $Command")
    Write-Host "🚀 Running command with WSL2 GPU support: $Command" -ForegroundColor Green
} else {
    $RunArgs += @($ImageTag)
    Write-Host "🚀 Starting container with WSL2 GPU support..." -ForegroundColor Green
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
        Write-Host "✅ GPU check completed successfully" -ForegroundColor Green
        Write-Host "If PyTorch CUDA shows 'False', try rebuilding container or restarting Podman machine" -ForegroundColor Yellow
    } elseif ($Interactive) {
        Write-Host ""
        Write-Host "Container exited successfully." -ForegroundColor Green
        Write-Host "To reconnect: .\extras\run-vllm-dev-wsl2.ps1" -ForegroundColor Cyan
    }
} else {
    Write-Host ""
    Write-Host "❌ Container command failed with exit code: $LASTEXITCODE" -ForegroundColor Red
    if ($LASTEXITCODE -eq 125) {
        Write-Host "This often indicates GPU device access issues." -ForegroundColor Yellow
        Write-Host "Try: podman machine restart" -ForegroundColor White
    }
}
