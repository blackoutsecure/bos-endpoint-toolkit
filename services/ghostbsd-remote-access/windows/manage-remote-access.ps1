[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [ValidateSet('Status', 'Configuration', 'VirtualBoxStatus', 'VirtualBoxApply', 'InstallKey', 'Apply', 'Rdp', 'Wizard')]
    [string]$Mode = 'Status',
    # >>> ghostbsd-remote-access:parameters >>>
    [string]$ComputerName,
    [int]$SshPort,
    [int]$LocalRdpPort,
    # <<< ghostbsd-remote-access:parameters <<<
    [ValidatePattern('^[a-z_][a-z0-9_-]{0,31}\z')][string]$UserName,
    [string]$VMName,
    [string]$IdentityFile,
    [string]$PublicKeyPath,
    [switch]$GenerateKey,
    [ValidateSet('auto', 'virtualbox', 'hyperv', 'physical')][string]$Platform,
    [switch]$KeysOnly,
    [switch]$KeyTested
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# >>> ghostbsd-remote-access:configuration >>>
throw 'Build first; deploy output\ghostbsd-remote-access\windows\manage-remote-access.ps1.'
# <<< ghostbsd-remote-access:configuration <<<

function Get-RemoteAccessTool {
    param([string]$Name)
    $Command = Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue
    if ($Command) { return $Command.Source }
    if ($Name -eq 'VBoxManage.exe') {
        $Candidate = Join-Path $env:ProgramFiles 'Oracle\VirtualBox\VBoxManage.exe'
        if (Test-Path -LiteralPath $Candidate -PathType Leaf) { return $Candidate }
    }
    throw "Required tool is unavailable: $Name"
}

function ConvertTo-RemoteAccessNativeArgument {
    param([AllowEmptyString()][string]$Value)
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $Escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $Escaped = [regex]::Replace($Escaped, '(\\+)$', '$1$1')
    return '"' + $Escaped + '"'
}

function ConvertTo-RemoteAccessShellLiteral {
    param([string]$Value)
    return "'" + $Value.Replace("'", ("'" + '"' + "'" + '"' + "'")) + "'"
}

function Invoke-RemoteAccessNative {
    param([string]$FilePath, [string[]]$Arguments, [switch]$Capture)
    if ($Capture) { $Output = & $FilePath @Arguments } else { & $FilePath @Arguments }
    if ($LASTEXITCODE -ne 0) { throw "Native command failed ($LASTEXITCODE): $([IO.Path]::GetFileName($FilePath))" }
    if ($Capture) { return $Output }
}

function Get-RemoteAccessSshArguments {
    param([string]$Target, [string]$Account, [int]$Port, [string]$Identity, [bool]$Batch = $true)
    if ($Target -cnotmatch '^[A-Za-z0-9][A-Za-z0-9.-]{0,252}\z' -or
        $Account -cnotmatch '^[a-z_][a-z0-9_-]{0,31}\z' -or $Account -eq 'root' -or
        $Port -lt 1 -or $Port -gt 65535) {
        throw 'Supply a safe host, valid SSH port, and an existing non-root UserName.'
    }
    $Result = @('-p', "$Port", '-o', 'StrictHostKeyChecking=yes', '-o', 'ConnectTimeout=10', '-o', 'ConnectionAttempts=1')
    if ($Batch) { $Result += @('-o', 'BatchMode=yes') }
    if ($Identity) {
        if ($Identity -match '[\r\n]' -or -not (Test-Path -LiteralPath $Identity -PathType Leaf)) { throw 'The explicit identity file is missing or invalid.' }
        $Result += @('-i', (Get-Item -LiteralPath $Identity).FullName)
    }
    return $Result
}

function Get-RemoteAccessIdentity {
    if ($IdentityFile) { return $IdentityFile }
    $Candidate = Join-Path $HOME '.ssh\id_ed25519_ghostbsd'
    if (Test-Path -LiteralPath $Candidate -PathType Leaf) { return $Candidate }
    return ''
}

function Get-RemoteAccessGuestArguments {
    param([string]$Operation)
    if (-not $UserName -or $UserName -eq 'root') { throw 'An existing non-root UserName is required.' }
    $SelectedPlatform = if ($Platform) { $Platform.ToLowerInvariant() } else { $RemoteAccessDefaults.platform }
    $Result = @('--user', $UserName, '--platform', $SelectedPlatform)
    if ($KeysOnly) {
        if (-not $KeyTested) { throw 'KeysOnly requires KeyTested after a separate successful key login.' }
        $Result += @('--keys-only', '--key-tested')
    }
    $Result += $Operation
    return ($Result | ForEach-Object { ConvertTo-RemoteAccessShellLiteral $_ }) -join ' '
}

function Invoke-RemoteAccessStatus {
    $Arguments = @(Get-RemoteAccessSshArguments -Target $ComputerName -Account $UserName -Port $SshPort -Identity (Get-RemoteAccessIdentity))
    $Arguments += @('-T', "$UserName@$ComputerName", ('exec /usr/local/bin/bash -s -- ' + (Get-RemoteAccessGuestArguments status)))
    $StartInfo = [Diagnostics.ProcessStartInfo]::new()
    $StartInfo.FileName = Get-RemoteAccessTool ssh.exe
    $StartInfo.Arguments = ($Arguments | ForEach-Object { ConvertTo-RemoteAccessNativeArgument $_ }) -join ' '
    $StartInfo.UseShellExecute = $false
    $StartInfo.RedirectStandardInput = $true
    $Process = [Diagnostics.Process]::Start($StartInfo)
    $Deadline = [DateTime]::UtcNow.AddSeconds(60)
    try {
        $Write = $Process.StandardInput.WriteAsync([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($RemoteAccessGuestBase64)))
        if (-not $Write.Wait(60000)) { throw 'Remote status input exceeded its 60-second deadline.' }
        $Process.StandardInput.Close()
        $Remaining = [int][math]::Max(0, ($Deadline - [DateTime]::UtcNow).TotalMilliseconds)
        if (-not $Process.WaitForExit($Remaining)) { throw 'Remote read-only status exceeded its 60-second deadline.' }
        if ($Process.ExitCode -ne 0) { throw "Remote status is not compliant or failed (guest exit $($Process.ExitCode))." }
    } finally {
        if (-not $Process.HasExited) { Stop-Process -Id $Process.Id -Force }
        $Process.Dispose()
    }
}

function Install-RemoteAccessKey {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()
    $Ssh = Get-RemoteAccessTool ssh.exe
    $Keygen = Get-RemoteAccessTool ssh-keygen.exe
    $null = Get-RemoteAccessSshArguments -Target $ComputerName -Account $UserName -Port $SshPort -Batch $false
    $Private = [IO.Path]::GetFullPath($(if ($IdentityFile) { $IdentityFile } else { Join-Path $HOME '.ssh\id_ed25519_ghostbsd' }))
    $Public = if ($PublicKeyPath) { $PublicKeyPath } else { "$Private.pub" }
    if (-not $PSCmdlet.ShouldProcess("$UserName@$ComputerName", 'Install a public key; prompt for a passphrase on generation only if explicitly requested and absent')) { return }
    if (-not (Test-Path -LiteralPath $Public -PathType Leaf)) {
        if (-not $GenerateKey -or $PublicKeyPath) { throw 'Supply an existing PublicKeyPath or explicitly use GenerateKey.' }
        if (Test-Path -LiteralPath $Private) { throw 'A private key already exists without its public key; recover the public key, do not overwrite the private key.' }
        $Parent = Split-Path -Parent $Private
        if (-not (Test-Path -LiteralPath $Parent -PathType Container)) { $null = New-Item -ItemType Directory -Path $Parent }
        Write-Output 'ssh-keygen will prompt for a passphrase. Existing key material is never regenerated.'
        Invoke-RemoteAccessNative -FilePath $Keygen -Arguments @('-t', 'ed25519', '-a', '64', '-f', $Private)
    }
    $Key = [IO.File]::ReadAllText((Get-Item -LiteralPath $Public).FullName).TrimEnd("`r", "`n")
    if ($Key -cnotmatch '\A(ssh-ed25519|ecdsa-sha2-[A-Za-z0-9-]+|ssh-rsa) [A-Za-z0-9+/]+=*( [^\r\n]*)?\z') {
        throw 'Supply exactly one valid OpenSSH public-key line, never a private key.'
    }
    Invoke-RemoteAccessNative -FilePath $Keygen -Arguments @('-l', '-f', (Get-Item -LiteralPath $Public).FullName)
    $Encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Key))
    $Remote = @'
