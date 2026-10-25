#requires -Version 5.1
<#
.SYNOPSIS
Detects whether the Windows devbox remediation is installed and healthy.

.DESCRIPTION
Use this script as the detection script for Microsoft Intune Remediations. It
checks the ProgramData state root, version file, embedded worker, configured
live VHDX and configured capacity, backup path parent, and scheduled tasks.

.NOTES
Supported platform: Windows PowerShell 5.1 on Windows 10/11 endpoints.
Required privileges: run as SYSTEM or an administrator.
Safe to repeat: yes; this script is read-only.
#>

[CmdletBinding()]
param(
    [string]$DesiredConfigPath,
    [switch]$ShowConfiguration
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# >>> devbox:configuration >>>
. (Join-Path $PSScriptRoot 'configuration.ps1')
# <<< devbox:configuration <<<

function Test-DevboxScheduledTask {
    param(
        $Task,
        [ValidateSet('Mount', 'Backup')][string]$Mode,
        [string]$ExpectedArguments,
        [int]$BackupHour,
        [int]$BackupMinute
    )
    foreach ($Property in @('Actions', 'Triggers', 'Principal')) {
        if ($null -eq $Task.PSObject.Properties[$Property]) { return $false }
    }
    $Actions = @($Task.Actions)
    $Triggers = @($Task.Triggers)
    if ($Actions.Count -ne 1 -or $null -eq $Actions[0] -or
        $Triggers.Count -ne 1 -or $null -eq $Triggers[0] -or $null -eq $Task.Principal) {
        return $false
    }
    $Action = $Actions[0]
    foreach ($Property in @('Execute', 'Arguments')) {
        if ($null -eq $Action.PSObject.Properties[$Property]) { return $false }
    }
    foreach ($Property in @('UserId', 'LogonType', 'RunLevel')) {
        if ($null -eq $Task.Principal.PSObject.Properties[$Property]) { return $false }
    }
    if ($Action.Execute -ine 'powershell.exe' -or $Action.Arguments -cne $ExpectedArguments -or
        $Task.Principal.UserId -notin @('SYSTEM', 'S-1-5-18', 'NT AUTHORITY\SYSTEM') -or
        $Task.Principal.LogonType -ne 'ServiceAccount' -or $Task.Principal.RunLevel -ne 'Highest') {
        return $false
    }
    $Trigger = $Triggers[0]
    foreach ($Property in @('Enabled', 'CimClass')) {
        if ($null -eq $Trigger.PSObject.Properties[$Property]) { return $false }
    }
    if (-not $Trigger.Enabled -or $null -eq $Trigger.CimClass -or
        $null -eq $Trigger.CimClass.PSObject.Properties['CimClassName']) {
        return $false
    }
    if ($Mode -eq 'Mount') { return $Trigger.CimClass.CimClassName -eq 'MSFT_TaskBootTrigger' }
    if ($Trigger.CimClass.CimClassName -ne 'MSFT_TaskDailyTrigger') { return $false }
    foreach ($Property in @('DaysInterval', 'StartBoundary')) {
        if ($null -eq $Trigger.PSObject.Properties[$Property]) { return $false }
    }
    $Time = [datetimeoffset]::MinValue
    if (-not [datetimeoffset]::TryParse([string]$Trigger.StartBoundary, [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeLocal, [ref]$Time)) {
        return $false
    }
    $LocalTime = $Time.LocalDateTime
    return $Trigger.DaysInterval -eq 1 -and $LocalTime.Hour -eq $BackupHour -and
        $LocalTime.Minute -eq $BackupMinute -and $LocalTime.Second -eq 0
}

$Problems = [System.Collections.Generic.List[string]]::new()

try {
    $Desired = Get-DevboxConfiguration -Path $DesiredConfigPath
    if ($ShowConfiguration) {
        $Desired | ConvertTo-Json -Depth 10
        exit 0
    }
    $DevboxName = $Desired.Values.name
    $RequiredVersion = $DevboxReleaseVersion
    $DevboxSizeGB = $Desired.Values.windows.sizeGiB
    $DevboxStateRoot = Join-Path $env:ProgramData $DevboxName
    $ConfigPath = Join-Path $DevboxStateRoot 'config.json'
    $VersionPath = Join-Path $DevboxStateRoot 'version.txt'
    $WorkerPath = Join-Path $DevboxStateRoot 'devbox-worker.ps1'

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        $Problems.Add('CONFIG_MISSING')
    } else {
        try {
            $Config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
            foreach ($Key in @('name', 'retention', 'backupHour', 'backupMinute')) {
                if ($Config.$Key -cne $Desired.Values.$Key) { $Problems.Add("CONFIG_DRIFT:$Key") }
            }
            if (-not (Test-Path -LiteralPath $Config.liveVhdx)) {
                $Problems.Add('LIVE_VHDX_MISSING')
            } else {
                try {
                    $Image = Get-DiskImage -ImagePath $Config.liveVhdx
                    $TargetSize = [uint64]($DevboxSizeGB * 1GB)
                    if ([uint64]$Image.Size -lt $TargetSize) {
                        $Problems.Add('CAPACITY_BELOW_TARGET')
                    } elseif ([uint64]$Image.Size -gt $TargetSize) {
                        $Problems.Add('CAPACITY_SHRINK_UNSUPPORTED')
                    }
                    if (-not $Image.Attached) {
                        $Problems.Add('VOLUME_CAPACITY_UNVERIFIED')
                    } else {
                        $Disk = $Image | Get-Disk
                        $DataPartitions = @(Get-Partition -DiskNumber $Disk.Number | Where-Object { $_.Type -eq 'Basic' })
                        if ($DataPartitions.Count -ne 1) {
                            $Problems.Add('VOLUME_LAYOUT_UNEXPECTED')
                        } else {
                            $Supported = Get-PartitionSupportedSize -DiskNumber $Disk.Number -PartitionNumber $DataPartitions[0].PartitionNumber
                            if ([uint64]$Supported.SizeMax -eq 0) {
                                $Problems.Add('VOLUME_CAPACITY_UNVERIFIED')
                            } elseif ([uint64]$DataPartitions[0].Size -lt [uint64]$Supported.SizeMax) {
                                $Problems.Add('VOLUME_CAPACITY_BELOW_MAXIMUM')
                            }
                        }
                    }
                } catch {
                    $Problems.Add('CAPACITY_CHECK_FAILED')
                }
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
        } else {
            $Mode = if ($TaskName -eq 'devbox - mount at startup') { 'Mount' } else { 'Backup' }
            $ExpectedArguments = Get-DevboxWorkerArgument -WorkerPath $WorkerPath -StateRoot $DevboxStateRoot -Mode $Mode
            if (-not (Test-DevboxScheduledTask -Task $Task -Mode $Mode -ExpectedArguments $ExpectedArguments `
                -BackupHour $Desired.Values.backupHour -BackupMinute $Desired.Values.backupMinute)) {
                $Problems.Add("TASK_DRIFT:$TaskName")
            }
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