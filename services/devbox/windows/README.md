# Devbox on Windows

[Devbox overview](../README.md) | [Framework](../../../framework/README.md)

The Windows Devbox scripts form one deployment package, so detection,
remediation, and the worker stay together.

## Scripts

### Windows Devbox Intune Remediation

Use [detect-devbox.ps1](./detect-devbox.ps1) and
[remediate-devbox.ps1](./remediate-devbox.ps1) with Microsoft Intune
Remediations. The remediation installs or repairs a user-scoped VHDX-backed ReFS
Dev Drive and device-scoped scheduled tasks that mount and back up the VHDX.

Files:

- [detect-devbox.ps1](./detect-devbox.ps1): read-only compliance detection for Intune.
- [remediate-devbox.ps1](./remediate-devbox.ps1): idempotent install, repair, and upgrade remediation.
- [devbox-worker.ps1](./devbox-worker.ps1): readable copy of the worker installed by remediation and
  run by scheduled tasks.

## Prerequisites

- Use 64-bit Windows PowerShell 5.1 as an administrator or SYSTEM.
- Installation requires a Windows 11 host whose `Format-Volume` command supports
  `-DevDrive`, the native disk/VHDX cmdlets, `diskpart.exe`, and Scheduled Tasks.
- Backups require VSS (`Win32_ShadowCopy`).
- No third-party package or downloaded dependency is required.

Run `npm ci --ignore-scripts` and `npm run build` on the build machine.
Deploy the generated scripts from `output/devbox/windows/`, not these authoring
sources. The build embeds the one authored worker and native configuration
validator automatically; endpoints need no Node.js or adjacent helper files.
Moving source does not change `$env:ProgramData\devbox` or scheduled-task paths.

## Deployment

Recommended Intune settings:

- Run using logged-on credentials: `No`.
- Use 64-bit PowerShell: `Yes`.
- Evaluate daily.

Defaults:

| Setting                 | Default                                      |
| ----------------------- | -------------------------------------------- |
| Devbox version          | `2.2.0`                                      |
| Live VHDX               | `<profile>\AppData\Local\devbox\devbox.vhdx` |
| Device state            | `$env:ProgramData\devbox`                    |
| Backup root             | `<Documents>\devbox\<machine-lowercase>`     |
| VHDX size               | 100 GiB dynamic                              |
| File system             | ReFS Dev Drive                               |
| Preferred drive letters | `V`, `W`, `X`, `Y`, `Z`                      |
| Nightly backup          | 2:00 AM                                      |
| Retention               | 14 backups                                   |

Configuration defaults come from [the shared source](../config/defaults.json).
Runtime state remains schema 3; desired configuration is a separate schema 1
document persisted at `$env:ProgramData\devbox\desired-config.json`.
Install/repair ensures the configured workspace directories in the verified
mounted data partition for both new and existing images. It does not guess a
drive letter or overwrite a file blocking a directory.
Detection and remediation resolve the same persisted configuration. An explicit
`-DesiredConfigPath` overrides it; unknown fields/types/versions fail explicitly.
Use the same explicit profile for detection and remediation when deploying a
configuration change. A custom service name also requires the corresponding
profile when invoking scripts outside that installed state root.

Detection reports `COMPLIANT` when config, worker, version, VHDX capacity, usable
partition capacity, backup root, and scheduled tasks match desired state. It
checks task action/arguments, SYSTEM principal, trigger type, enabled state,
and daily backup time/interval. UTC and offset-qualified trigger boundaries are
compared in local time, matching the configured local backup schedule. It reports
`REMEDIATION_REQUIRED` with problem codes when remediation should run.
`CONFIG_DRIFT:<field>` and `TASK_DRIFT:<task>` identify configuration/task drift.
Wrong trigger types, invalid schedules, and incomplete task definitions are
reported as task drift rather than aborting detection.
Malformed or unavailable desired configuration reports `DETECTION_ERROR`.

Read-only configuration inspection, including its source:

```powershell
.\output\devbox\windows\detect-devbox.ps1 -ShowConfiguration
```

Preview remediation changes with PowerShell `-WhatIf`:

```powershell
# From the repository root:
.\output\devbox\windows\remediate-devbox.ps1 -WhatIf
```

Check worker status after remediation:

```powershell
& "$env:ProgramData\devbox\devbox-worker.ps1" -Mode Status
```

## Changing capacity

