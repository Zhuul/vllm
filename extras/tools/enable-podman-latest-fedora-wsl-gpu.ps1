#Requires -Version 7.0

<#
.SYNOPSIS
    Simplified Podman machine setup for Windows with WSL2 GPU support
.DESCRIPTION
    This script manages a Podman machine (podman-machine-default) with NVIDIA GPU support.
    Based on: https://kubecoin.io/install-podman-desktop-windows-fedora-gpu
.PARAMETER Reset
    (Deprecated) Use -Install or -Remove instead
.PARAMETER Install
    Create podman-machine-default if it does not exist (no removal). If it exists, do nothing.
.PARAMETER Update
    Update GPU configuration in existing machine
.PARAMETER Remove
    Completely remove podman-machine-default
.PARAMETER CpuCount
    Number of CPU cores to allocate (default: auto)
.PARAMETER MemoryGB
    Amount of memory in GB to allocate (default: auto)
.EXAMPLE
    .\enable-podman-latest-fedora-wsl-gpu.ps1
    # Creates podman-machine-default with GPU support
.EXAMPLE
    .\enable-podman-latest-fedora-wsl-gpu.ps1 -Install -CpuCount 8 -MemoryGB 16
    # Creates machine with custom resources (no removal)
.EXAMPLE
    .\enable-podman-latest-fedora-wsl-gpu.ps1 -Update
    # Updates GPU configuration on existing machine
.EXAMPLE
    .\enable-podman-latest-fedora-wsl-gpu.ps1 -Remove
    # Removes the machine completely
.NOTES
    - Requires Windows 11 with WSL2
    - Requires NVIDIA GPU with drivers installed
    - Requires Podman Desktop or Podman CLI for Windows
    - Only affects podman-machine-default
#>

param(
    [switch]$Install,
    [switch]$Update,
    [switch]$Remove,
    [string]$CpuCount = 'auto',
    [string]$MemoryGB = 'auto',
    [string]$PodmanPath = ''
)

# Back-compat: map deprecated -Reset to -Install if present in $PSBoundParameters
if ($PSBoundParameters.ContainsKey('Reset')) {
    Write-Warning "-Reset is deprecated. Use -Install (create) or -Remove (delete) instead. Proceeding as -Install."
    $Install = $true
}

$MachineName = "podman-machine-default"
$script:ElevatedLaunchDone = $false

#region Helper Functions

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Start-Elevated {
    param([string]$Reason)
    if (Test-Administrator) { return }
    if ($script:ElevatedLaunchDone) { return }
    Write-Host "⚠️  Elevation required: $Reason" -ForegroundColor Yellow
    $scriptPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
    if (-not (Test-Path $scriptPath)) { throw "Unable to locate script path for elevation ($scriptPath)." }
    $argsList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath)
    if ($Install)  { $argsList += '-Install' }
    if ($Update) { $argsList += '-Update' }
    if ($Remove) { $argsList += '-Remove' }
    if ($CpuCount) { $argsList += @('-CpuCount', $CpuCount) }
    if ($MemoryGB) { $argsList += @('-MemoryGB', $MemoryGB) }
    # Capture current podman path for elevated context
    $podExe = (Get-Command podman -ErrorAction SilentlyContinue)?.Source
    if ($podExe) { $argsList += @('-PodmanPath', $podExe) }
    $script:ElevatedLaunchDone = $true
    Start-Process -FilePath "pwsh.exe" -ArgumentList $argsList -Verb RunAs -WorkingDirectory (Get-Location) -Wait | Out-Null
    exit 0
}

function Get-DefaultCpuCount {
    $logical = [Environment]::ProcessorCount
    # Leave at least 1 core for host; minimum 2 cores for the VM
    $suggested = [Math]::Max(2, $logical - 1)
    return $suggested
}

