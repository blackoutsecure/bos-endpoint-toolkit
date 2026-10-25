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
backup. Existing images and their ReFS data partitions grow to the configured
capacity on each remediation run (100 GB by default). Shrinking and reformatting
are never automatic.

.NOTES
Supported platform: Windows 11 endpoints where Format-Volume supports -DevDrive.
Required privileges: run as SYSTEM or an administrator. In Intune Remediations,
run using logged-on credentials: No, and use 64-bit PowerShell: Yes.
Safe to repeat: yes; install, repair, and upgrade converge on the configured
state. Use -WhatIf to preview state-changing work.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$DesiredConfigPath,
    [switch]$ShowConfiguration
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# >>> devbox:configuration >>>
. (Join-Path $PSScriptRoot 'configuration.ps1')
# <<< devbox:configuration <<<

try {
    $Desired = Get-DevboxConfiguration -Path $DesiredConfigPath
} catch {
    Write-Error "Desired configuration could not be resolved: $($_.Exception.Message)"
    exit 1
}
if ($ShowConfiguration) {
    $Desired | ConvertTo-Json -Depth 10
    exit 0
}
$DevboxVersion = $DevboxReleaseVersion
$DevboxName = $Desired.Values.name
$DevboxSizeGB = $Desired.Values.windows.sizeGiB
$DevboxVolumeLabel = $Desired.Values.windows.volumeLabel
$DevboxPreferredDriveLetters = $Desired.Values.windows.preferredDriveLetters
$DevboxBackupHour = $Desired.Values.backupHour
$DevboxBackupMinute = $Desired.Values.backupMinute
$DevboxRetention = $Desired.Values.retention
$DevboxStateRoot = Join-Path $env:ProgramData $DevboxName

$MachineName = $env:COMPUTERNAME.ToLowerInvariant()
$WorkerPath = Join-Path $DevboxStateRoot 'devbox-worker.ps1'
$ConfigPath = Join-Path $DevboxStateRoot 'config.json'
$VersionPath = Join-Path $DevboxStateRoot 'version.txt'
$LogRoot = Join-Path $DevboxStateRoot 'logs'
$LogPath = Join-Path $LogRoot 'devbox-remediation.log'
# >>> devbox:worker >>>
$WorkerSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'devbox-worker.ps1') -Raw
# <<< devbox:worker <<<

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

    foreach ($UserProfile in $Profiles) {
        $Key = "Registry::HKEY_USERS\$($UserProfile.SID)\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
        try {
            $Raw = (Get-ItemProperty -LiteralPath $Key -Name Personal -ErrorAction Stop).Personal
            $Documents = [Environment]::ExpandEnvironmentVariables(([string]$Raw).Replace('%USERPROFILE%', $UserProfile.LocalPath))
            if (Test-Path -LiteralPath $Documents -PathType Container) {
                return [pscustomobject]@{
                    sid = $UserProfile.SID
                    profile = $UserProfile.LocalPath
                    localAppData = (Join-Path $UserProfile.LocalPath 'AppData\Local')
                    documents = $Documents
                }
            }
        } catch {
            continue
        }
    }

    return $null
}

function Get-DevboxHostFreeSpace {
    param([string]$LiveVhdx)
    $Root = [IO.Path]::GetPathRoot($LiveVhdx)
    if ($Root -notmatch '^[A-Z]:\\$') { throw 'Devbox requires a local Windows backing volume.' }
    $Drive = Get-PSDrive -Name $Root.Substring(0, 1) -ErrorAction Stop
    if ($null -eq $Drive.Free) { throw "Free space could not be verified on backing volume $Root" }
    [uint64]$Drive.Free
}

function New-DevboxVhdx {
    [CmdletBinding(SupportsShouldProcess = $true)]
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
    if ((Get-DevboxHostFreeSpace -LiveVhdx $LiveVhdx) -lt ($DevboxSizeGB * 1GB)) {
        throw "Less than $DevboxSizeGB GiB free on the VHDX backing volume."
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
    Dismount-DiskImage -ImagePath $StageVhdx
    Move-Item -LiteralPath $StageVhdx -Destination $LiveVhdx
    Mount-DiskImage -ImagePath $LiveVhdx | Out-Null
}

function Initialize-DevboxWorkspace {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string]$LiveVhdx, [string[]]$Directories)

    if ($WhatIfPreference) {
        Write-DevboxLog "Would ensure configured workspace directories in $LiveVhdx after capacity reconciliation." 'INFO'
        return
    }
    $Layout = Get-DevboxResizeLayout -LiveVhdx $LiveVhdx
    $Letter = [string]$Layout.Partition.DriveLetter
    if ($Letter -notmatch '^[A-Z]$') {
        throw 'The verified Devbox data partition has no usable drive letter; resolve its mount before creating workspace directories.'
    }
    foreach ($Folder in $Directories) {
        $Path = "$Letter`:\$Folder"
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            throw "A file blocks the configured workspace directory: $Path"
        }
        if (-not (Test-Path -LiteralPath $Path -PathType Container) -and
            $PSCmdlet.ShouldProcess($Path, 'Ensure configured Devbox workspace directory')) {
            New-Item -ItemType Directory -Path $Path -Force | Out-Null
        }
    }
}

