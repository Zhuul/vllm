#!/usr/bin/env pwsh
[CmdletBinding()] param(
	[switch]$Build,
	[switch]$Interactive,
	[string]$Command = "",
	[switch]$Setup,
	[switch]$GPUCheck,
	[switch]$Mirror,
	[switch]$Recreate,
	[string]$WorkVolume = "",
	[string]$WorkDirHost = "",
	[switch]$Progress,
	[switch]$Help
)

if ($Help) {
	Write-Host "Usage: extras/podman/run.ps1 [-Build] [-Interactive] [-Command <cmd>] [-Setup] [-GPUCheck] [-Mirror] [-Recreate] [-WorkVolume <name>] [-WorkDirHost <path>] [-Progress]"; exit 0
}

if (-not $Interactive -and [string]::IsNullOrEmpty($Command) -and -not $GPUCheck -and -not $Setup) { $Interactive = $true }

if (-not (Get-Command podman -ErrorAction SilentlyContinue)) { Write-Host "❌ Podman not found in PATH" -ForegroundColor Red; exit 1 }

$ContainerName = "vllm-dev"
$ImageTag = "vllm-dev:latest"
$SourceDir = (Get-Location).Path

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

if ($Recreate -and $running -eq $ContainerName) {
	Write-Host "♻️  Removing existing container '$ContainerName'" -ForegroundColor Yellow
	podman rm -f $ContainerName | Out-Null
	$running = $null
}