set -eu
umask 077
key="$(printf '%s' '@KEY@' | base64 -d)"
directory="$HOME/.ssh"
target="$directory/authorized_keys"
test ! -L "$directory" && test ! -L "$target" || { echo 'Refusing symlinked SSH paths.' >&2; exit 2; }
mkdir -p "$directory"
chmod 0700 "$directory"
touch "$target"
chmod 0600 "$target"
result=0
grep -Fqx -- "$key" "$target" || result=$?
case "$result" in 0) exit 0 ;; 1) ;; *) echo 'Cannot inspect existing keys.' >&2; exit 2 ;; esac
stage="$(mktemp "$directory/.bos-authorized-keys.XXXXXXXX")"
trap 'rm -f -- "$stage"' EXIT HUP INT TERM
cat "$target" > "$stage"
if test -s "$stage"; then printf '\n' >> "$stage"; fi
printf '%s\n' "$key" >> "$stage"
chmod 0600 "$stage"
mv -f -- "$stage" "$target"
'@
    $Remote = $Remote.Replace('@KEY@', $Encoded)
    $Arguments = @(Get-RemoteAccessSshArguments -Target $ComputerName -Account $UserName -Port $SshPort -Identity (Get-RemoteAccessIdentity) -Batch $false)
    $Arguments += @("$UserName@$ComputerName", ('/bin/sh -c ' + (ConvertTo-RemoteAccessShellLiteral $Remote)))
    Invoke-RemoteAccessNative -FilePath $Ssh -Arguments $Arguments
    Write-Output 'Public key installed without removing existing keys. Test a separate key login before selecting KeysOnly.'
}