function Get-DefaultMemoryGB {
    try {
        $sys = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $totalBytes = [double]$sys.TotalPhysicalMemory
        $totalGB = [Math]::Floor($totalBytes / 1GB)
        # Allocate ~50% of RAM to the VM, but not less than 8GB
        $half = [Math]::Floor($totalGB * 0.5)
        return [int]([Math]::Max(8, $half))
    } catch {
        # Fallback to 8GB if detection fails
        return 8
    }
}

function Resolve-IntParam {
    param(
        [Parameter(Mandatory)] [string]$Value,
        [Parameter(Mandatory)] [int]$Default
    )
    if ($Value -eq 'auto' -or [string]::IsNullOrWhiteSpace($Value)) { return $Default }
    if ($Value -as [int]) {
        $v = [int]$Value
        if ($v -le 0) { return $Default }
        return $v
    }
    return $Default
}

function Get-PodmanPath {
    if ($PodmanPath -and (Test-Path $PodmanPath)) { return $PodmanPath }
    $cmd = Get-Command podman -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { return $cmd.Source }
    throw "'podman' CLI not found. Please install Podman Desktop or Podman CLI for Windows and ensure it's on PATH."
}

function Invoke-Podman {
    param(
        [Parameter(ValueFromRemainingArguments=$true)]
        [string[]]$Args
    )
    $exe = Get-PodmanPath
    & $exe @Args
}

