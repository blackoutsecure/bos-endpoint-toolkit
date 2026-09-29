#Dependency-free tests: storage operations are mocked; no real disks or tasks are used.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$SourcePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'remediate-devbox.ps1'
$DetectionPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'detect-devbox.ps1'
$Tokens = $null
$ParseErrors = $null
$Ast = [System.Management.Automation.Language.Parser]::ParseFile($SourcePath, [ref]$Tokens, [ref]$ParseErrors)
if ($ParseErrors.Count) { throw ($ParseErrors | Out-String) }
foreach ($Name in 'Get-DevboxResizeLayout', 'Resize-DevboxVhdx') {
    $Function = $Ast.Find({ param($Node) $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq $Name }, $true)
    if (-not $Function) { throw "Missing function: $Name" }
    . ([scriptblock]::Create($Function.Extent.Text))
}

$Work = Join-Path ([IO.Path]::GetTempPath()) ("devbox-resize-tests-" + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $Work
$SavedTemp = $env:TEMP
$SavedProgramData = $env:ProgramData
$env:TEMP = $Work
$env:ProgramData = $Work
$LiveVhdx = Join-Path $Work 'fixture.vhdx'
Set-Content -LiteralPath $LiveVhdx -Value 'Never passed to a real disk tool.'
$DevboxSizeGB = 100
$DevboxVolumeLabel = 'devbox'
$State = $null

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Get-TestState {
    param([uint64]$Size = 50GB, [bool]$Attached = $true)
    @{
        Size = $Size; PartitionSize = $Size - 17MB; Attached = $Attached; DiskNumber = 8
        BusType = 'File Backed Virtual'; FileSystem = 'ReFS'; VolumeLabel = $DevboxVolumeLabel
        IsSystem = $false; MultiplePartitions = $false; FailDetach = $false; FailInspection = $false
        FailExpand = $false; FailResize = $false; Calls = [System.Collections.Generic.List[string]]::new()
        Logs = [System.Collections.Generic.List[string]]::new()
    }
}

function Write-DevboxLog { param($Message, $Level) $State.Logs.Add("[$Level] $Message") }
function Get-DiskImage {
    param($ImagePath)
    Assert-True ($ImagePath -eq $LiveVhdx) 'An unexpected image path was queried.'
    if ($State.FailInspection) { throw 'Mock disk image inspection failure.' }
    [pscustomobject]@{ Size = $State.Size; Attached = $State.Attached }
}
function Mount-DiskImage {
    param($ImagePath)
    Assert-True ($ImagePath -eq $LiveVhdx) 'An unexpected image path was mounted.'
    $State.Calls.Add('mount')
    $State.Attached = $true
    $State.DiskNumber++
}
function Dismount-DiskImage {
    param($ImagePath)
    Assert-True ($ImagePath -eq $LiveVhdx) 'An unexpected image path was detached.'
    $State.Calls.Add('detach')
    if ($State.FailDetach) { throw 'Mock busy disk.' }
    $State.Attached = $false
}
function Get-Disk {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline = $true)]$InputObject)
    process {
        Assert-True ($State.Attached -and $InputObject.Attached) 'Disk inspection requires the mock image to be attached.'
        [pscustomobject]@{
            Number = $State.DiskNumber; BusType = $State.BusType
            PartitionStyle = 'GPT'; IsBoot = $false; IsSystem = $State.IsSystem; IsReadOnly = $false
        }
    }
}
function Get-Partition {
    param($DiskNumber)
    Assert-True ($DiskNumber -eq $State.DiskNumber) 'A stale disk number was used.'
    [pscustomobject]@{ PartitionNumber = 1; Offset = 1MB; Size = 16MB; Type = 'Reserved' }
    [pscustomobject]@{ PartitionNumber = 2; Offset = 17MB; Size = $State.PartitionSize; Type = 'Basic' }
    if ($State.MultiplePartitions) {
        [pscustomobject]@{ PartitionNumber = 3; Offset = 60GB; Size = 1GB; Type = 'Basic' }
    }
}
function Get-Volume {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline = $true)]$InputObject)
    process {
        Assert-True ($InputObject.PartitionNumber -eq 2) 'Wrong partition queried for its filesystem.'
        [pscustomobject]@{ FileSystem = $State.FileSystem; FileSystemLabel = $State.VolumeLabel }
    }
}
function Get-PartitionSupportedSize {
    param($DiskNumber, $PartitionNumber)
    Assert-True ($DiskNumber -eq $State.DiskNumber -and $PartitionNumber -eq 2) 'Wrong resize target.'
    [pscustomobject]@{ SizeMax = $State.Size - 17MB }
}
function Resize-Partition {
    param($DiskNumber, $PartitionNumber, $Size)
    Assert-True ($DiskNumber -eq $State.DiskNumber -and $PartitionNumber -eq 2) 'Wrong partition resized.'
    $State.Calls.Add('resize-partition')
    if ($State.FailResize) { throw 'Mock ReFS resize failure.' }
    $State.PartitionSize = $Size
}
function diskpart.exe {
    param($Switch, $ScriptPath)
    Assert-True ($Switch -eq '/s' -and -not $State.Attached) 'DiskPart must receive a detached image.'
    $Commands = Get-Content -LiteralPath $ScriptPath -Raw
    Assert-True ($Commands.Contains("select vdisk file=`"$LiveVhdx`"")) 'Wrong VHDX selected.'
    Assert-True ($Commands -notmatch '(?m)^\s*(create|format|delete|clean)\b') 'Resize must not recreate or erase anything.'
    $State.Calls.Add('expand-vhdx')
    $global:LASTEXITCODE = 0
    if ($State.FailExpand) { $global:LASTEXITCODE = 5; return }
    Assert-True ($Commands -match 'expand vdisk maximum=(\d+)') 'Expansion command missing.'
    $State.Size = [uint64]$Matches[1] * 1MB
}
function Get-ScheduledTask {
    [CmdletBinding()]
    param($TaskName)
    Assert-True ($TaskName -in @('devbox - mount at startup', 'devbox - nightly backup')) 'Unexpected task queried.'
    [pscustomobject]@{ State = 'Ready' }
}

try {
    Assert-True ((Get-Content $SourcePath -Raw) -match '\$DevboxSizeGB = 100') 'Remediation default is not 100 GB.'
    Assert-True ((Get-Content $DetectionPath -Raw) -match '\$DevboxSizeGB = 100') 'Detection target is not 100 GB.'
    $State = Get-TestState
    Resize-DevboxVhdx -LiveVhdx $LiveVhdx -WhatIf
    Assert-True ($State.Calls.Count -eq 0 -and $State.Size -eq 50GB) '-WhatIf mutated storage.'
    $State = Get-TestState -Attached $false
    Resize-DevboxVhdx -LiveVhdx $LiveVhdx -WhatIf
    Assert-True ($State.Calls.Count -eq 0 -and -not $State.Attached) '-WhatIf attached an image.'
    $State = Get-TestState -Size 100GB
    $State.PartitionSize = 50GB - 17MB
    Resize-DevboxVhdx -LiveVhdx $LiveVhdx -WhatIf
    Assert-True ($State.Calls.Count -eq 0 -and $State.PartitionSize -eq (50GB - 17MB)) '-WhatIf extended a partition.'
    Write-Output 'PASS mounted and detached WhatIf paths perform no storage mutations'

    $State = Get-TestState
    Resize-DevboxVhdx -LiveVhdx $LiveVhdx
    Assert-True ($State.Size -eq ($DevboxSizeGB * 1GB) -and $State.PartitionSize -eq (100GB - 17MB)) 'Image and ReFS capacity did not grow.'
    Assert-True ($State.Attached -and ($State.Calls -join ',') -eq 'detach,expand-vhdx,mount,resize-partition') 'Unexpected resize sequence.'
    $State.Calls.Clear()
    Resize-DevboxVhdx -LiveVhdx $LiveVhdx
    Assert-True ($State.Calls.Count -eq 0) 'A second run repeated storage changes.'
    Write-Output 'PASS growth and repeat-run no-op, using a freshly resolved disk number'

    $State = Get-TestState -Attached $false
    $DevboxSizeGB = 125
    Resize-DevboxVhdx -LiveVhdx $LiveVhdx
    Assert-True ($State.Size -eq 125GB -and $State.PartitionSize -eq (125GB - 17MB) -and $State.Attached) 'A custom capacity or initial detached state was ignored.'
    $State.Calls.Clear()
    Resize-DevboxVhdx -LiveVhdx $LiveVhdx
    Assert-True ($State.Calls.Count -eq 0) 'Custom capacity did not converge.'
    $DevboxSizeGB = 100
    Write-Output 'PASS custom capacity grows a detached image and is idempotent'

    $State = Get-TestState -Size 150GB
    $Refused = $false
    try { Resize-DevboxVhdx -LiveVhdx $LiveVhdx } catch { $Refused = $_.Exception.Message -match 'shrinking is refused' }
    Assert-True ($Refused -and $State.Calls.Count -eq 0) 'A shrink request was not safely rejected.'
    Write-Output 'PASS shrinking is refused without storage changes'

    $State = Get-TestState
    $State.FailExpand = $true
    $Failed = $false
    try { Resize-DevboxVhdx -LiveVhdx $LiveVhdx } catch { $Failed = $_.Exception.Message -match 'expansion failed' }
    Assert-True ($Failed -and $State.Attached -and $State.Size -eq 50GB) 'Failed expansion did not restore original attachment.'
    Assert-True (@(Get-ChildItem $Work -Filter 'devbox-resize-*.txt').Count -eq 0) 'DiskPart temporary file leaked.'
    Write-Output 'PASS failed image growth restores attachment and cleans its temporary file'

    $State = Get-TestState -Attached $false
    $State.FailExpand = $true
    $Failed = $false
    try { Resize-DevboxVhdx -LiveVhdx $LiveVhdx } catch { $Failed = $_.Exception.Message -match 'expansion failed' }
    Assert-True ($Failed -and -not $State.Attached -and $State.Size -eq 50GB) 'A failed resize left an originally detached image attached.'

    $State = Get-TestState
    $State.FailDetach = $true
    $Failed = $false
    try { Resize-DevboxVhdx -LiveVhdx $LiveVhdx } catch { $Failed = $_.Exception.Message -match 'busy disk' }
    Assert-True ($Failed -and $State.Attached -and $State.Size -eq 50GB -and ($State.Calls -join ',') -eq 'detach') 'Busy disk handling attempted growth or changed attachment.'
    Write-Output 'PASS detached failure recovery and busy disks do not change capacity'

    $State = Get-TestState
    $State.FailResize = $true
    $Failed = $false
    try { Resize-DevboxVhdx -LiveVhdx $LiveVhdx } catch { $Failed = $_.Exception.Message -match 'ReFS resize failure' }
    Assert-True ($Failed -and $State.Size -eq 100GB -and $State.Attached) 'Partial growth was hidden or detached the existing image.'
    $State.FailResize = $false
    $State.Calls.Clear()
    Resize-DevboxVhdx -LiveVhdx $LiveVhdx
    Assert-True (($State.Calls -join ',') -eq 'resize-partition') 'Repair repeated VHDX growth instead of finishing the partition.'
    Write-Output 'PASS partial filesystem growth is repaired safely on the next run'

    foreach ($Unsafe in 'physical', 'filesystem', 'system', 'partitions', 'label') {
        $State = Get-TestState
        switch ($Unsafe) {
            'physical' { $State.BusType = 'SATA' }
            'filesystem' { $State.FileSystem = 'NTFS' }
            'system' { $State.IsSystem = $true }
            'partitions' { $State.MultiplePartitions = $true }
            'label' { $State.VolumeLabel = 'unrelated' }
        }
        $Failed = $false
        try { Resize-DevboxVhdx -LiveVhdx $LiveVhdx } catch { $Failed = $true }
        Assert-True ($Failed -and $State.Calls.Count -eq 0) "An unsafe $Unsafe layout was accepted."
    }
    Write-Output 'PASS disk identity and ReFS checks remain mandatory'

    $State = Get-TestState
    $Ready = [Threading.ManualResetEvent]::new($false)
    $Release = [Threading.ManualResetEvent]::new($false)
    $Locker = [powershell]::Create()
    $null = $Locker.AddScript({
        param($Ready, $Release)
        $Mutex = [Threading.Mutex]::new($false, 'Global\DEVBOX_BACKUP')
        $Held = $false
        try {
            $Held = $Mutex.WaitOne(0)
            if (-not $Held) { throw 'The test backup mutex is already held.' }
            $null = $Ready.Set()
            $null = $Release.WaitOne(15000)
        } finally {
            if ($Held) { $Mutex.ReleaseMutex() }
            $Mutex.Dispose()
        }
    }).AddArgument($Ready).AddArgument($Release)
    $Pending = $Locker.BeginInvoke()
    try {
        Assert-True ($Ready.WaitOne(10000)) 'Could not establish the simulated backup lock.'
        $Failed = $false
        try { Resize-DevboxVhdx -LiveVhdx $LiveVhdx } catch { $Failed = $_.Exception.Message -match 'backup is running' }
        Assert-True ($Failed -and $State.Calls.Count -eq 0) 'Capacity reconciliation ignored an active backup.'
    } finally {
        $null = $Release.Set()
        $null = $Locker.EndInvoke($Pending)
        $Locker.Dispose()
        $Ready.Dispose()
        $Release.Dispose()
    }
    Write-Output 'PASS active backup mutex blocks image and partition changes'

    $StateRoot = Join-Path $Work 'devbox'
    $null = New-Item -ItemType Directory -Path $StateRoot
    @{ liveVhdx = $LiveVhdx; backupRoot = (Join-Path $Work 'backups') } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $StateRoot 'config.json')
    Set-Content -LiteralPath (Join-Path $StateRoot 'version.txt') -Value '2.1.0'
    Set-Content -LiteralPath (Join-Path $StateRoot 'devbox-worker.ps1') -Value 'fixture'
    $ExpectedCodes = @{
        small = 'CAPACITY_BELOW_TARGET'; partition = 'VOLUME_CAPACITY_BELOW_MAXIMUM'
        detached = 'VOLUME_CAPACITY_UNVERIFIED'; large = 'CAPACITY_SHRINK_UNSUPPORTED'
        inspection = 'CAPACITY_CHECK_FAILED'; layout = 'VOLUME_LAYOUT_UNEXPECTED'
    }
    foreach ($Case in 'small', 'partition', 'detached', 'large', 'inspection', 'layout', 'ready') {
        $State = Get-TestState -Size 100GB
        if ($Case -eq 'small') { $State.Size = 50GB; $State.PartitionSize = 50GB - 17MB }
        if ($Case -eq 'partition') { $State.PartitionSize = 50GB - 17MB }
        if ($Case -eq 'detached') { $State.Attached = $false }
        if ($Case -eq 'large') { $State.Size = 150GB; $State.PartitionSize = 150GB - 17MB }
        if ($Case -eq 'inspection') { $State.FailInspection = $true }
        if ($Case -eq 'layout') { $State.MultiplePartitions = $true }
        $Output = & $DetectionPath
        if ($Case -eq 'ready') {
            Assert-True ($LASTEXITCODE -eq 0 -and "$Output" -match 'COMPLIANT:') "Ready capacity is not compliant: $Output (exit $LASTEXITCODE)."
        } else {
            Assert-True ($LASTEXITCODE -eq 1 -and "$Output" -eq "REMEDIATION_REQUIRED: $($ExpectedCodes[$Case])") "Detection missed $Case capacity: $Output."
        }
        Assert-True ($State.Calls.Count -eq 0) 'Detection mutated storage.'
    }
    Write-Output 'PASS detection reports drift, incomplete growth, and shrink conflicts without mutation'
} finally {
    $env:TEMP = $SavedTemp
    $env:ProgramData = $SavedProgramData
    Remove-Item -LiteralPath $Work -Recurse -Force
}
