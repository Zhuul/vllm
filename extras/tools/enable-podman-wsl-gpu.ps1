#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Configures a Podman machine running under WSL2 (Rocky Linux 10 default) for NVIDIA GPU passthrough.

.DESCRIPTION
    Installs the NVIDIA Container Toolkit inside the Podman machine, generates a CDI spec for
    WSL2 GPUs, and verifies device/node availability. This script is idempotent and safe to run
    multiple times. A machine reboot is recommended after toolkit installation.

.PARAMETER MachineName
    Name of the Podman machine to configure. Defaults to "podman-machine-default".

.PARAMETER SkipReboot
    Prevents the script from automatically restarting the Podman machine after configuration.

.PARAMETER ImagePath
    Optional override for the Podman guest image. Defaults to the Rocky Linux 10 WSL Base archive.

.EXAMPLE
    pwsh extras/tools/enable-podman-wsl-gpu.ps1

.NOTES
    Requires Podman 4.6+ with `podman machine` support and an NVIDIA driver on Windows that
    exposes the CUDA WSL integration. Run from an elevated PowerShell session for best results.
#>

[CmdletBinding()]
param(
    [string]$MachineName = "podman-machine-default",
    [switch]$SkipReboot,
    [switch]$Reset,
    [string]$ImagePath = "https://dl.rockylinux.org/pub/rocky/10/images/x86_64/Rocky-10-WSL-Base.latest.x86_64.wsl",
    [switch]$Rootful
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Invoke-Podman {
    param([string[]]$Arguments)
    $result = & podman @Arguments
    return $result
}

function Test-PodmanMachine {
    try {
        $name = Invoke-Podman @('machine','inspect',$MachineName,'--format','{{.Name}}') | Select-Object -First 1
        if ($name -and $name.TrimEnd('*') -eq $MachineName) {
            return $true
        }
    } catch {
    }
    return $false
}

function Confirm-PodmanCli {
    if (-not (Get-Command podman -ErrorAction SilentlyContinue)) {
        throw "Podman CLI not found. Install Podman Desktop or Podman for Windows first."
    }
}

function Resolve-ImagePath {
    param([string]$ImageSpec)

    if (-not $ImageSpec) {
        return $null
    }

    if ($ImageSpec -match '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
        $cacheRoot = Join-Path $env:LOCALAPPDATA 'vllm-podman-images'
        if (-not (Test-Path $cacheRoot)) {
            [void](New-Item -ItemType Directory -Path $cacheRoot -Force)
        }
        $leaf = Split-Path $ImageSpec -Leaf
        if (-not $leaf) {
            $leaf = 'podman-machine-image.qcow2'
        }
        $localPath = Join-Path $cacheRoot $leaf
        if (-not (Test-Path $localPath)) {
            Write-Host "⬇️  Downloading Podman machine image from '$ImageSpec'..." -ForegroundColor Cyan
            try {
                Invoke-WebRequest -Uri $ImageSpec -OutFile $localPath -UseBasicParsing | Out-Null
            } catch {
                if (Test-Path $localPath) { Remove-Item $localPath -Force }
                throw "Failed to download image from '$ImageSpec': $($_.Exception.Message)"
            }
        } else {
            Write-Host "ℹ️  Reusing cached machine image '$localPath'." -ForegroundColor DarkGray
        }
        return $localPath
    }

    if (-not (Test-Path $ImageSpec)) {
        throw "Image path '$ImageSpec' does not exist."
    }

    return (Resolve-Path $ImageSpec).Path
}

function Initialize-PodmanMachine {
    if (Test-PodmanMachine) {
        return
    }
    Write-Host "🆕 Creating Podman machine '$MachineName'..." -ForegroundColor Cyan
    $resolvedImage = Resolve-ImagePath -ImageSpec $ImagePath
    $initArgs = @('machine','init')
    if ($resolvedImage) {
        Write-Host "📦 Using machine image '$resolvedImage'." -ForegroundColor DarkGray
        $initArgs += @('--image',$resolvedImage)
    }
    $initArgs += $MachineName
    Invoke-Podman $initArgs | Out-Null
}

function Start-MachineIfNeeded {
    $state = $null
    try {
        $state = Invoke-Podman @('machine','inspect',$MachineName,'--format','{{.State}}') | Select-Object -First 1
    } catch {}
    if (-not $state) {
        throw "Machine '$MachineName' could not be inspected. Ensure it exists or rerun with -Reset."
    }
    if ($state.Trim() -ne 'Running') {
        Write-Host "🟢 Starting Podman machine '$MachineName'..." -ForegroundColor Green
        Invoke-Podman @('machine','start',$MachineName) | Out-Null
    }
}

function Reset-PodmanMachine {
    if (-not $Reset.IsPresent) {
        return
    }
    Write-Host "♻️ Resetting Podman machine '$MachineName'..." -ForegroundColor Yellow
    if (Test-PodmanMachine) {
        try {
            Invoke-Podman @('machine','stop',$MachineName) | Out-Null
        } catch {}
        Invoke-Podman @('machine','rm','-f',$MachineName) | Out-Null
    } else {
        Write-Host "ℹ️  Machine '$MachineName' already absent." -ForegroundColor DarkGray
    }
}

function Set-PodmanRootfulMode {
    if (-not $Rootful.IsPresent) {
        return
    }
    if (-not (Test-PodmanMachine)) {
        return
    }
    $rootfulState = Invoke-Podman @('machine','inspect',$MachineName,'--format','{{.Rootful}}') | Select-Object -First 1
    if ($rootfulState -and $rootfulState.Trim().ToLower() -eq 'true') {
        return
    }
    Write-Host "🔑 Enabling rootful mode for '$MachineName'..." -ForegroundColor Yellow
    Invoke-Podman @('machine','set','--rootful',$MachineName) | Out-Null
    try {
        Invoke-Podman @('machine','stop',$MachineName) | Out-Null
    } catch {}
}

function Get-OsRelease {
    $osRelease = Invoke-Podman @('machine','ssh',$MachineName,'--','cat','/etc/os-release')
    $map = @{}
    foreach ($line in $osRelease) {
        if ($line -match '^(?<key>[A-Z0-9_]+)=("?)(?<value>.*)\2$') {
            $map[$Matches.key] = $Matches.value
        }
    }
    return $map
}

function Install-NvidiaToolkit {
    $remoteScript = @'
#!/usr/bin/env bash
set -euo pipefail

REPO_FILE="/etc/yum.repos.d/nvidia-container-toolkit.repo"
ARCH="$(uname -m)"
. /etc/os-release
MAJOR="${VERSION_ID%%.*}"
ID_LIKE_LOWER=$(echo "${ID_LIKE:-}" | tr '[:upper:]' '[:lower:]')
ID_LOWER=$(echo "$ID" | tr '[:upper:]' '[:lower:]')

if [ ! -f "$REPO_FILE" ]; then
    if [[ "$ID_LOWER" == "rocky" || "$ID_LOWER" == "rhel" || "$ID_LIKE_LOWER" == *"rhel"* ]]; then
        if [[ "$MAJOR" =~ ^1[0-9]$ ]]; then
            CUDA_REPO="https://developer.download.nvidia.com/compute/cuda/repos/rhel${MAJOR}/${ARCH}/cuda-rhel${MAJOR}.repo"
            TMP_REPO=$(mktemp)
            if curl -fsSL "$CUDA_REPO" -o "$TMP_REPO"; then
                sudo mv "$TMP_REPO" "$REPO_FILE"
            else
                rm -f "$TMP_REPO"
            fi
        elif [[ "$MAJOR" -ge 8 ]]; then
            CUDA_REPO="https://developer.download.nvidia.com/compute/cuda/repos/rhel${MAJOR}/${ARCH}/cuda-rhel${MAJOR}.repo"
            TMP_REPO=$(mktemp)
            if curl -fsSL "$CUDA_REPO" -o "$TMP_REPO"; then
                sudo mv "$TMP_REPO" "$REPO_FILE"
            else
                rm -f "$TMP_REPO"
            fi
        fi
    fi

    if [ ! -f "$REPO_FILE" ]; then
        cat <<'EOF' | sudo tee "$REPO_FILE" >/dev/null
[nvidia-container-toolkit]
name=NVIDIA Container Toolkit
baseurl=https://nvidia.github.io/libnvidia-container/stable/rpm
enabled=1
gpgcheck=1
gpgkey=https://nvidia.github.io/libnvidia-container/gpgkey
EOF
    fi
fi

if command -v rpm-ostree >/dev/null 2>&1; then
    sudo rpm-ostree install --idempotent nvidia-container-toolkit || true
else
    sudo dnf install -y nvidia-container-toolkit || true
fi

if command -v nvidia-ctk >/dev/null 2>&1; then
    sudo mkdir -p /etc/cdi /var/cdi
    sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml --mode=wsl || true
    sudo cp -f /etc/cdi/nvidia.yaml /var/cdi/nvidia.yaml || true
fi

if command -v nvidia-smi >/dev/null 2>&1; then
    true
elif [ -x /usr/lib/wsl/drivers/nvidia-smi ]; then
    sudo ln -sf /usr/lib/wsl/drivers/nvidia-smi /usr/local/bin/nvidia-smi
elif [ -x /usr/lib/wsl/lib/nvidia-smi ]; then
    sudo ln -sf /usr/lib/wsl/lib/nvidia-smi /usr/local/bin/nvidia-smi
fi

sudo mkdir -p /usr/lib/wsl
if [ ! -e /usr/lib/wsl/lib ] && [ -d /mnt/c/Windows/System32/nvidia-cuda ]; then
    sudo ln -sf /mnt/c/Windows/System32/nvidia-cuda /usr/lib/wsl/lib
fi
if [ ! -e /usr/lib/wsl/drivers ] && [ -d /mnt/c/Windows/System32/DriverStore/FileRepository ]; then
    sudo ln -sf /mnt/c/Windows/System32/DriverStore/FileRepository /usr/lib/wsl/drivers
fi

sudo udevadm control --reload || true
exit 0
'@

    $remoteScriptLf = $remoteScript -replace "`r", ""
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($remoteScriptLf))
    $sshArgs = @('machine','ssh',$MachineName,'--','bash','-lc',"set -euo pipefail; echo $encoded | base64 -d >/tmp/configure-gpu.sh; chmod +x /tmp/configure-gpu.sh; sudo /tmp/configure-gpu.sh")
    Invoke-Podman $sshArgs | Out-Null
}