function Test-PodmanMachine {
    param([string]$Name)
    try {
        $null = Invoke-Podman machine inspect $Name --format '{{.Name}}' 2>$null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

function Remove-PodmanMachine {
    param([string]$Name)
    if ($Name -ne $MachineName) {
        throw "Safety guard: refusing to remove machine '$Name'. This script only manages '$MachineName'."
    }
    
    Write-Host "🗑️  Removing Podman machine '$Name'..." -ForegroundColor Yellow
    
    # Stop if running
    Invoke-Podman machine stop $Name 2>$null
    
    # Remove machine (this also unregisters WSL distro)
    Invoke-Podman machine rm -f $Name 2>$null
    
    Write-Host "✅ Machine removed" -ForegroundColor Green
}

function Initialize-PodmanMachine {
    param(
        [string]$Name,
        [int]$CpuCount,
        [int]$MemoryGB
    )
    
    Write-Host "🚀 Initializing Podman machine '$Name'..." -ForegroundColor Cyan
    Write-Host "   CPU: $CpuCount cores, Memory: ${MemoryGB}GB" -ForegroundColor DarkGray
    
    $memoryMB = $MemoryGB * 1024
    
    # Initialize machine with GPU support
    # Using --now to start immediately
    $initOutput = Invoke-Podman machine init $Name --cpus $CpuCount --memory $memoryMB --now 2>&1
    $exit = $LASTEXITCODE
    if ($exit -ne 0) {
        Write-Host $initOutput -ForegroundColor Yellow
        throw "Failed to initialize Podman machine (exit $exit)"
    }
    Write-Host "✅ Podman machine initialized and started" -ForegroundColor Green
    # Show machine list summary for visibility
    try { Invoke-Podman machine list --format "table {{.Name}}\t{{.Running}}\t{{.VMType}}" | Out-Host } catch {}
}

function Wait-PodmanMachineRunning {
    param([string]$Name,[int]$TimeoutSec=60)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        try {
            $running = Invoke-Podman machine inspect $Name --format '{{.Running}}' 2>$null | Select-Object -First 1
            if ($running -and $running.Trim().ToLower() -eq 'true') { return $true }
        } catch {}
        Start-Sleep -Seconds 2
    }
    return $false
}

function Wait-PodmanMachineStopped {
    param([string]$Name,[int]$TimeoutSec=60)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        try {
            $running = Invoke-Podman machine inspect $Name --format '{{.Running}}' 2>$null | Select-Object -First 1
            if (-not $running -or $running.Trim().ToLower() -ne 'true') { return $true }
        } catch { return $true }
        Start-Sleep -Seconds 2
    }
    return $false
}
function Update-GpuSupport {
    param([string]$Name)
    Write-Host "🔧 Updating GPU support in machine '$Name'..." -ForegroundColor Cyan
    $remote = @'
set -euo pipefail

sudo mkdir -p /usr/lib/wsl
if [ ! -e /usr/lib/wsl/lib ] && [ -d /mnt/c/Windows/System32/nvidia-cuda ]; then
    sudo ln -sf /mnt/c/Windows/System32/nvidia-cuda /usr/lib/wsl/lib
fi
if [ ! -e /usr/lib/wsl/drivers ] && [ -d /mnt/c/Windows/System32/DriverStore/FileRepository ]; then
    sudo ln -sf /mnt/c/Windows/System32/DriverStore/FileRepository /usr/lib/wsl/drivers
fi

if ! rpm -q dnf-plugins-core >/dev/null 2>&1; then
    sudo dnf install -y dnf-plugins-core
fi

if [ ! -f /etc/yum.repos.d/nvidia-container-toolkit.repo ]; then
    echo "Configuring NVIDIA Container Toolkit repo..."
    sudo tee /etc/yum.repos.d/nvidia-container-toolkit.repo >/dev/null <<'EOR'
[nvidia-container-toolkit]
name=NVIDIA Container Toolkit
baseurl=https://nvidia.github.io/libnvidia-container/stable/rpm/$basearch
enabled=1
gpgcheck=1
gpgkey=https://nvidia.github.io/libnvidia-container/gpgkey
EOR
fi

if ! command -v nvidia-ctk >/dev/null 2>&1; then
    echo "Installing nvidia-container-toolkit..."
    sudo dnf install -y nvidia-container-toolkit
fi

sudo mkdir -p /etc/cdi /var/cdi /var/run/cdi
echo "Generating CDI spec (mode=wsl)..."
sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml --mode=wsl
sudo cp -f /etc/cdi/nvidia.yaml /var/cdi/nvidia.yaml
sudo cp -f /etc/cdi/nvidia.yaml /var/run/cdi/nvidia.yaml

if command -v nvidia-smi >/dev/null 2>&1; then
    true
elif [ -x /usr/lib/wsl/drivers/nvidia-smi ]; then
    sudo ln -sf /usr/lib/wsl/drivers/nvidia-smi /usr/local/bin/nvidia-smi || sudo ln -sf /usr/lib/wsl/drivers/nvidia-smi /usr/bin/nvidia-smi
elif [ -x /usr/lib/wsl/lib/nvidia-smi ]; then
    sudo ln -sf /usr/lib/wsl/lib/nvidia-smi /usr/local/bin/nvidia-smi || sudo ln -sf /usr/lib/wsl/lib/nvidia-smi /usr/bin/nvidia-smi
fi

sudo mkdir -p /usr/lib64
for lib in /usr/lib/wsl/lib/*.so*; do
    if [ -f "$lib" ] && [ ! -e "/usr/lib64/$(basename "$lib")" ]; then
        sudo ln -sf "$lib" "/usr/lib64/$(basename "$lib")"
    fi
done

echo '✅ GPU configuration updated'
'@
    $remoteLf = $remote -replace "`r",""
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($remoteLf))
    $sshArgs = @('machine','ssh',$Name,'--','bash','-lc',"set -euo pipefail; echo $encoded | base64 -d >/tmp/configure-gpu.sh; chmod +x /tmp/configure-gpu.sh; sudo /tmp/configure-gpu.sh")
    $remoteOut = Invoke-Podman $sshArgs 2>&1
    $remoteOut | Out-Host
    $exit = $LASTEXITCODE
    if ($exit -ne 0) {
        Write-Host "❌ GPU update failed (exit code $exit)." -ForegroundColor Red
        return $false
    }
    Write-Host "✅ GPU support updated" -ForegroundColor Green
    return $true
}

function Test-GpuAccess {
    param([string]$Name)
    Write-Host "🧪 Testing GPU access..." -ForegroundColor Cyan
    Write-Host "🧪 Testing GPU access in VM (nvidia-smi)..." -ForegroundColor Cyan
    $vmResult = (Invoke-Podman machine ssh $Name -- nvidia-smi 2>&1)
    $vmOk = ($LASTEXITCODE -eq 0 -and $vmResult -match 'CUDA Version')
    if ($vmOk) {
        Write-Host "✅ GPU detected in VM!" -ForegroundColor Green
        Write-Host $vmResult -ForegroundColor DarkGray
    } else {
        Write-Host "⚠️  GPU access test in VM failed. Output:" -ForegroundColor Yellow
        Write-Host $vmResult -ForegroundColor Red
    }
    Write-Host "🧪 Testing GPU access in Podman container..." -ForegroundColor Cyan
    $containerResult = (Invoke-Podman run --rm --device nvidia.com/gpu=all nvidia/cuda:12.5.1-base-ubuntu22.04 nvidia-smi 2>&1)
    $ctrOk = ($LASTEXITCODE -eq 0 -and $containerResult -match 'CUDA Version')
    if ($ctrOk) {
        Write-Host "✅ GPU detected in Podman container!" -ForegroundColor Green
        Write-Host $containerResult -ForegroundColor DarkGray
        return $true
    } else {
        Write-Host "⚠️  GPU access test in Podman container failed. Output:" -ForegroundColor Yellow
        Write-Host $containerResult -ForegroundColor Red
        Write-Host "You may need to run with -Update, check Windows/WSL NVIDIA drivers, or verify CDI spec paths." -ForegroundColor Yellow
        return $false
    }
}

#endregion

#region Main Script

try {
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  Podman Machine GPU Setup (Windows)" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
    
    # Verify podman CLI is available (supports -PodmanPath override)
    $null = Get-PodmanPath
    Write-Host ("Admin: {0}" -f (Test-Administrator)) -ForegroundColor DarkGray
    Write-Host ("Podman: {0}" -f (Get-PodmanPath)) -ForegroundColor DarkGray
    
    # Handle Remove operation
    if ($Remove) {
        $exists = Test-PodmanMachine -Name $MachineName
        if ($exists -and -not (Test-Administrator)) {
            Start-Elevated -Reason "Removing Podman machine requires administrative privileges"
        }
        if ($exists) {
            Remove-PodmanMachine -Name $MachineName
            Write-Host ""
            Write-Host "✅ Machine '$MachineName' removed successfully" -ForegroundColor Green
        } else {
            Write-Host "ℹ️  Machine '$MachineName' does not exist" -ForegroundColor DarkGray
        }
        exit 0
    }
    
    # Handle Install operation (create only if missing)
    if ($Install) {
        $exists = Test-PodmanMachine -Name $MachineName
        if ($exists) {
            Write-Host "ℹ️  Machine '$MachineName' already exists; nothing to do. Use -Update for GPU config or -Remove to delete." -ForegroundColor Yellow
            exit 0
        }
        # Fall through to creation flow below
    }
    
    # Check if machine exists
    $machineExists = Test-PodmanMachine -Name $MachineName
    
    # Handle Update operation
    if ($Update) {
        if (-not $machineExists) {
            throw "Machine '$MachineName' does not exist. Create it first without -Update flag."
        }
        
        $gpuOk = Update-GpuSupport -Name $MachineName
        if (-not $gpuOk) {
            Write-Host "⏳ Waiting for machine to stop after reboot..." -ForegroundColor Cyan
            if (-not (Wait-PodmanMachineStopped -Name $MachineName -TimeoutSec 120)) {
                Write-Host "⚠️  Machine did not stop in time; attempting to continue." -ForegroundColor Yellow
            }
            Write-Host "🔄 Starting machine again..." -ForegroundColor Cyan
            Invoke-Podman machine start $MachineName | Out-Null
            if (-not (Wait-PodmanMachineRunning -Name $MachineName -TimeoutSec 120)) {
                Write-Host "⚠️  Machine did not start in time; continuing anyway." -ForegroundColor Yellow
            }
            $null = Update-GpuSupport -Name $MachineName
        }
        Test-GpuAccess -Name $MachineName
        
        Write-Host ""
        Write-Host "✅ GPU support updated on '$MachineName'" -ForegroundColor Green
        exit 0
    }
    
    # Create new machine if it doesn't exist
    if ($Install -and $machineExists) {
        Write-Host "ℹ️  Machine '$MachineName' already exists; nothing to do. Use -Update for GPU config or -Remove to delete." -ForegroundColor Yellow
        exit 0
    }
    if (-not $machineExists) {
        Write-Host "🎯 Creating Podman machine '$MachineName' with GPU support" -ForegroundColor White
        Write-Host ""
        # Resolve auto CPU/Memory
        $resolvedCpu = Resolve-IntParam -Value $CpuCount -Default (Get-DefaultCpuCount)
        $resolvedMem = Resolve-IntParam -Value $MemoryGB -Default (Get-DefaultMemoryGB)
        Write-Host ("Using resources -> CPU: {0} cores, Memory: {1} GB" -f $resolvedCpu, $resolvedMem) -ForegroundColor DarkGray
        Initialize-PodmanMachine -Name $MachineName -CpuCount $resolvedCpu -MemoryGB $resolvedMem
        
        Write-Host ""
        Write-Host "⏳ Waiting for machine to be ready..." -ForegroundColor Cyan
        if (-not (Wait-PodmanMachineRunning -Name $MachineName -TimeoutSec 30)) {
            Write-Host "⚠️  Machine not reported as Running within timeout; proceeding anyway." -ForegroundColor Yellow
        }
        
        # Configure GPU support
        $gpuOk2 = Update-GpuSupport -Name $MachineName
        if (-not $gpuOk2) {
            Write-Host "⏳ Waiting for machine to stop after reboot..." -ForegroundColor Cyan
            if (-not (Wait-PodmanMachineStopped -Name $MachineName -TimeoutSec 120)) {
                Write-Host "⚠️  Machine did not stop in time; attempting to continue." -ForegroundColor Yellow
            }
            Write-Host "🔄 Starting machine again..." -ForegroundColor Cyan
            Invoke-Podman machine start $MachineName | Out-Null
            if (-not (Wait-PodmanMachineRunning -Name $MachineName -TimeoutSec 120)) {
                Write-Host "⚠️  Machine did not start in time; continuing anyway." -ForegroundColor Yellow
            }
            $null = Update-GpuSupport -Name $MachineName
        }
        
        # Test GPU
        Test-GpuAccess -Name $MachineName
        
        Write-Host ""
        Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Green
        Write-Host "  ✅ Setup Complete!" -ForegroundColor Green
        Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Green
        Write-Host ""
        Write-Host "🎉 Podman machine '$MachineName' is ready!" -ForegroundColor Green
        Write-Host ""
        Write-Host "Next steps:" -ForegroundColor Cyan
        Write-Host "  1. Test GPU in container:" -ForegroundColor White
        Write-Host "     podman run --rm --device nvidia.com/gpu=all nvidia/cuda:12.5.1-base-ubuntu22.04 nvidia-smi" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "  2. SSH into machine:" -ForegroundColor White
        Write-Host "     podman machine ssh $MachineName" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "  3. Stop machine:" -ForegroundColor White
        Write-Host "     podman machine stop $MachineName" -ForegroundColor DarkGray
        Write-Host ""
        
    } else {
        Write-Host "ℹ️  Machine '$MachineName' already exists" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Options:" -ForegroundColor Cyan
        Write-Host "  -Reset   : Recreate the machine" -ForegroundColor White
        Write-Host "  -Update  : Update GPU configuration" -ForegroundColor White
        Write-Host "  -Remove  : Delete the machine" -ForegroundColor White
        Write-Host ""
    }
    
} catch {
    Write-Host ""
    Write-Host "❌ Error: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    exit 1
}

#endregion