if ($running -eq $ContainerName) {
	if ($GPUCheck) {
		Write-Host "🔍 GPU check (existing container)" -ForegroundColor Yellow
		$cmd = @'
source /home/vllmuser/venv/bin/activate && python - <<'PY'
import torch, os
print("PyTorch:", getattr(torch,"__version__","n/a"))
print("CUDA:", torch.cuda.is_available())
print("Devices:", torch.cuda.device_count() if torch.cuda.is_available() else 0)
print("LD_LIBRARY_PATH:", os.environ.get("LD_LIBRARY_PATH"))
if torch.cuda.is_available():
		try:
				print("GPU 0:", torch.cuda.get_device_name(0))
		except Exception as e:
				print("GPU name error:", e)
PY
nvidia-smi || true
'@
		$cmd = "export NVIDIA_VISIBLE_DEVICES=all; " + $cmd
		podman exec $ContainerName bash -lc $cmd
		exit $LASTEXITCODE
	}
	if ($Setup) {
		Write-Host "🔧 Running dev setup in existing container" -ForegroundColor Yellow
		$envs = @()
		if ($Mirror) { $envs += @('LOCAL_MIRROR=1') }
		if ($Progress) { $envs += @('PROGRESS_WATCH=1') }
		$envs += @('NVIDIA_VISIBLE_DEVICES=all')
		$envStr = ($envs | ForEach-Object { "export $_;" }) -join ' '
		$cmd = "$envStr chmod +x ./extras/dev-setup.sh 2>/dev/null || true; ./extras/dev-setup.sh"
		if ($Progress) { podman exec -it $ContainerName bash -lc $cmd } else { podman exec $ContainerName bash -lc $cmd }
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

# Base args (no default /tmp tmpfs; can be enabled via VLLM_TMPFS_TMP_SIZE)
$runArgs = @("run","--rm","--security-opt=label=disable","--shm-size","8g","-v","${SourceDir}:/workspace:Z")
if (-not [string]::IsNullOrWhiteSpace($WorkVolume)) { $runArgs += @('-v',"${WorkVolume}:/opt/work:Z") }
elseif ($WorkDirHost -and (Test-Path $WorkDirHost)) { $runArgs += @('-v',"${WorkDirHost}:/opt/work:Z") }
$runArgs += @('-w','/workspace','--name',"$ContainerName",'--user','vllmuser','--env','ENGINE=podman')

$tmpfsSize = [Environment]::GetEnvironmentVariable('VLLM_TMPFS_TMP_SIZE')
if (-not [string]::IsNullOrEmpty($tmpfsSize) -and $tmpfsSize -ne '0') { $runArgs += @('--tmpfs',"/tmp:size=$tmpfsSize") }

if ($true) { # Request GPU via CDI hooks
	$runArgs = @("run","--rm","--security-opt=label=disable","--device=nvidia.com/gpu=all") + $runArgs[2..($runArgs.Length-1)]
}

# WSL GPU: map /dev/dxg and mount WSL libs
$runArgs += @('--device','/dev/dxg','-v','/usr/lib/wsl:/usr/lib/wsl:ro')
if ($Mirror) { $runArgs += @('--env','LOCAL_MIRROR=1') }
foreach ($ev in 'NVIDIA_VISIBLE_DEVICES','NVIDIA_DRIVER_CAPABILITIES','NVIDIA_REQUIRE_CUDA') {
	$val = [Environment]::GetEnvironmentVariable($ev)
	if ($val) { $runArgs += @('--env',"$ev=$val") }
}
$runArgs += @('--env','ENGINE=podman','--env','NVIDIA_VISIBLE_DEVICES=all','--env','NVIDIA_DRIVER_CAPABILITIES=compute,utility','--env','NVIDIA_REQUIRE_CUDA=')

if ($GPUCheck) {
	$pyDiag = @'
import json, torch, os
out = {
		"torch_version": getattr(torch, "__version__", "n/a"),
		"torch_cuda_version": getattr(getattr(torch, "version", None), "cuda", "n/a"),
		"cuda_available": torch.cuda.is_available(),
		"ld_library_path": os.environ.get("LD_LIBRARY_PATH"),
}
try:
		out["device_count"] = torch.cuda.device_count()
except Exception as e:
		out["device_count_error"] = str(e)
if out["cuda_available"] and out.get("device_count", 0) > 0:
		try:
				cap = torch.cuda.get_device_capability(0)
				out["device_0"] = {"name": torch.cuda.get_device_name(0), "capability": f"sm_{cap[0]}{cap[1]}"}
		except Exception as e:
				out["device_0_error"] = str(e)
else:
		out["diagnostics"] = ["Missing /dev/nvidia* or podman machine without GPU passthrough"]
print(json.dumps(out, indent=2))
'@
	$pyB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pyDiag))
	$gpuScript = @'
echo '=== GPU Check ==='
which nvidia-smi && nvidia-smi || echo 'nvidia-smi unavailable'
echo '--- /dev/nvidia* ---'
ls -l /dev/nvidia* 2>/dev/null || echo 'no /dev/nvidia* nodes'
echo '--- Environment (NVIDIA_*) ---'
env | grep -E '^NVIDIA_' || echo 'no NVIDIA_* env vars'
if [ "$NVIDIA_VISIBLE_DEVICES" = "void" ]; then echo 'WARN: NVIDIA_VISIBLE_DEVICES=void (no GPU mapped)'; fi
echo '--- LD_LIBRARY_PATH ---'
echo "LD_LIBRARY_PATH=$LD_LIBRARY_PATH"
source /home/vllmuser/venv/bin/activate 2>/dev/null || true
echo __PY_B64__ | base64 -d > /tmp/gpucheck.py
python /tmp/gpucheck.py || true
rm -f /tmp/gpucheck.py
'@
	$gpuScript = "export NVIDIA_VISIBLE_DEVICES=all; export LD_LIBRARY_PATH=/usr/lib/wsl/lib:/usr/lib/wsl/drivers:`$LD_LIBRARY_PATH; " + ($gpuScript -replace '__PY_B64__', $pyB64) -replace "`r",""
	$runArgs += @('--user','root', $ImageTag,'bash','-lc',$gpuScript)
} elseif ($Setup) {
	# Use robust setup entrypoint that finds the right script (extras/dev-setup.sh, extras/old/dev-setup.sh, or image helper)
	$prefix = "chmod +x ./extras/podman/dev-setup.sh 2>/dev/null || true; "
	$envPrefix = ''
	if ($Mirror) { $envPrefix += 'export LOCAL_MIRROR=1; ' }
	if ($Progress) { $envPrefix += 'export PROGRESS_WATCH=1; ' }
	$envPrefix += 'export TMPDIR=/opt/work/tmp; export TMP=/opt/work/tmp; export TEMP=/opt/work/tmp; mkdir -p /opt/work/tmp; '
		$setupCmd = $prefix + $envPrefix + "./extras/podman/dev-setup.sh"
	if ($Progress) { $runArgs += @('-it', $ImageTag, 'bash','-lc', $setupCmd) } else { $runArgs += @($ImageTag, 'bash','-lc', $setupCmd) }
	Write-Host "🔧 Running dev setup" -ForegroundColor Green
} elseif ($Interactive -and -not $Command) {
	$runArgs += @('-it',$ImageTag,'bash')
	Write-Host "🚀 Interactive shell" -ForegroundColor Green
} elseif ($Command) {
	$runArgs += @($ImageTag,'bash','-lc',"source /home/vllmuser/venv/bin/activate && $Command")
	Write-Host "🚀 Running command" -ForegroundColor Green
} else {
	$runArgs += @($ImageTag)
}

Write-Host "Command: podman $($runArgs -join ' ')" -ForegroundColor Gray
& podman @runArgs

if ($LASTEXITCODE -eq 0 -and $Interactive) { Write-Host "Exited cleanly" -ForegroundColor Green }