function Invoke-RemoteAccessApply {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()
    $Ssh = Get-RemoteAccessTool ssh.exe
    $Scp = Get-RemoteAccessTool scp.exe
    $Identity = Get-RemoteAccessIdentity
    $Arguments = @(Get-RemoteAccessSshArguments -Target $ComputerName -Account $UserName -Port $SshPort -Identity $Identity)
    $GuestArguments = Get-RemoteAccessGuestArguments apply
    if (-not $PSCmdlet.ShouldProcess("$UserName@$ComputerName", 'Upload the embedded guest backend to private temporary staging and apply through an interactive approved sudo session')) { return }
    $RemoteDirectory = ''
    $LocalFile = Join-Path ([IO.Path]::GetTempPath()) ("bos-remote-access-$([guid]::NewGuid().ToString('N')).sh")
    try {
        $Create = '/bin/sh -c ' + (ConvertTo-RemoteAccessShellLiteral 'umask 077; mktemp -d /tmp/bos-ghostbsd-remote-access.XXXXXXXX')
        $Created = @(Invoke-RemoteAccessNative -FilePath $Ssh -Arguments ($Arguments + @("$UserName@$ComputerName", $Create)) -Capture)
        $Candidate = ($Created -join "`n").Trim()
        if ($Candidate -cnotmatch '\A/tmp/bos-ghostbsd-remote-access\.[A-Za-z0-9]{8,}\z') { throw 'Remote staging did not return one safe private directory; inspect the remote endpoint.' }
        $RemoteDirectory = $Candidate
        $Stream = [IO.File]::Open($LocalFile, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $Bytes = [Convert]::FromBase64String($RemoteAccessGuestBase64)
            $Stream.Write($Bytes, 0, $Bytes.Length)
        } finally { $Stream.Dispose() }
        $CopyArguments = @('-P', "$SshPort", '-o', 'StrictHostKeyChecking=yes', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10')
        if ($Identity) { $CopyArguments += @('-i', (Get-Item -LiteralPath $Identity).FullName) }
        $Destination = '{0}@{1}:{2}/manage-remote-access.sh' -f $UserName, $ComputerName, $RemoteDirectory
        Invoke-RemoteAccessNative -FilePath $Scp -Arguments ($CopyArguments + @($LocalFile, $Destination))
        $Remote = 'sudo -- /usr/local/bin/bash ' + (ConvertTo-RemoteAccessShellLiteral "$RemoteDirectory/manage-remote-access.sh") + ' ' + $GuestArguments
        Invoke-RemoteAccessNative -FilePath $Ssh -Arguments ($Arguments + @('-tt', "$UserName@$ComputerName", $Remote))
    } finally {
        if (Test-Path -LiteralPath $LocalFile -PathType Leaf) { Remove-Item -LiteralPath $LocalFile -Force }
        if ($RemoteDirectory) {
            $Cleanup = 'set -e; rm -f -- ' + (ConvertTo-RemoteAccessShellLiteral "$RemoteDirectory/manage-remote-access.sh") +
                '; rmdir -- ' + (ConvertTo-RemoteAccessShellLiteral $RemoteDirectory)
            Invoke-RemoteAccessNative -FilePath $Ssh -Arguments ($Arguments + @("$UserName@$ComputerName", ('/bin/sh -c ' + (ConvertTo-RemoteAccessShellLiteral $Cleanup))))
        }
    }
    Write-Output 'Guest apply and verification completed.'
}

function Get-RemoteAccessVirtualBoxInfo {
    if ([string]::IsNullOrWhiteSpace($VMName) -or $VMName.StartsWith('-') -or $VMName -match '[\r\n]') { throw 'Supply an explicit, valid VMName.' }
    $Lines = Invoke-RemoteAccessNative -FilePath (Get-RemoteAccessTool VBoxManage.exe) -Arguments @('showvminfo', $VMName, '--machinereadable') -Capture
    $Info = @{}
    foreach ($Line in $Lines) {
        if ($Line -match '\A(?<key>[^=]+)=(?<value>.*)\z') {
            if ($Info.ContainsKey($Matches.key)) { throw 'VirtualBox returned a duplicate information key.' }
            $Info[$Matches.key] = $Matches.value.Trim('"')
        }
    }
    foreach ($Key in @('VMState', 'graphicscontroller', 'vram', 'monitorcount', 'accelerate3d', 'vrde', 'memory', 'cpus', 'nic1')) {
        if (-not $Info.ContainsKey($Key)) { throw "VirtualBox did not return required information: $Key" }
    }
    return $Info
}

function Get-RemoteAccessVirtualBoxDesired {
    return [ordered]@{
        graphicscontroller = 'vmsvga'
        vram = "$($RemoteAccessDefaults.videoMemoryMiB)"
        monitorcount = '1'
        accelerate3d = 'off'
        vrde = 'off'
    }
}

function Test-RemoteAccessForwarding {
    param([hashtable]$Info)
    $Found = $false
    foreach ($Key in $Info.Keys) {
        if ($Key -notmatch '\AForwarding\([0-9]+\)\z') { continue }
        $Fields = $Info[$Key].Split(',')
        if ($Fields.Count -ne 6) { throw 'VirtualBox returned a malformed forwarding rule.' }
        if ($Fields[0] -eq 'bos-ghostbsd-ssh' -or ($Fields[1] -eq 'tcp' -and $Fields[3] -eq "$SshPort")) {
            if ($Fields[1] -ne 'tcp' -or $Fields[2] -ne '127.0.0.1' -or $Fields[3] -ne "$SshPort" -or
                $Fields[4] -ne '' -or $Fields[5] -ne "$($RemoteAccessDefaults.sshPort)") {
                throw 'An SSH forwarding rule conflicts with the loopback-only desired rule. Resolve it explicitly; no rule will be deleted.'
            }
            if ($Found) { throw 'Multiple SSH forwarding rules use the desired port.' }
            $Found = $true
        }
    }
    return $Found
}

function Get-RemoteAccessVirtualBoxFindings {
    param([hashtable]$Info)
    $Desired = Get-RemoteAccessVirtualBoxDesired
    foreach ($Key in $Desired.Keys) {
        [pscustomobject]@{ Setting = $Key; Current = $Info[$Key]; Desired = $Desired[$Key]; Compliant = $Info[$Key] -eq $Desired[$Key] }
    }
    [pscustomobject]@{ Setting = 'nic1'; Current = $Info.nic1; Desired = 'nat'; Compliant = $Info.nic1 -eq 'nat' }
    $Forwarding = Test-RemoteAccessForwarding $Info
    [pscustomobject]@{ Setting = 'SSH forwarding'; Current = $Forwarding; Desired = "127.0.0.1:$SshPort -> guest:$($RemoteAccessDefaults.sshPort)"; Compliant = $Forwarding }
    if ([int]$Info.memory -lt 4096) { Write-Warning 'Recommend at least 4096 MiB guest memory; no memory setting is changed.' }
    if ([int]$Info.cpus -lt 2) { Write-Warning 'Recommend at least two guest CPUs; no CPU setting is changed.' }
}

function Set-RemoteAccessVirtualBox {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()
    $Info = Get-RemoteAccessVirtualBoxInfo
    $Findings = @(Get-RemoteAccessVirtualBoxFindings $Info)
    $Findings | Format-Table -AutoSize | Out-Host
    if (@($Findings | Where-Object { -not $_.Compliant }).Count -eq 0) { Write-Output 'COMPLIANT'; return }
    if ($Info.nic1 -ne 'nat') { throw 'NIC1 must already be NAT. This service does not change network topology.' }
    if (-not $PSCmdlet.ShouldProcess($VMName, 'Set VM graphics/VRDE and add a missing loopback-only SSH NAT rule; never stop the VM or discard saved state')) { return }
    if ($Info.VMState -ne 'poweroff') { throw 'Shut down the VM normally first. Running or saved VMs are never stopped or discarded automatically.' }
    $Arguments = @('modifyvm', $VMName)
    $Desired = Get-RemoteAccessVirtualBoxDesired
    foreach ($Key in $Desired.Keys) { $Arguments += @("--$Key", $Desired[$Key]) }
    if (-not (Test-RemoteAccessForwarding $Info)) {
        $Arguments += @('--natpf1', "bos-ghostbsd-ssh,tcp,127.0.0.1,$SshPort,,$($RemoteAccessDefaults.sshPort)")
    }
    Invoke-RemoteAccessNative -FilePath (Get-RemoteAccessTool VBoxManage.exe) -Arguments $Arguments
    $Remaining = @(Get-RemoteAccessVirtualBoxFindings (Get-RemoteAccessVirtualBoxInfo) | Where-Object { -not $_.Compliant })
    if ($Remaining.Count) { throw 'VirtualBox verification still reports drift.' }
    Write-Output 'COMPLIANT'
}

function Test-RemoteAccessTunnelReady {
    param([int]$ProcessId, [int]$Port)
    $Connections = @(Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object {
        $_.OwningProcess -eq $ProcessId -and $_.LocalAddress -eq '127.0.0.1' -and $_.LocalPort -eq $Port
    })
    return $Connections.Count -gt 0
}

function Start-RemoteAccessRdp {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()
    $Ssh = Get-RemoteAccessTool ssh.exe
    $Client = Get-RemoteAccessTool mstsc.exe
    $null = Get-Command Get-NetTCPConnection -ErrorAction Stop
    $Arguments = @(Get-RemoteAccessSshArguments -Target $ComputerName -Account $UserName -Port $SshPort -Identity (Get-RemoteAccessIdentity))
    $Arguments += @('-N', '-T', '-o', 'ExitOnForwardFailure=yes', '-o', 'ControlMaster=no', '-o', 'ControlPath=none',
        '-L', "127.0.0.1:${LocalRdpPort}:127.0.0.1:$($RemoteAccessDefaults.rdpPort)", "$UserName@$ComputerName")
    if (-not $PSCmdlet.ShouldProcess("127.0.0.1:$LocalRdpPort", 'Start an owned SSH tunnel and Remote Desktop client until Enter or Ctrl+C')) { return }
    $Probe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $LocalRdpPort)
    try { $Probe.Start() } finally { $Probe.Stop() }
    $Tunnel = Start-Process -FilePath $Ssh -ArgumentList (($Arguments | ForEach-Object { ConvertTo-RemoteAccessNativeArgument $_ }) -join ' ') -NoNewWindow -PassThru
    try {
        $Deadline = [DateTime]::UtcNow.AddSeconds(20)
        $Ready = $false
        while ([DateTime]::UtcNow -lt $Deadline) {
            if ($Tunnel.HasExited) { throw "SSH tunnel exited before readiness ($($Tunnel.ExitCode))." }
            if (Test-RemoteAccessTunnelReady -ProcessId $Tunnel.Id -Port $LocalRdpPort) { $Ready = $true; break }
            Start-Sleep -Milliseconds 200
        }
        if (-not $Ready) { throw 'SSH tunnel was not ready within 20 seconds.' }
        $null = Start-Process -FilePath $Client -ArgumentList "/v:127.0.0.1:$LocalRdpPort"
        $null = Read-Host 'Tunnel ready. Close Remote Desktop, then press Enter here to stop the tunnel (Ctrl+C also stops it)'
        if ($Tunnel.HasExited -and $Tunnel.ExitCode -ne 0) { throw "SSH tunnel failed ($($Tunnel.ExitCode))." }
    } finally {
        if (-not $Tunnel.HasExited) { Stop-Process -Id $Tunnel.Id -Force }
        $Tunnel.Dispose()
    }
}

