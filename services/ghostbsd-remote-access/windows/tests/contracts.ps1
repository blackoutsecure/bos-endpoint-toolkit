param([Parameter(Mandatory = $true)][string]$ScriptPath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Tokens = $null
$Errors = $null
$Ast = [Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$Tokens, [ref]$Errors)
if ($Errors.Count) { throw ($Errors | Out-String) }
foreach ($Function in $Ast.FindAll({ param($Node) $Node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    . ([scriptblock]::Create($Function.Extent.Text))
}
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern)
    $Caught = $false
    try { & $Action } catch {
        if ($_ -notmatch $Pattern) { throw }
        $Caught = $true
    }
    if (-not $Caught) { throw "Expected failure matching $Pattern" }
}

$ComputerName = '127.0.0.1'
$UserName = 'fixture'
$SshPort = 2222
$LocalRdpPort = 13389
$VMName = 'Fixture VM'
$IdentityFile = ''
$PublicKeyPath = ''
$GenerateKey = $false
$Platform = ''
$KeysOnly = $false
$KeyTested = $false
$RemoteAccessDefaults = [pscustomobject]@{ platform = 'auto'; sshPort = 22; rdpPort = 3389; videoMemoryMiB = 128 }
$RemoteAccessGuestBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("exit 0`n"))

