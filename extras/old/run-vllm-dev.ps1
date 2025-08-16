#!/usr/bin/env pwsh
# Deprecated: please use extras/podman/run.ps1. This script forwards for back-compat.
param([Parameter(ValueFromRemainingArguments=$true)] [string[]]$Args)
$pod = Join-Path $PSScriptRoot 'podman\run.ps1'
if (-not (Test-Path $pod)) { Write-Error "Missing: $pod"; exit 1 }
& $pod @Args
