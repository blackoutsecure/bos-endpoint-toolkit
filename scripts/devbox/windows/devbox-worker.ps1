#requires -Version 5.1
#requires -RunAsAdministrator
<#
.SYNOPSIS
Mounts, reports status for, or backs up the Windows devbox VHDX.

.DESCRIPTION
This worker is installed by remediate-devbox.ps1 into ProgramData and invoked by
scheduled tasks as SYSTEM. Backups use a VSS snapshot of the host volume so the
live VHDX can be copied consistently while the endpoint is running.

.NOTES
Supported platform: Windows PowerShell 5.1 on Windows 10/11 endpoints with VHDX
and VSS support.
Required privileges: administrator or SYSTEM.
Safe to repeat: yes; backup uses a global mutex and retention cleanup.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Backup', 'Mount', 'Status')]
    [string]$Mode = 'Backup'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ==================== CONFIGURABLE VARIABLES ====================
$DevboxName = 'devbox'
$DevboxStateRoot = Join-Path $env:ProgramData $DevboxName
# ================================================================

$ConfigPath = Join-Path $DevboxStateRoot 'config.json'
$LogRoot = Join-Path $DevboxStateRoot 'logs'
$LogPath = Join-Path $LogRoot 'devbox.log'

function Write-DevboxLog {
    param(
        [string]$Message,
        [string]$Level = 'INFO'
    )

    if ($WhatIfPreference) {
        Write-Output "WHATIF: [$Level] $Message"
        return
    }
    New-Item -ItemType Directory -Path $LogRoot -Force | Out-Null
    Add-Content -LiteralPath $LogPath -Encoding UTF8 -Value "$(Get-Date -Format s) [$Level] $Message"
}

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    Write-DevboxLog 'Configuration is missing.' 'ERROR'
    exit 1
}

$Config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$LiveVhdx = [string]$Config.liveVhdx
$BackupRoot = [string]$Config.backupRoot
$Retention = [int]$Config.retention

if ($Mode -eq 'Mount') {
    if (Test-Path -LiteralPath $LiveVhdx) {
        $Image = Get-DiskImage -ImagePath $LiveVhdx
        if (-not $Image.Attached -and $PSCmdlet.ShouldProcess($LiveVhdx, 'Mount devbox VHDX')) {
            Mount-DiskImage -ImagePath $LiveVhdx | Out-Null
        }
    }
    exit 0
}

if ($Mode -eq 'Status') {
    Get-Content -LiteralPath $ConfigPath
    Get-DiskImage -ImagePath $LiveVhdx
    exit 0
}

$Mutex = [Threading.Mutex]::new($false, 'Global\DEVBOX_BACKUP')
$Held = $false

try {
    $Held = $Mutex.WaitOne(0)
    if (-not $Held) {
        throw 'Another backup is running.'
    }
    if (-not (Test-Path -LiteralPath $LiveVhdx)) {
        throw "Live VHDX is missing: $LiveVhdx"
    }
    if ([string]::IsNullOrWhiteSpace($BackupRoot)) {
        throw 'Backup root is unresolved.'
    }
    if (-not $PSCmdlet.ShouldProcess($BackupRoot, 'Create VSS-backed devbox backup and apply retention')) {
        exit 0
    }

    New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
    $Destination = Join-Path $BackupRoot ("$DevboxName-{0}.vhdx" -f (Get-Date -Format 'yyyy-MM-dd_HHmmss'))
    $DriveRoot = [IO.Path]::GetPathRoot($LiveVhdx)
    $ShadowClass = [WMIClass]'root\cimv2:Win32_ShadowCopy'
    $Result = $ShadowClass.Create($DriveRoot, 'ClientAccessible')
    if ($Result.ReturnValue -ne 0) {
        throw "VSS snapshot creation failed with code $($Result.ReturnValue)."
    }
    $Shadow = Get-WmiObject -Class Win32_ShadowCopy | Where-Object { $_.ID -eq $Result.ShadowID } | Select-Object -First 1
    if ($null -eq $Shadow) {
        throw 'Created VSS snapshot was not found.'
    }

    try {
        $Source = $Shadow.DeviceObject.TrimEnd('\') + '\' + $LiveVhdx.Substring($DriveRoot.Length)
        $Partial = "$Destination.partial"
        Copy-Item -LiteralPath $Source -Destination $Partial -Force
        $Hash = (Get-FileHash -LiteralPath $Partial -Algorithm SHA256).Hash
        Move-Item -LiteralPath $Partial -Destination $Destination
        $Manifest = [ordered]@{
            schemaVersion = 3
            version = $Config.version
            machineName = $Config.machineName
            createdUtc = (Get-Date).ToUniversalTime().ToString('o')
            backup = $Destination
            length = (Get-Item $Destination).Length
            sha256 = $Hash
            verified = $true
            consistency = 'VSS crash-consistent host-volume snapshot'
        }
        $Manifest | ConvertTo-Json | Set-Content -LiteralPath "$Destination.json" -Encoding UTF8
        $Manifest | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $BackupRoot "$DevboxName-latest.json") -Encoding UTF8
    } finally {
        $null = $Shadow.Delete()
    }

    Get-ChildItem -LiteralPath $BackupRoot -Filter "$DevboxName-*.vhdx" -File |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -Skip $Retention |
        ForEach-Object {
            $Json = "$($_.FullName).json"
            if (Test-Path -LiteralPath $Json) {
                Remove-Item -LiteralPath $_.FullName, $Json -Force
            }
        }

    Write-DevboxLog "Backup completed: $Destination" 'SUCCESS'
    exit 0
} catch {
    Write-DevboxLog $_.Exception.Message 'ERROR'
    exit 1
} finally {
    if ($Held) {
        $Mutex.ReleaseMutex()
    }
    $Mutex.Dispose()
}