Set `windows.sizeGiB` in a schema 1 desired profile; do not edit two scripts.
For example, `{"schemaVersion":1,"windows":{"sizeGiB":200}}`, then:

```powershell
.\output\devbox\windows\detect-devbox.ps1 -DesiredConfigPath C:\staging\devbox.json
.\output\devbox\windows\remediate-devbox.ps1 -DesiredConfigPath C:\staging\devbox.json -WhatIf
```

After applying on a disposable target, remediation saves the resolved desired
configuration; subsequent runs and scheduled workers use that state.
The supported setting range is 50 through 65536; Dev Drive requires at least
50 GB. The existing PowerShell convention is retained: `100 * 1GB` means
100 GiB (107,374,182,400 bytes). Partition metadata slightly reduces usable space.

An existing 50 GB VHDX is detected as undersized and grows to the new 100 GB
default during remediation. A larger configured value follows the same path.
The script detaches that exact VHDX, expands it with native DiskPart, reattaches
it, resolves its current disk number again, and extends the existing ReFS data
partition into the available space. It never initializes or formats an existing
image. Subsequent runs leave correct capacity alone.

Back up before applying. Run `-WhatIf` first, close applications and files on
Devbox, and ensure sufficient host disk space for future data and backups.
Resizing waits for the existing backup mutex to become available by failing
clearly while a backup is active; retry once the backup finishes. Failure to
detach does not trigger a forced detach. On failure the script attempts to
restore the original image attachment; on success remediation leaves it mounted,
as before. If image growth succeeds but ReFS extension fails, rerun remediation
to finish the partition rather than recreating the VHDX.

A size below the existing VHDX capacity is an explicit error, including when a
default would otherwise shrink a previously customized larger drive. Keep both
scripts set to at least that capacity or plan a separate data migration.
Worker Mount/Backup operations do not resize the VHDX.

Capacity-related detection codes:

| Code | Meaning |
| --- | --- |
| `CAPACITY_BELOW_TARGET` | VHDX capacity is below the configured target. |
| `CAPACITY_SHRINK_UNSUPPORTED` | VHDX exceeds the target; adjust configuration or migrate data. |
| `VOLUME_CAPACITY_BELOW_MAXIMUM` | The existing data partition has space left to grow into. |
| `VOLUME_CAPACITY_UNVERIFIED` | The image is detached or Windows did not report a valid maximum. |
| `VOLUME_LAYOUT_UNEXPECTED` | The expected single data partition was not found. |
| `CAPACITY_CHECK_FAILED` | Windows could not inspect image or partition capacity. |

Detection remains read-only; it does not attach an image just to inspect it.
Previewing a detached image reports the planned work but cannot validate its
ReFS layout until apply mounts it.

## Capacity regression tests

From the repository root, in a separate PowerShell process:

```powershell
npm run build
powershell.exe -NoProfile -NonInteractive -File .\services\devbox\windows\tests\configuration.ps1
powershell.exe -NoProfile -NonInteractive -File .\services\devbox\windows\tests\resize-devbox.ps1
powershell.exe -NoProfile -NonInteractive -File .\services\devbox\windows\tests\scheduled-task.ps1
```

The dependency-free suite extracts only the resize helpers and mocks Storage,
DiskPart, and scheduled-task inspection. It checks both capacity layers,
custom sizes, no-op reruns, `-WhatIf`, drift codes, wrong disk/filesystem rejection,
busy images, failure recovery, and scheduled-task drift. Configuration tests
cover validation, merging, persistence, and explicit worker state-root arguments.
The Windows-only scheduled-task suite constructs native CIM task objects in
memory to verify provider shapes and timezone handling without registering,
enumerating, or changing any scheduled tasks.
The same mocks can run under PowerShell 7
on another OS, but do not verify real Windows behavior.

Before deployment, also validate growth and a second no-op run using a disposable
Windows 11 VHDX/ReFS Dev Drive. The mock suite is not a substitute for this native
integration check.

## Rollback

Remove the scheduled tasks and device state as an administrator when retiring
the package. Confirm backup and live VHDX retention requirements before deleting
user data.

```powershell
Unregister-ScheduledTask -TaskName 'devbox - mount at startup' -Confirm:$false
Unregister-ScheduledTask -TaskName 'devbox - nightly backup' -Confirm:$false
Remove-Item -LiteralPath "$env:ProgramData\devbox" -Recurse -Force
```