function Get-DevboxResizeLayout {
    param([string]$LiveVhdx)

    $Disks = @(Get-DiskImage -ImagePath $LiveVhdx | Get-Disk)
    if ($Disks.Count -ne 1) {
        throw 'Expected exactly one disk belonging to the Devbox VHDX.'
    }
    $Disk = $Disks[0]
    if ($Disk.BusType -ne 'File Backed Virtual' -or $Disk.PartitionStyle -ne 'GPT' -or
        $Disk.IsBoot -or $Disk.IsSystem -or $Disk.IsReadOnly) {
        throw 'Refusing to resize an unexpected, system, or read-only disk.'
    }
    $Partitions = @(Get-Partition -DiskNumber $Disk.Number | Sort-Object Offset)
    $DataPartitions = @($Partitions | Where-Object { $_.Type -eq 'Basic' })
    if ($DataPartitions.Count -ne 1 -or $Partitions[-1].PartitionNumber -ne $DataPartitions[0].PartitionNumber) {
        throw 'Expected one final data partition in the Devbox VHDX; no partition will be deleted.'
    }
    $Partition = $DataPartitions[0]
    $Volumes = @($Partition | Get-Volume)
    if ($Volumes.Count -ne 1 -or $Volumes[0].FileSystem -ne 'ReFS' -or
        $Volumes[0].FileSystemLabel -ne $DevboxVolumeLabel) {
        throw 'Expected the configured ReFS Devbox volume; refusing to reformat or resize another volume.'
    }
    $Supported = Get-PartitionSupportedSize -DiskNumber $Disk.Number -PartitionNumber $Partition.PartitionNumber
    if ([uint64]$Supported.SizeMax -eq 0) {
        throw 'Windows did not report a valid maximum size for the Devbox partition.'
    }
    [pscustomobject]@{ Disk = $Disk; Partition = $Partition; MaximumSize = [uint64]$Supported.SizeMax }
}