Assert-Throws { Invoke-RemoteAccessNative -FilePath (Get-Command powershell.exe).Source -Arguments @('-NoProfile', '-NonInteractive', '-Command', 'exit 7') } 'Native command failed \(7\)'
Assert-True ((ConvertTo-RemoteAccessNativeArgument 'C:\with spaces\') -ceq '"C:\with spaces\\"') 'Trailing backslashes were not preserved in a quoted native argument.'
Assert-True ((ConvertTo-RemoteAccessNativeArgument 'a"b') -ceq '"a\"b"') 'Native quotes were not escaped.'
Assert-True ((ConvertTo-RemoteAccessNativeArgument '') -ceq '""') 'An empty native argument was lost.'
Assert-True ((ConvertTo-RemoteAccessShellLiteral "a'b") -ceq ("'a'" + '"' + "'" + '"' + "'b'")) 'Remote shell literals are not single-quote safe.'
Assert-Throws { Get-RemoteAccessSshArguments -Target '-oBad' -Account fixture -Port 22 } 'safe host'
Assert-Throws { Get-RemoteAccessSshArguments -Target localhost -Account root -Port 22 } 'non-root'
Assert-Throws { Get-RemoteAccessSshArguments -Target localhost -Account 'x;bad' -Port 22 } 'non-root'
Assert-Throws { Get-RemoteAccessSshArguments -Target localhost -Account fixture -Port 0 } 'valid SSH port'
$Arguments = @(Get-RemoteAccessSshArguments -Target localhost -Account fixture -Port 22)
Assert-True ($Arguments -contains 'StrictHostKeyChecking=yes') 'Host trust was weakened.'
Assert-True ($Arguments -contains 'BatchMode=yes') 'Unattended SSH unexpectedly permits password prompts.'

$script:Calls = [Collections.Generic.List[object]]::new()
$script:VM = @{
    VMState = 'poweroff'; graphicscontroller = 'vboxvga'; vram = '16'; monitorcount = '2'
    accelerate3d = 'on'; vrde = 'on'; memory = '4096'; cpus = '2'; nic1 = 'nat'
    'Forwarding(7)' = 'unrelated,tcp,127.0.0.1,8080,,80'
}
function Get-RemoteAccessTool { param([string]$Name) return "mock-$Name" }
function Get-RemoteAccessIdentity { return '' }
function Invoke-RemoteAccessNative {
    param([string]$FilePath, [string[]]$Arguments, [switch]$Capture)
    $script:Calls.Add([pscustomobject]@{ File = $FilePath; Arguments = $Arguments })
    if ($Arguments[0] -eq 'showvminfo') {
        foreach ($Key in $script:VM.Keys) { "$Key=`"$($script:VM[$Key])`"" }
        return
    }
    if ($Arguments[0] -ne 'modifyvm') { throw 'An unexpected native mutation was attempted.' }
    for ($Index = 2; $Index -lt $Arguments.Count; $Index += 2) {
        if ($Arguments[$Index] -eq '--natpf1') { $script:VM['Forwarding(8)'] = $Arguments[$Index + 1] }
        else { $script:VM[$Arguments[$Index].Substring(2)] = $Arguments[$Index + 1] }
    }
}
function Start-Process { throw 'Process launch is prohibited in this mock suite.' }
function Stop-Process { throw 'Process termination is prohibited in this mock suite.' }

Set-RemoteAccessVirtualBox -WhatIf
Assert-True (@($script:Calls | Where-Object { $_.Arguments[0] -eq 'modifyvm' }).Count -eq 0) 'WhatIf changed a VM.'
$script:VM.VMState = 'running'
Assert-Throws { Set-RemoteAccessVirtualBox -Confirm:$false } 'Shut down the VM normally'
$script:VM.VMState = 'saved'
Assert-Throws { Set-RemoteAccessVirtualBox -Confirm:$false } 'Shut down the VM normally'
Assert-True (@($script:Calls | Where-Object { $_.Arguments[0] -ne 'showvminfo' }).Count -eq 0) 'A running/saved VM was mutated.'
$script:VM.VMState = 'poweroff'
Set-RemoteAccessVirtualBox -Confirm:$false
Assert-True ($script:VM.graphicscontroller -eq 'vmsvga' -and $script:VM.vrde -eq 'off') 'VM settings did not converge.'
Assert-True ($script:VM['Forwarding(8)'] -eq 'bos-ghostbsd-ssh,tcp,127.0.0.1,2222,,22') 'SSH forwarding was not loopback-only.'
$Count = @($script:Calls | Where-Object { $_.Arguments[0] -eq 'modifyvm' }).Count
Set-RemoteAccessVirtualBox -Confirm:$false
Assert-True (@($script:Calls | Where-Object { $_.Arguments[0] -eq 'modifyvm' }).Count -eq $Count) 'Repeat VM apply unnecessarily mutated state.'
Assert-True (Test-RemoteAccessForwarding $script:VM) 'A valid rule outside index zero was missed.'
$Conflict = $script:VM.Clone()
$Conflict['Forwarding(9)'] = 'conflict,tcp,0.0.0.0,2222,,22'
Assert-Throws { Test-RemoteAccessForwarding $Conflict } 'conflicts'
$Duplicate = $script:VM.Clone()
$Duplicate['Forwarding(9)'] = 'duplicate,tcp,127.0.0.1,2222,,22'
Assert-Throws { Test-RemoteAccessForwarding $Duplicate } 'Multiple'
$script:VM.nic1 = 'bridged'
$Before = $script:Calls.Count
Assert-Throws { Set-RemoteAccessVirtualBox -Confirm:$false } 'does not change network topology'
Assert-True ($script:Calls.Count -eq ($Before + 1)) 'Topology refusal still mutated the VM.'

$Before = $script:Calls.Count
Install-RemoteAccessKey -WhatIf
Invoke-RemoteAccessApply -WhatIf
Assert-True ($script:Calls.Count -eq $Before) 'A preview contacted a remote endpoint.'
$KeysOnly = $true
Assert-Throws { Get-RemoteAccessGuestArguments apply } 'requires KeyTested'
$KeysOnly = $false
$Platform = 'VirtualBox'
Assert-True ((Get-RemoteAccessGuestArguments apply) -match "'virtualbox'") 'Case-insensitive PowerShell platform input was not normalized for the guest.'
$Platform = ''
function Get-NetTCPConnection {
    param([string]$State)
    @(
        [pscustomobject]@{ OwningProcess = 10; LocalAddress = '127.0.0.1'; LocalPort = 13389 }
        [pscustomobject]@{ OwningProcess = 20; LocalAddress = '0.0.0.0'; LocalPort = 13390 }
    )
}
Assert-True (Test-RemoteAccessTunnelReady -ProcessId 10 -Port 13389) 'Owned loopback listener was not recognized.'
Assert-True (-not (Test-RemoteAccessTunnelReady -ProcessId 11 -Port 13389)) 'Another process was mistaken for the tunnel.'
Assert-True (-not (Test-RemoteAccessTunnelReady -ProcessId 20 -Port 13390)) 'Wildcard listener was accepted as loopback-only.'
Write-Output 'PASS Windows argument, preview, VM, NAT, and tunnel-ownership contracts'
