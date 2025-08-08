# run-vllm-dev-fedora.ps1
# Launch a vLLM development container using Fedora 42 base with Podman
# This script mounts your local vLLM fork and sets up a development environment

# === Configuration ===
$Network          = if ($env:VLLM_PODMAN_NETWORK) { $env:VLLM_PODMAN_NETWORK } else { "llm-net" }  # Use env var or default to llm-net
$ContainerName    = "vllm-dev-fedora"
$PortMappingAPI   = "127.0.0.1:8000:8000"
$PortMappingSSH   = "127.0.0.1:2222:22"
# GPU configuration for Windows/WSL2 - try different methods
$Gpus             = "--device", "nvidia.com/gpu=all", "--security-opt", "label=disable"  # WSL2 + Podman method
# Alternative methods (uncomment as needed):
# $Gpus           = "--device", "nvidia.com/gpu=all"  # Standard Podman method
# $Gpus           = "--gpus", "all"  # Docker-style method

# Adjust these paths to your environment
$VLLMSourcePath   = 'C:\sources\github\Zhuul\vllm'  # Your fork path
$ModelCacheVolume = 'C:\models\huggingface'         # Persistent HF cache
$VLLMCacheVolume  = 'C:\cache\vllm'                 # vLLM specific cache

# Environment variables
$EnvPytorchCuda   = 'PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True'
$EnvToken         = 'HUGGINGFACE_HUB_TOKEN=your_huggingface_token_here'
$EnvVLLM          = 'VLLM_USE_V1=1'
$EnvDisableFlash  = 'VLLM_DISABLE_FLASH_ATTN=1'  # Disable if build issues

# Build settings
$ImageName        = "vllm-dev-fedora:latest"
$DockerfilePath   = "extras/Dockerfile"

# === Functions ===
function Write-Section {
    param([string]$Title)
    Write-Host "`n=== $Title ===" -ForegroundColor Cyan
}

function Test-PodmanAvailable {
    try {
        $null = Get-Command podman -ErrorAction Stop
        return $true
    }
    catch {
        Write-Host "Error: Podman is not available. Please install Podman Desktop or Podman CLI." -ForegroundColor Red
        return $false
    }
}

function Test-PathExists {
    param([string]$Path, [string]$Description)
    if (-not (Test-Path $Path)) {
        Write-Host "Warning: $Description path does not exist: $Path" -ForegroundColor Yellow
        Write-Host "Creating directory..." -ForegroundColor Yellow
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Test-NetworkExists {
    param([string]$NetworkName)
    try {
        $networks = podman network ls --format "{{.Name}}" 2>$null
        if ($LASTEXITCODE -eq 0) {
            $networkExists = $networks | Where-Object { $_ -eq $NetworkName }
            return $null -ne $networkExists
        }
        return $false
    }
    catch {
        return $false
    }
}

function Test-GPUAvailable {
    Write-Host "Testing GPU availability..." -ForegroundColor Yellow
    try {
        # Test if NVIDIA drivers are available in WSL2/host
        podman run --rm --device nvidia.com/gpu=all nvidia/cuda:12.9.1-base-ubi9 nvidia-smi 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "GPU is available and working!" -ForegroundColor Green
            return $true
        } else {
            Write-Host "GPU test failed. GPU might not be available." -ForegroundColor Yellow
            Write-Host "Container will run in CPU-only mode." -ForegroundColor Yellow
            return $false
        }
    }
    catch {
        Write-Host "Could not test GPU availability." -ForegroundColor Yellow
        return $false
    }
}

# === Main Script ===
Write-Section "vLLM Development Environment Setup (Fedora 42)"

Write-Host "Using Podman network: $Network" -ForegroundColor Green

# Check prerequisites
if (-not (Test-PodmanAvailable)) {
    exit 1
}

# Validate and create paths
Test-PathExists $VLLMSourcePath "vLLM source"
Test-PathExists $ModelCacheVolume "Model cache"
Test-PathExists $VLLMCacheVolume "vLLM cache"

# Check if we're in the vLLM repository root
if (-not (Test-Path "pyproject.toml")) {
    Write-Host "Warning: Not in vLLM repository root. Please run from vLLM root directory." -ForegroundColor Yellow
}

Write-Section "Network Configuration"

# Check if network exists, create if it doesn't
if (Test-NetworkExists $Network) {
    Write-Host "Network '$Network' already exists, using it." -ForegroundColor Green
} else {
    Write-Host "Creating network '$Network'..." -ForegroundColor Yellow
    podman network create $Network 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Network '$Network' created successfully." -ForegroundColor Green
    } else {
        Write-Host "Warning: Could not create network '$Network'. Will use default networking." -ForegroundColor Yellow
        $Network = ""  # Use default networking
    }
}

