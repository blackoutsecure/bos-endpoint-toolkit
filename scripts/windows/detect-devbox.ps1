#requires -Version 5.1
<#
.SYNOPSIS
Detects whether the Windows devbox remediation is installed and healthy.

.DESCRIPTION
Use this script as the detection script for Microsoft Intune Remediations. It
checks the ProgramData state root, version file, embedded worker, configured
live VHDX, backup path parent, and scheduled tasks.

.NOTES
Supported platform: Windows PowerShell 5.1 on Windows 10/11 endpoints.
Required privileges: run as SYSTEM or an administrator.
Safe to repeat: yes; this script is read-only.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ==================== CONFIGURABLE VARIABLES ====================
$DevboxName = 'devbox'
$RequiredVersion = '2.1.0'
$DevboxStateRoot = Join-Path $env:ProgramData $DevboxName
# ================================================================

$Problems = [System.Collections.Generic.List[string]]::new()

try {
    $ConfigPath = Join-Path $DevboxStateRoot 'config.json'
    $VersionPath = Join-Path $DevboxStateRoot 'version.txt'
    $WorkerPath = Join-Path $DevboxStateRoot 'devbox-worker.ps1'

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        $Problems.Add('CONFIG_MISSING')
    } else {
        try {
            $Config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
            if (-not (Test-Path -LiteralPath $Config.liveVhdx)) {
                $Problems.Add('LIVE_VHDX_MISSING')
            }
            if ([string]::IsNullOrWhiteSpace([string]$Config.backupRoot)) {
                $Problems.Add('BACKUP_ROOT_UNRESOLVED')
            } elseif (-not (Test-Path -LiteralPath (Split-Path $Config.backupRoot -Parent))) {
                $Problems.Add('BACKUP_ROOT_PARENT_UNAVAILABLE')
            }
        } catch {
            $Problems.Add('CONFIG_INVALID')
        }
    }

    if (-not (Test-Path -LiteralPath $WorkerPath)) {
        $Problems.Add('WORKER_MISSING')
    }

    if (-not (Test-Path -LiteralPath $VersionPath) -or (Get-Content -LiteralPath $VersionPath -Raw).Trim() -ne $RequiredVersion) {
        $Problems.Add('VERSION_MISMATCH')
    }

    foreach ($TaskName in @('devbox - mount at startup', 'devbox - nightly backup')) {
        $Task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($null -eq $Task) {
            $Problems.Add("TASK_MISSING:$TaskName")
        } elseif ($Task.State -eq 'Disabled') {
            $Problems.Add("TASK_DISABLED:$TaskName")
        }
    }

    if ($Problems.Count -gt 0) {
        Write-Output ('REMEDIATION_REQUIRED: ' + ($Problems -join ';'))
        exit 1
    }

    Write-Output "COMPLIANT: devbox $RequiredVersion"
    exit 0
} catch {
    Write-Output "DETECTION_ERROR: $($_.Exception.Message)"
    exit 1
}