function Resize-DevboxVhdx {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string]$LiveVhdx)

    if ($LiveVhdx -match '["\r\n]' -or [IO.Path]::GetExtension($LiveVhdx) -ne '.vhdx') {
        throw 'Expected a VHDX path without quotes or newlines.'
    }
    foreach ($Command in 'diskpart.exe', 'Get-DiskImage', 'Mount-DiskImage', 'Dismount-DiskImage',
        'Get-Disk', 'Get-Partition', 'Get-Volume', 'Get-PartitionSupportedSize', 'Resize-Partition') {
        if (-not (Get-Command $Command -ErrorAction SilentlyContinue)) {
            throw "Required resize command unavailable: $Command"
        }
    }
    $TargetSize = [uint64]($DevboxSizeGB * 1GB)
    $BackupMutex = [Threading.Mutex]::new($false, 'Global\DEVBOX_BACKUP')
    $BackupHeld = $false
    $OriginalAttached = $false
    $AttachmentTouched = $false
    $DiskpartPath = $null
    try {
        $BackupHeld = $BackupMutex.WaitOne(0)
        if (-not $BackupHeld) {
            throw 'A Devbox backup is running. Capacity changes must wait until it finishes.'
        }
        $Image = Get-DiskImage -ImagePath $LiveVhdx
        $OriginalAttached = [bool]$Image.Attached
        if ([uint64]$Image.Size -eq 0) {
            throw 'Could not determine the virtual size of the Devbox VHDX.'
        }
        if ([uint64]$Image.Size -gt $TargetSize) {
            throw "The existing VHDX is larger than ${DevboxSizeGB}GB. Automatic shrinking is refused; increase the setting or migrate to a new image."
        }
        if (-not $Image.Attached) {
            if (-not $PSCmdlet.ShouldProcess($LiveVhdx, "Mount and reconcile existing ReFS capacity to ${DevboxSizeGB}GB")) {
                return
            }
            $AttachmentTouched = $true
            Mount-DiskImage -ImagePath $LiveVhdx | Out-Null
        }
        $Layout = Get-DevboxResizeLayout -LiveVhdx $LiveVhdx
        if ([uint64]$Image.Size -lt $TargetSize) {
            if (-not $PSCmdlet.ShouldProcess($LiveVhdx, "Detach, expand VHDX to ${DevboxSizeGB}GB, and grow its existing ReFS partition")) {
                return
            }
            $AttachmentTouched = $true
            Dismount-DiskImage -ImagePath $LiveVhdx
            if ((Get-DiskImage -ImagePath $LiveVhdx).Attached) {
                throw 'The VHDX could not be detached. Close files on Devbox and retry.'
            }
            $DiskpartPath = Join-Path $env:TEMP ("devbox-resize-{0}.txt" -f [guid]::NewGuid().ToString('N'))
            @(
                "select vdisk file=`"$LiveVhdx`"",
                "expand vdisk maximum=$($DevboxSizeGB * 1024)",
                'exit'
            ) | Set-Content -LiteralPath $DiskpartPath -Encoding Unicode
            $Output = & diskpart.exe /s $DiskpartPath 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "VHDX expansion failed: $($Output -join ' ')"
            }
            $Image = Get-DiskImage -ImagePath $LiveVhdx
            if ([uint64]$Image.Size -ne $TargetSize) {
                throw 'VHDX expansion did not reach the requested virtual capacity.'
            }
            Mount-DiskImage -ImagePath $LiveVhdx | Out-Null
            #Attachment can change the disk number; resolve the layout from the image path again.
            $Layout = Get-DevboxResizeLayout -LiveVhdx $LiveVhdx
        }
        if ([uint64]$Layout.Partition.Size -lt $Layout.MaximumSize) {
            if (-not $PSCmdlet.ShouldProcess($LiveVhdx, "Extend the existing ReFS partition to $($Layout.MaximumSize) bytes")) {
                return
            }
            Resize-Partition -DiskNumber $Layout.Disk.Number -PartitionNumber $Layout.Partition.PartitionNumber -Size $Layout.MaximumSize
            $Updated = Get-DevboxResizeLayout -LiveVhdx $LiveVhdx
            if ([uint64]$Updated.Partition.Size -lt $Updated.MaximumSize) {
                throw 'The image is enlarged but the ReFS partition is still too small. Rerun remediation; do not reformat it.'
            }
        }
        Write-DevboxLog "Devbox capacity is ${DevboxSizeGB}GB and its ReFS partition uses the available image space." 'SUCCESS'
    } catch {
        $ResizeError = $_
        if ($AttachmentTouched) {
            try {
                $AttachedNow = [bool](Get-DiskImage -ImagePath $LiveVhdx).Attached
                if ($OriginalAttached -and -not $AttachedNow) {
                    Mount-DiskImage -ImagePath $LiveVhdx | Out-Null
                } elseif (-not $OriginalAttached -and $AttachedNow) {
                    Dismount-DiskImage -ImagePath $LiveVhdx
                }
            } catch {
                throw "Capacity reconciliation failed: $($ResizeError.Exception.Message) Restoring the original attachment also failed: $($_.Exception.Message)"
            }
        }
        throw $ResizeError
    } finally {
        try {
            if ($DiskpartPath -and (Test-Path -LiteralPath $DiskpartPath)) {
                Remove-Item -LiteralPath $DiskpartPath -Force
            }
        } finally {
            if ($BackupHeld) { $BackupMutex.ReleaseMutex() }
            $BackupMutex.Dispose()
        }
    }
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
        Resize-DevboxVhdx -LiveVhdx $LiveVhdx
    }
    Initialize-DevboxWorkspace -LiveVhdx $LiveVhdx -Directories $Desired.Values.workspaceDirectories

    if ($PSCmdlet.ShouldProcess($DevboxStateRoot, 'Write devbox state, worker, and version files')) {
        New-Item -ItemType Directory -Path $DevboxStateRoot -Force | Out-Null
        Set-Content -LiteralPath "$WorkerPath.tmp" -Value $WorkerSource -Encoding UTF8
        Move-Item -LiteralPath "$WorkerPath.tmp" -Destination $WorkerPath -Force
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
        $DesiredPath = Join-Path $DevboxStateRoot 'desired-config.json'
        Set-Content -LiteralPath "$DesiredPath.tmp" -Value $Desired.Json -Encoding UTF8
        Move-Item -LiteralPath "$DesiredPath.tmp" -Destination $DesiredPath -Force
        Set-Content -LiteralPath "$VersionPath.tmp" -Value $DevboxVersion -Encoding ASCII
        Move-Item -LiteralPath "$VersionPath.tmp" -Destination $VersionPath -Force
    }

    $Principal = New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest
    $Settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -WakeToRun -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 8)
    $MountAction = New-ScheduledTaskAction -Execute powershell.exe -Argument (Get-DevboxWorkerArgument -WorkerPath $WorkerPath -StateRoot $DevboxStateRoot -Mode Mount)
    $MountTrigger = New-ScheduledTaskTrigger -AtStartup
    if ($PSCmdlet.ShouldProcess('devbox - mount at startup', 'Register scheduled task')) {
        Register-ScheduledTask -TaskName 'devbox - mount at startup' -Action $MountAction -Trigger $MountTrigger -Principal $Principal -Settings $Settings -Force | Out-Null
    }

    $BackupAction = New-ScheduledTaskAction -Execute powershell.exe -Argument (Get-DevboxWorkerArgument -WorkerPath $WorkerPath -StateRoot $DevboxStateRoot -Mode Backup)
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