#requires -Version 5.1
# Native task objects are constructed in memory only; no task is registered or read.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module ScheduledTasks -ErrorAction Stop

$SourcePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'detect-devbox.ps1'
$Tokens = $null
$Errors = $null
$Ast = [System.Management.Automation.Language.Parser]::ParseFile($SourcePath, [ref]$Tokens, [ref]$Errors)
if ($Errors.Count) { throw ($Errors | Out-String) }
$Function = $Ast.Find({
    param($Node)
    $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq 'Test-DevboxScheduledTask'
}, $true)
if ($null -eq $Function) { throw 'The scheduled-task validator is missing.' }
. ([scriptblock]::Create($Function.Extent.Text))

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$Arguments = '-NoProfile -File "C:\fixture\worker.ps1" -Mode Backup'
$Action = New-ScheduledTaskAction -Execute powershell.exe -Argument $Arguments
$Principal = New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest
$Daily = New-ScheduledTaskTrigger -Daily -At ([datetime]::Today.AddHours(2))
$Task = New-ScheduledTask -Action $Action -Principal $Principal -Trigger $Daily
$Parameters = @{ Mode = 'Backup'; ExpectedArguments = $Arguments; BackupHour = 2; BackupMinute = 0 }
Assert-True (Test-DevboxScheduledTask -Task $Task @Parameters) 'A healthy native daily task was rejected.'

$Boundary = [datetimeoffset]::Parse($Task.Triggers[0].StartBoundary, [Globalization.CultureInfo]::InvariantCulture)
foreach ($Offset in @([timespan]::Zero, [timespan]::FromMinutes(330), [timespan]::FromHours(-7))) {
    $Task.Triggers[0].StartBoundary = $Boundary.ToOffset($Offset).ToString('o')
    Assert-True (Test-DevboxScheduledTask -Task $Task @Parameters) 'An equivalent timezone-qualified schedule was reported as drift.'
}
$Task.Triggers[0].StartBoundary = $Boundary.LocalDateTime.ToString('s')
Assert-True (Test-DevboxScheduledTask -Task $Task @Parameters) 'An unqualified local schedule was rejected.'
Write-Output 'PASS native CIM task properties and UTC, offset, and local scheduling representations'

$Task.Triggers[0].StartBoundary = $Boundary.AddHours(1).ToString('o')
Assert-True (-not (Test-DevboxScheduledTask -Task $Task @Parameters)) 'An incorrect local backup hour was accepted.'
$Task.Triggers[0].StartBoundary = $Boundary.AddSeconds(30).ToString('o')
Assert-True (-not (Test-DevboxScheduledTask -Task $Task @Parameters)) 'An incorrect scheduled second was accepted.'
$Task.Triggers[0].StartBoundary = 'invalid-timestamp'
Assert-True (-not (Test-DevboxScheduledTask -Task $Task @Parameters)) 'An invalid schedule was accepted.'

$Boot = New-ScheduledTask -Action $Action -Principal $Principal -Trigger (New-ScheduledTaskTrigger -AtStartup)
Assert-True (-not (Test-DevboxScheduledTask -Task $Boot @Parameters)) 'A boot trigger was accepted as a daily backup.'
$Parameters.Mode = 'Mount'
Assert-True (Test-DevboxScheduledTask -Task $Boot @Parameters) 'A healthy native boot task was rejected.'
$Boot.Triggers[0].Enabled = $false
Assert-True (-not (Test-DevboxScheduledTask -Task $Boot @Parameters)) 'A disabled native trigger was accepted.'
Write-Output 'PASS native wrong-trigger, malformed-time, disabled-trigger, and schedule-drift rejection; no tasks registered'
