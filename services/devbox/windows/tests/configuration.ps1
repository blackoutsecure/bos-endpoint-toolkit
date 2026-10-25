# Configuration tests use only private temporary files, never endpoint storage or tasks.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
$DetectionPath = Join-Path $RepositoryRoot 'output\devbox\windows\detect-devbox.ps1'
$Tokens = $null
$Errors = $null
$Ast = [Management.Automation.Language.Parser]::ParseFile($DetectionPath, [ref]$Tokens, [ref]$Errors)
if ($Errors.Count) { throw ($Errors | Out-String) }
foreach ($Node in $Ast.EndBlock.Statements) {
    if ($Node -is [Management.Automation.Language.AssignmentStatementAst] -and
        $Node.Left.Extent.Text -in @('$DevboxReleaseVersion', '$DevboxDefaultsJson', '$DevboxConfigurationFields')) {
        . ([scriptblock]::Create($Node.Extent.Text))
    }
    if ($Node -is [Management.Automation.Language.FunctionDefinitionAst]) {
        . ([scriptblock]::Create($Node.Extent.Text))
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$Work = Join-Path ([IO.Path]::GetTempPath()) ('bos-devbox-config-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $Work
$SavedProgramData = $env:ProgramData
$env:ProgramData = $Work
try {
    $Resolved = Get-DevboxConfiguration
    Assert-True ($Resolved.Source -eq 'packaged defaults') 'Unexpected source for a fresh configuration.'
    Assert-True ($Resolved.Values.windows.sizeGiB -eq 100 -and $Resolved.Values.macos.sizeGB -eq 100) 'Native capacity defaults changed.'
    $ProfilePath = Join-Path $Work 'profile.json'
    Set-Content -LiteralPath $ProfilePath -Value '{"schemaVersion":1.0,"retention":21.0,"windows":{"sizeGiB":200.0}}'
    $Resolved = Get-DevboxConfiguration -Path $ProfilePath
    Assert-True ($Resolved.Values.retention -eq 21 -and $Resolved.Values.windows.sizeGiB -eq 200) 'Explicit profile was ignored.'
    Assert-True ($Resolved.Values.windows.volumeLabel -eq 'devbox' -and $Resolved.Values.macos.sizeGB -eq 100) 'Profile merge lost unrelated defaults.'
    $Installed = Join-Path $Work 'devbox'
    $null = New-Item -ItemType Directory -Path $Installed
    Set-Content -LiteralPath (Join-Path $Installed 'desired-config.json') -Value $Resolved.Json
    $Reloaded = Get-DevboxConfiguration
    Assert-True ($Reloaded.Values.retention -eq 21 -and $Reloaded.Values.windows.sizeGiB -eq 200) 'Installed desired configuration was not reloaded.'
    Write-Output 'PASS packaged defaults, partial profile merge, and persisted desired configuration'

    foreach ($Json in @(
        '{}', 'null', '[]', '[{"schemaVersion":1}]', '[{"schemaVersion":1},null]',
        '{"schemaVersion":2}', '{"schemaVersion":"1"}',
        '{"schemaVersion":1,"retension":14}', '{"schemaVersion":1,"name":"../escape"}',
        '{"schemaVersion":1,"name":"devbox\n"}',
        '{"schemaVersion":1,"windows":{"volumeLabel":"devbox\n"}}',
        '{"schemaVersion":1,"workspaceDirectories":["repos\n"]}',
        '{"schemaVersion":1,"backupHour":24}', '{"schemaVersion":1,"retention":1.5}',
        '{"schemaVersion":1,"retention":"14"}', '{"schemaVersion":1,"retention":null}',
        '{"schemaVersion":1,"macos":null}', '{"schemaVersion":1,"macos":{"hideVolume":"true"}}',
        '{"schemaVersion":1,"workspaceDirectories":["repos","repos"]}',
        '{"schemaVersion":1,"workspaceDirectories":["../repos"]}',
        '{"schemaVersion":1,"windows":{"sizeGiB":49}}',
        '{"schemaVersion":1,"windows":{"sizeGB":100}}',
        '{"schemaVersion":1,"windows":{"preferredDriveLetters":["v"]}}'
    )) {
        Set-Content -LiteralPath $ProfilePath -Value $Json
        $Rejected = $false
        try { $null = Get-DevboxConfiguration -Path $ProfilePath } catch { $Rejected = $true }
        Assert-True $Rejected "An invalid configuration was accepted: $Json"
    }
    $Rejected = $false
    try { $null = Get-DevboxConfiguration -Path (Join-Path $Work 'missing.json') } catch { $Rejected = $true }
    Assert-True $Rejected 'An explicitly missing configuration silently fell back to defaults.'
    Write-Output 'PASS invalid, unsupported, unknown, unsafe, missing, and incorrectly typed configuration fails explicitly'

    $Arguments = Get-DevboxWorkerArgument -WorkerPath 'C:\ProgramData\devbox\devbox-worker.ps1' -StateRoot 'C:\ProgramData\devbox' -Mode Backup
    Assert-True ($Arguments -match '-StateRoot "C:\\ProgramData\\devbox" -Mode Backup$') 'Task arguments do not preserve the state root.'
    $Rejected = $false
    try { $null = Get-DevboxWorkerArgument -WorkerPath 'C:\bad"path.ps1' -StateRoot 'C:\state' -Mode Backup } catch { $Rejected = $true }
    Assert-True $Rejected 'Unsafe worker argument path was accepted.'
    Write-Output 'PASS scheduled worker arguments are explicit and reject malformed paths'
} finally {
    $env:ProgramData = $SavedProgramData
    Remove-Item -LiteralPath $Work -Recurse -Force
}
