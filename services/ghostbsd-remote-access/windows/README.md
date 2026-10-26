# Windows remote-access operator

Use the generated `manage-remote-access.ps1` with Windows PowerShell 5.1 or
PowerShell 7 on Windows 10/11. OpenSSH client tools are prerequisites; VirtualBox
is needed only for its VM operations. No Windows administrator session is
required by this operator. Nothing is installed, contacted, or launched merely
by building/testing it.

## Inspect and preview

```powershell
.\manage-remote-access.ps1 -Mode Configuration
.\manage-remote-access.ps1 -Mode VirtualBoxStatus -VMName 'GhostBSD Lab'
.\manage-remote-access.ps1 -Mode VirtualBoxApply -VMName 'GhostBSD Lab' -WhatIf
.\manage-remote-access.ps1 -Mode Status -UserName desktop
.\manage-remote-access.ps1 -Mode Apply -UserName desktop -WhatIf
```

The examples default to SSH `127.0.0.1:2222`, a VirtualBox NAT forwarding
endpoint. Supply `-ComputerName` and `-SshPort` for direct Hyper-V/physical
connections; IPv4/DNS names are supported, not IPv6 literal targets.
`-Platform` overrides the packaged guest profile.
`Configuration` displays packaged defaults, not live guest observations.
`Status` streams the embedded guest backend through SSH stdin without creating
guest files. Guest noncompliance/native failures throw; `VirtualBoxStatus`
returns 1 for drift and 0 for compliance.

VM apply requires a normal **poweroff** state. It sets VMSVGA, packaged VRAM,
one monitor, 3D off, VRDE off, and adds a missing loopback-only SSH NAT rule.
NIC1 must already be NAT; the service never rewrites topology or deletes a
conflicting forwarding rule. Rules at every index are checked, not just index 0.
Memory/CPU recommendations are advisory. Saved/running VMs are never shut down,
resumed, or discarded by this script. Start the VM normally after applying.

## Bootstrap and onboard a key

Remote orchestration cannot enable SSH on an unreachable guest. At the guest
console, prepare Bash/SSH through an approved administrative session first.
Check the guest host-key fingerprint against a trusted console/out-of-band
source, then establish trust with an ordinary OpenSSH connection:

```powershell
ssh -p 2222 desktop@127.0.0.1
```

The service always uses `StrictHostKeyChecking=yes`; it never accepts unknown
host keys automatically or rewrites known-hosts files.

```powershell
.\manage-remote-access.ps1 -Mode InstallKey -UserName desktop -PublicKeyPath C:\staging\ghostbsd.pub -WhatIf
.\manage-remote-access.ps1 -Mode InstallKey -UserName desktop -PublicKeyPath C:\staging\ghostbsd.pub
.\manage-remote-access.ps1 -Mode InstallKey -UserName desktop -GenerateKey
```

Optional generation uses `ssh-keygen`'s interactive passphrase prompt and never
overwrites existing/partial key pairs. The default key path is
`$HOME\.ssh\id_ed25519_ghostbsd`. A present default service identity is reused;
otherwise the OpenSSH agent/default identities are used.
Specify `-IdentityFile` to select another private key **locally**. Only public
material is installed remotely. No key/passphrase is stored in configuration.

Verify a separate key-only login before selecting SSH keys-only mode:

```powershell
ssh -o BatchMode=yes -i "$HOME\.ssh\id_ed25519_ghostbsd" -p 2222 desktop@127.0.0.1
```

## Remote apply

```powershell
.\manage-remote-access.ps1 -Mode Apply -UserName desktop -Platform virtualbox -WhatIf
.\manage-remote-access.ps1 -Mode Apply -UserName desktop -Platform virtualbox
.\manage-remote-access.ps1 -Mode Apply -UserName desktop -KeysOnly -KeyTested
```

Apply requires working key/agent authentication and pre-established host trust.
It uploads the embedded guest backend into a private temporary directory, then
opens an interactive SSH session for `sudo`. Enter the approved sudo password
there if required; no NOPASSWD grant or execution-policy bypass is made.
Local/remote staging is cleaned on completion or failure; cleanup failure is
an error. The original ZIP is neither uploaded nor extracted.
Package installation and service changes persist on the guest as documented in
the [guest guide](../ghostbsd/README.md); there is no fleet-wide deployment claim.

## Tunneled RDP and wizard

```powershell
.\manage-remote-access.ps1 -Mode Rdp -UserName desktop -WhatIf
.\manage-remote-access.ps1 -Mode Rdp -UserName desktop -LocalRdpPort 13389
.\manage-remote-access.ps1 -Mode Wizard -UserName desktop -VMName 'GhostBSD Lab'
```

The tunnel binds only `127.0.0.1`, checks for an occupied local port, requires
SSH forward success, and waits up to 20 seconds for a listener owned by its
specific SSH PID before starting MSTSC. It does not treat an arbitrary open port
as proof of tunnel readiness.

Keep the operator terminal open. After closing Remote Desktop, press Enter to
stop the owned tunnel; Ctrl+C also runs cleanup. No detached shell/tunnel is
left deliberately running, and no unrelated process is killed.
The wizard's `0` exits its loop; it does not implicitly apply or shut down VMs.
All mutating actions honor `-WhatIf`.

[Service contract, archive review and native rollout gate](../README.md)
