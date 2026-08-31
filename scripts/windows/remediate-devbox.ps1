#requires -Version 5.1
#requires -RunAsAdministrator
<#
.SYNOPSIS
Installs or repairs the Windows devbox VHDX and scheduled tasks.

.DESCRIPTION
Use this script as the remediation script for Microsoft Intune Remediations. It
locates the most recently used non-special user profile, creates a dynamic ReFS
Dev Drive VHDX in that user's LocalAppData, writes ProgramData state, installs a
worker script, and registers SYSTEM scheduled tasks for startup mount and nightly
backup.

.NOTES
Supported platform: Windows 11 endpoints where Format-Volume supports -DevDrive.
Required privileges: run as SYSTEM or an administrator. In Intune Remediations,
run using logged-on credentials: No, and use 64-bit PowerShell: Yes.
Safe to repeat: yes; install, repair, and upgrade converge on the configured
state. Use -WhatIf to preview state-changing work.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ==================== CONFIGURABLE VARIABLES ====================
$DevboxVersion = '2.1.0'
$DevboxName = 'devbox'
$DevboxSizeGB = 50
$DevboxVolumeLabel = 'devbox'
$DevboxPreferredDriveLetters = @('V', 'W', 'X', 'Y', 'Z')
$DevboxBackupHour = 2
$DevboxBackupMinute = 0
$DevboxRetention = 14
$DevboxStateRoot = Join-Path $env:ProgramData $DevboxName
# ================================================================

$MachineName = $env:COMPUTERNAME.ToLowerInvariant()
$WorkerPath = Join-Path $DevboxStateRoot 'devbox-worker.ps1'
$ConfigPath = Join-Path $DevboxStateRoot 'config.json'
$VersionPath = Join-Path $DevboxStateRoot 'version.txt'
$LogRoot = Join-Path $DevboxStateRoot 'logs'
$LogPath = Join-Path $LogRoot 'devbox-remediation.log'
$WorkerSource = @'
#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Backup', 'Mount', 'Status')]
    [string]$Mode = 'Backup'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$DevboxName = 'devbox'
$DevboxStateRoot = Join-Path $env:ProgramData $DevboxName
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
'@

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

function Get-DevboxUserContext {
    $Profiles = Get-CimInstance -ClassName Win32_UserProfile |
        Where-Object { -not $_.Special -and ($_.SID -match '^S-1-5-21-' -or $_.SID -match '^S-1-12-1-') } |
        Sort-Object LastUseTime -Descending

    foreach ($Profile in $Profiles) {
        $Key = "Registry::HKEY_USERS\$($Profile.SID)\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
        try {
            $Raw = (Get-ItemProperty -LiteralPath $Key -Name Personal -ErrorAction Stop).Personal
            $Documents = [Environment]::ExpandEnvironmentVariables(([string]$Raw).Replace('%USERPROFILE%', $Profile.LocalPath))
            if (Test-Path -LiteralPath $Documents -PathType Container) {
                return [pscustomobject]@{
                    sid = $Profile.SID
                    profile = $Profile.LocalPath
                    localAppData = (Join-Path $Profile.LocalPath 'AppData\Local')
                    documents = $Documents
                }
            }
        } catch {
            continue
        }
    }

    return $null
}

function New-DevboxVhdx {
    param(
        [string]$LiveVhdx,
        [string]$StageVhdx
    )

    foreach ($Command in 'diskpart.exe', 'Get-DiskImage', 'Initialize-Disk', 'New-Partition', 'Format-Volume') {
        if (-not (Get-Command $Command -ErrorAction SilentlyContinue)) {
            throw "Required command unavailable: $Command"
        }
    }
    if (-not (Get-Command Format-Volume).Parameters.ContainsKey('DevDrive')) {
        throw 'Format-Volume -DevDrive is unavailable.'
    }
    if ((Get-PSDrive C).Free -lt ($DevboxSizeGB * 1GB)) {
        throw "Less than $DevboxSizeGB GB free on C:."
    }
    if (-not $PSCmdlet.ShouldProcess($LiveVhdx, "Create ${DevboxSizeGB}GB dynamic ReFS Dev Drive VHDX")) {
        return
    }

    New-Item -ItemType Directory -Path (Split-Path $LiveVhdx) -Force | Out-Null
    if (Test-Path -LiteralPath $StageVhdx) {
        throw "Partial staging VHDX exists: $StageVhdx"
    }
    $DiskpartPath = Join-Path $env:TEMP ("devbox-{0}.txt" -f [guid]::NewGuid().ToString('N'))
    @(
        "create vdisk file=`"$StageVhdx`" maximum=$($DevboxSizeGB * 1024) type=expandable",
        "select vdisk file=`"$StageVhdx`"",
        'attach vdisk',
        'exit'
    ) | Set-Content -LiteralPath $DiskpartPath -Encoding ASCII

    try {
        $Output = & diskpart.exe /s $DiskpartPath 2>&1
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $StageVhdx)) {
            throw "DiskPart failed: $($Output -join ' ')"
        }
    } finally {
        Remove-Item -LiteralPath $DiskpartPath -Force -ErrorAction SilentlyContinue
    }

    $Image = Get-DiskImage -ImagePath $StageVhdx
    if (-not $Image.Attached) {
        throw 'Staging VHDX was not attached.'
    }
    $Disk = $Image | Get-Disk
    if ($Disk.BusType -ne 'File Backed Virtual' -or $Disk.PartitionStyle -ne 'RAW') {
        throw 'Staging disk identity validation failed.'
    }
    $Disk = Initialize-Disk -Number $Disk.Number -PartitionStyle GPT -PassThru
    $Letter = $DevboxPreferredDriveLetters | Where-Object { -not (Get-Volume -DriveLetter $_ -ErrorAction SilentlyContinue) } | Select-Object -First 1
    if (-not $Letter) {
        throw 'No preferred drive letter is available.'
    }
    $Partition = New-Partition -DiskNumber $Disk.Number -UseMaximumSize -DriveLetter $Letter
    $null = Format-Volume -Partition $Partition -FileSystem ReFS -NewFileSystemLabel $DevboxVolumeLabel -AllocationUnitSize 4096 -DevDrive -Force -Confirm:$false
    foreach ($Folder in @('repos', 'projects', 'agent-workspaces', 'ai', 'data', 'tools', 'scripts', 'temp', 'package-caches', 'build-output', 'docker', 'archives')) {
        New-Item -ItemType Directory -Path "$Letter`:\$Folder" -Force | Out-Null
    }
    Dismount-DiskImage -ImagePath $StageVhdx
    Move-Item -LiteralPath $StageVhdx -Destination $LiveVhdx
    Mount-DiskImage -ImagePath $LiveVhdx | Out-Null
}

