#!/usr/bin/env pwsh

# Unified lightweight dev container launcher for vLLM
# - Auto-detects container engine (Podman preferred, fallback Docker)
# - Minimal flags; environment baked into image
# - Optional GPU diagnostics

param(
    [switch]$Build,
    [switch]$Interactive,
    [string]$Command = "",
    [switch]$Setup,
    [switch]$GPUCheck,
    [switch]$Help,
    [ValidateSet('podman')][string]$Engine = 'podman'
)

if ($Help) {
    Write-Host "Usage: run-vllm-dev.ps1 [-Build] [-Interactive] [-Command <cmd>] [-Setup] [-GPUCheck] [-Help]"
    Write-Host ""
    Write-Host "Examples:" 
    Write-Host '  .\run-vllm-dev.ps1 -Build'
    # Use double quotes for python -c and single quotes inside for Python code; escaping via doubling single quotes in literal PS string
    Write-Host '  .\run-vllm-dev.ps1 -Command "python -c ''import torch;print(torch.cuda.is_available())''"'
    Write-Host '  .\run-vllm-dev.ps1 -GPUCheck'
    Write-Host '  .\run-vllm-dev.ps1 -Setup    # runs ./extras/dev-setup.sh inside the container'
    exit 0
}

if (-not $Interactive -and [string]::IsNullOrEmpty($Command) -and -not $GPUCheck -and -not $Setup) { $Interactive = $true }

if (-not (Get-Command podman -ErrorAction SilentlyContinue)) { Write-Host "❌ Podman not found in PATH" -ForegroundColor Red; exit 1 }

$ContainerName = "vllm-dev"
$ImageTag = "vllm-dev:latest"
$SourceDir = $PWD

Write-Host "🐋 vLLM Dev Container (Podman)" -ForegroundColor Green

if ($Build) {
    Write-Host "🔨 Building image..." -ForegroundColor Yellow
    $buildCmd = @("build","-f","extras/Dockerfile","-t",$ImageTag,".")
    & podman @buildCmd
    if ($LASTEXITCODE -ne 0) { Write-Host "❌ Build failed" -ForegroundColor Red; exit 1 }
    Write-Host "✅ Build ok" -ForegroundColor Green
}

# Already running?
$running = podman ps --filter "name=$ContainerName" --format "{{.Names}}" 2>$null

if ($running -eq $ContainerName) {
    if ($GPUCheck) {
        Write-Host "🔍 GPU check (existing container)" -ForegroundColor Yellow
        $cmd = @'
source /home/vllmuser/venv/bin/activate && python - <<'PY'
import torch
print("PyTorch:", getattr(torch,"__version__","n/a"))
print("CUDA:", torch.cuda.is_available())
print("Devices:", torch.cuda.device_count() if torch.cuda.is_available() else 0)
if torch.cuda.is_available():
    try:
        print("GPU 0:", torch.cuda.get_device_name(0))
    except Exception as e:
        print("GPU name error:", e)
PY
nvidia-smi || true
'@
    podman exec $ContainerName bash -c $cmd
        exit $LASTEXITCODE
    }
    if ($Setup) {
        Write-Host "🔧 Running dev setup in existing container" -ForegroundColor Yellow
        podman exec $ContainerName bash -lc 'chmod +x ./extras/dev-setup.sh 2>/dev/null || true; ./extras/dev-setup.sh'
        exit $LASTEXITCODE
    }
    if ($Command) {
        Write-Host "🚀 Running command in existing container" -ForegroundColor Green
        $runCmd = "source /home/vllmuser/venv/bin/activate && $Command"
    podman exec $ContainerName bash -c $runCmd
        exit $LASTEXITCODE
    }
    $resp = Read-Host "Attach to running container? [Y/n]"
    if ($resp -eq "" -or $resp -match '^[Yy]$') { podman exec -it $ContainerName bash; exit $LASTEXITCODE } else { exit 0 }
}

# Ensure image exists
podman image exists $ImageTag
if ($LASTEXITCODE -ne 0) { Write-Host "❌ Image missing. Use -Build." -ForegroundColor Red; exit 1 }

# Base args
$runArgs = @("run","--rm","--security-opt=label=disable","--device=nvidia.com/gpu=all","--shm-size","8g","--tmpfs","/tmp:size=8g","-v","${SourceDir}:/workspace:Z","-w","/workspace","--name=$ContainerName","--user","vllmuser","--env","ENGINE=podman")
foreach ($ev in 'NVIDIA_VISIBLE_DEVICES','NVIDIA_DRIVER_CAPABILITIES','NVIDIA_REQUIRE_CUDA') {
    $val = [Environment]::GetEnvironmentVariable($ev)
    if ($val) { $runArgs += @('--env',"$ev=$val") }
}
# Force override to avoid 'void' value injected by failing hooks
$runArgs += @('--env','NVIDIA_VISIBLE_DEVICES=all','--env','NVIDIA_DRIVER_CAPABILITIES=compute,utility')

if ($GPUCheck) {
        $gpuScript = @"
echo '=== GPU Check ==='
which nvidia-smi && nvidia-smi || echo 'nvidia-smi unavailable'
echo '--- /dev/nvidia* ---'
ls -l /dev/nvidia* 2>/dev/null || echo 'no /dev/nvidia* nodes'
echo '--- Environment (NVIDIA_*) ---'
env | grep -E '^NVIDIA_' || echo 'no NVIDIA_* env vars'
source /home/vllmuser/venv/bin/activate 2>/dev/null || true
python - <<'PY'
import json,torch
out={
 'torch_version':getattr(torch,'__version__','n/a'),
 'torch_cuda_version':getattr(getattr(torch,'version',None),'cuda','n/a'),
 'cuda_available':torch.cuda.is_available()
}
try: out['device_count']=torch.cuda.device_count()
except Exception as e: out['device_count_error']=str(e)
if out['cuda_available'] and out.get('device_count',0)>0:
    try:
        cap=torch.cuda.get_device_capability(0)
        out['device_0']={'name':torch.cuda.get_device_name(0),'capability':f'sm_{cap[0]}{cap[1]}'}
    except Exception as e:
        out['device_0_error']=str(e)
else:
    out['diagnostics']=['Missing /dev/nvidia* or podman machine without GPU passthrough']
print(json.dumps(out,indent=2))
PY
"@
        $runArgs += @($ImageTag,"bash","-lc",$gpuScript)
} elseif ($Setup) {
    $runArgs += @($ImageTag,"bash","-lc","chmod +x ./extras/dev-setup.sh 2>/dev/null || true; ./extras/dev-setup.sh")
    Write-Host "🔧 Running dev setup" -ForegroundColor Green
} elseif ($Interactive -and -not $Command) {
    $runArgs += @("-it",$ImageTag,"bash")
    Write-Host "🚀 Interactive shell" -ForegroundColor Green
} elseif ($Command) {
    $runArgs += @($ImageTag,"bash","-lc","source /home/vllmuser/venv/bin/activate && $Command")
    Write-Host "🚀 Running command" -ForegroundColor Green
} else {
    $runArgs += @($ImageTag)
}

Write-Host "Command: podman $($runArgs -join ' ')" -ForegroundColor Gray
& podman @runArgs

if ($LASTEXITCODE -eq 0 -and $Interactive) {
    Write-Host "Exited cleanly" -ForegroundColor Green
}