function Test-PodmanGpu {
    Write-Host "🔍 Checking GPU devices inside the machine..." -ForegroundColor Yellow
    $cmd = 'bash -lc "ls -l /dev/dxg 2>/dev/null; ls -l /dev/nvidia* 2>/dev/null; nvidia-smi || true"'
    Invoke-Podman @('machine','ssh',$MachineName,'--',$cmd)
}

Confirm-PodmanCli
Reset-PodmanMachine
Initialize-PodmanMachine
Set-PodmanRootfulMode
Start-MachineIfNeeded
$osInfo = Get-OsRelease
$machineId = if ($osInfo.ContainsKey('ID') -and $osInfo['ID']) { $osInfo['ID'] } elseif ($osInfo.ContainsKey('ID_LIKE') -and $osInfo['ID_LIKE']) { $osInfo['ID_LIKE'] } elseif ($osInfo.ContainsKey('PRETTY_NAME') -and $osInfo['PRETTY_NAME']) { $osInfo['PRETTY_NAME'] } else { 'unknown' }
if ($machineId -notlike 'rocky*') {
    Write-Warning ("Machine reports ID='{0}'. Script was validated against Rocky Linux 10; adjust steps manually if your image differs." -f $machineId)
}

Write-Host "⚙️  Installing NVIDIA container runtime bits inside '$MachineName'..." -ForegroundColor Cyan
Install-NvidiaToolkit

if (-not $SkipReboot.IsPresent) {
    Write-Host "🔄 Restarting machine to finalize toolkit installation..." -ForegroundColor Cyan
    Invoke-Podman @('machine','stop',$MachineName) | Out-Null
    Invoke-Podman @('machine','start',$MachineName) | Out-Null
}

Test-PodmanGpu

Write-Host "✅ GPU configuration routine completed. Re-run your container helper (run.ps1 -GPUCheck) to validate from the workload container." -ForegroundColor Green