function Show-RemoteAccessWizard {
    while ($true) {
        Write-Output "`nGhostBSD Remote Access`n1) Guest status`n2) VirtualBox status`n3) Apply VirtualBox settings`n4) Install public key`n5) Apply guest setup`n6) Start tunneled RDP`n0) Exit"
        $Choice = Read-Host 'Selection'
        switch ($Choice) {
            '0' { return }
            '1' { Invoke-RemoteAccessStatus }
            '2' { Get-RemoteAccessVirtualBoxFindings (Get-RemoteAccessVirtualBoxInfo) | Format-Table -AutoSize | Out-Host }
            '3' { Set-RemoteAccessVirtualBox }
            '4' { Install-RemoteAccessKey }
            '5' { Invoke-RemoteAccessApply }
            '6' { Start-RemoteAccessRdp }
            default { Write-Warning 'Unknown selection.' }
        }
    }
}

if ($Mode -eq 'Configuration') { $RemoteAccessDefaults | ConvertTo-Json; return }
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'This operator backend requires Windows.' }
switch ($Mode) {
    'Status' { Invoke-RemoteAccessStatus }
    'VirtualBoxStatus' {
        $Findings = @(Get-RemoteAccessVirtualBoxFindings (Get-RemoteAccessVirtualBoxInfo))
        $Findings | Format-Table -AutoSize | Out-Host
        if (@($Findings | Where-Object { -not $_.Compliant }).Count) { Write-Output 'REMEDIATION_REQUIRED'; exit 1 }
        Write-Output 'COMPLIANT'
    }
    'VirtualBoxApply' { Set-RemoteAccessVirtualBox }
    'InstallKey' { Install-RemoteAccessKey }
    'Apply' { Invoke-RemoteAccessApply }
    'Rdp' { Start-RemoteAccessRdp }
    'Wizard' { Show-RemoteAccessWizard }
}