Write-Section "GPU Configuration"

# Test GPU availability (optional - for diagnostics)
Test-GPUAvailable | Out-Null

Write-Section "Building Development Container"

# Build the container image
Write-Host "Building vLLM development image..."
$BuildCommand = "podman build -f $DockerfilePath -t $ImageName ."
Write-Host "Build command: $BuildCommand" -ForegroundColor Gray
Invoke-Expression $BuildCommand

if ($LASTEXITCODE -ne 0) {
    Write-Host "Error: Failed to build container image" -ForegroundColor Red
    exit 1
}

Write-Section "Starting Development Container"

# Remove existing container if it exists
Write-Host "Removing existing container if present..."
podman rm -f $ContainerName 2>$null

# Inner command for container setup
$InnerCommand = @"
whoami && \
dnf install -y openssh-server sudo && \
systemctl enable sshd && \
mkdir -p /var/run/sshd && \
echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config && \
echo 'PasswordAuthentication yes' >> /etc/ssh/sshd_config && \
usermod -aG wheel vllmuser && \
echo 'vllmuser:vllmdev' | chpasswd && \
/usr/sbin/sshd -D & \
runuser -l vllmuser -c "cd /workspace && source /home/vllmuser/venv/bin/activate && echo 'Python Virtual environment activated:' \$VIRTUAL_ENV && echo 'Setting up vLLM development environment...' && pip install -e . && python -c 'import vllm; print(\"vLLM version:\", vllm.__version__)' && echo 'Development environment ready!' && exec /bin/bash"
"@

# Strip Windows line endings
$InnerCommand = $InnerCommand -replace "`r", ""

# Build the complete Podman command
$PodmanArgs = @(
    "run", "-it",
    "--name", $ContainerName,
    "-p", $PortMappingAPI,
    "-p", $PortMappingSSH
)
$PodmanArgs += $Gpus  # Add GPU arguments (handles both single and multiple args)
$PodmanArgs += @(
    "-v", "${VLLMSourcePath}:/workspace:Z",
    "-v", "${ModelCacheVolume}:/home/vllmuser/.cache/huggingface:Z",
    "-v", "${VLLMCacheVolume}:/home/vllmuser/.cache/vllm:Z",
    "-e", $EnvPytorchCuda,
    "-e", $EnvToken,
    "-e", $EnvVLLM,
    "-e", $EnvDisableFlash,
    "--ipc=host",
    "--entrypoint", "/bin/bash",
    $ImageName,
    "-c", $InnerCommand
)

# Add network parameter only if network is specified
if ($Network -and $Network -ne "") {
    $PodmanArgs = @("run", "-it", "--network", $Network) + $PodmanArgs[2..($PodmanArgs.Length-1)]
}

Write-Host "Starting container with command:" -ForegroundColor Gray
Write-Host "podman $($PodmanArgs -join ' ')" -ForegroundColor Gray

& podman @PodmanArgs

Write-Section "Container Started"
Write-Host "Development environment is ready!" -ForegroundColor Green
Write-Host "- vLLM API will be available at: http://localhost:8000" -ForegroundColor Green
Write-Host "- SSH access available at: localhost:2222" -ForegroundColor Green
Write-Host "- Container name: $ContainerName" -ForegroundColor Green
Write-Host "- Network: $Network" -ForegroundColor Green
Write-Host "`nTo reconnect to the container later:" -ForegroundColor Yellow
Write-Host "  podman start -ai $ContainerName" -ForegroundColor Yellow