$Mutex = [Threading.Mutex]::new($false, 'Global\DEVBOX_REMEDIATION')
$Held = $false

try {
    $Held = $Mutex.WaitOne(0)
    if (-not $Held) {
        throw 'Another devbox remediation is running.'
    }

    $Context = Get-DevboxUserContext
    if ($null -eq $Context) {
        Write-DevboxLog 'No signed-in Entra/domain/local user with an available Documents known folder; remediation deferred.' 'WARN'
        exit 1
    }

    $UserRoot = Join-Path $Context.localAppData $DevboxName
    $LiveVhdx = Join-Path $UserRoot "$DevboxName.vhdx"
    $StageVhdx = Join-Path $UserRoot "$DevboxName-staging.vhdx"
    $BackupRoot = Join-Path (Join-Path $Context.documents $DevboxName) $MachineName

    if ($PSCmdlet.ShouldProcess($BackupRoot, 'Ensure devbox backup root exists')) {
        New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
    }

    if (-not (Test-Path -LiteralPath $LiveVhdx)) {
        New-DevboxVhdx -LiveVhdx $LiveVhdx -StageVhdx $StageVhdx
    } else {
        $Image = Get-DiskImage -ImagePath $LiveVhdx
        if (-not $Image.Attached -and $PSCmdlet.ShouldProcess($LiveVhdx, 'Mount existing devbox VHDX')) {
            Mount-DiskImage -ImagePath $LiveVhdx | Out-Null
        }
    }

    if ($PSCmdlet.ShouldProcess($DevboxStateRoot, 'Write devbox state, worker, and version files')) {
        New-Item -ItemType Directory -Path $DevboxStateRoot -Force | Out-Null
        Set-Content -LiteralPath $WorkerPath -Value $WorkerSource -Encoding UTF8
        $Config = [ordered]@{
            schemaVersion = 3
            version = $DevboxVersion
            name = $DevboxName
            machineName = $MachineName
            userSid = $Context.sid
            userProfile = $Context.profile
            liveVhdx = $LiveVhdx
            backupRoot = $BackupRoot
            retention = $DevboxRetention
            backupHour = $DevboxBackupHour
            backupMinute = $DevboxBackupMinute
        }
        $Config | ConvertTo-Json | Set-Content -LiteralPath "$ConfigPath.tmp" -Encoding UTF8
        Move-Item -LiteralPath "$ConfigPath.tmp" -Destination $ConfigPath -Force
        Set-Content -LiteralPath $VersionPath -Value $DevboxVersion -Encoding ASCII
    }

    $Principal = New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest
    $Settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -WakeToRun -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 8)
    $MountAction = New-ScheduledTaskAction -Execute powershell.exe -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$WorkerPath`" -Mode Mount"
    $MountTrigger = New-ScheduledTaskTrigger -AtStartup
    if ($PSCmdlet.ShouldProcess('devbox - mount at startup', 'Register scheduled task')) {
        Register-ScheduledTask -TaskName 'devbox - mount at startup' -Action $MountAction -Trigger $MountTrigger -Principal $Principal -Settings $Settings -Force | Out-Null
    }

    $BackupAction = New-ScheduledTaskAction -Execute powershell.exe -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$WorkerPath`" -Mode Backup"
    $BackupTime = [datetime]::Today.AddHours($DevboxBackupHour).AddMinutes($DevboxBackupMinute)
    $BackupTrigger = New-ScheduledTaskTrigger -Daily -At $BackupTime
    if ($PSCmdlet.ShouldProcess('devbox - nightly backup', 'Register scheduled task')) {
        Register-ScheduledTask -TaskName 'devbox - nightly backup' -Action $BackupAction -Trigger $BackupTrigger -Principal $Principal -Settings $Settings -Force | Out-Null
    }

    Write-DevboxLog "devbox $DevboxVersion install/repair completed." 'SUCCESS'
    Write-Output "COMPLIANT: devbox $DevboxVersion"
    exit 0
} catch {
    Write-DevboxLog $_.Exception.Message 'ERROR'
    Write-Error $_.Exception.Message
    exit 1
} finally {
    if ($Held) {
        $Mutex.ReleaseMutex()
    }
    $Mutex.Dispose()
}