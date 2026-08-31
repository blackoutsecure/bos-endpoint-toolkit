# Windows Scripts

PowerShell scripts for Windows endpoint administration.

## Scripts

### Windows Devbox Intune Remediation

Use `detect-devbox.ps1` and `remediate-devbox.ps1` with Microsoft Intune
Remediations. The remediation installs or repairs a user-scoped VHDX-backed ReFS
Dev Drive and device-scoped scheduled tasks that mount and back up the VHDX.

Files:

- `detect-devbox.ps1`: read-only compliance detection for Intune.
- `remediate-devbox.ps1`: idempotent install, repair, and upgrade remediation.
- `devbox-worker.ps1`: readable copy of the worker installed by remediation and
  run by scheduled tasks.

Recommended Intune settings:

- Run using logged-on credentials: `No`.
- Use 64-bit PowerShell: `Yes`.
- Evaluate daily.

Defaults:

| Setting                 | Default                                      |
| ----------------------- | -------------------------------------------- |
| Devbox version          | `2.1.0`                                      |
| Live VHDX               | `<profile>\AppData\Local\devbox\devbox.vhdx` |
| Device state            | `$env:ProgramData\devbox`                    |
| Backup root             | `<Documents>\devbox\<machine-lowercase>`     |
| VHDX size               | 50 GB dynamic                                |
| File system             | ReFS Dev Drive                               |
| Preferred drive letters | `V`, `W`, `X`, `Y`, `Z`                      |
| Nightly backup          | 2:00 AM                                      |
| Retention               | 14 backups                                   |

Detection reports `COMPLIANT` when config, worker, version, VHDX, backup root,
and scheduled tasks are healthy. It reports `REMEDIATION_REQUIRED` with problem
codes when remediation should run.

Preview remediation changes with PowerShell `-WhatIf`:

```powershell
.\remediate-devbox.ps1 -WhatIf
```

Check worker status after remediation:

```powershell
& "$env:ProgramData\devbox\devbox-worker.ps1" -Mode Status
```

## Rollback

Remove the scheduled tasks and device state as an administrator when retiring
the package. Confirm backup and live VHDX retention requirements before deleting
user data.

```powershell
Unregister-ScheduledTask -TaskName 'devbox - mount at startup' -Confirm:$false
Unregister-ScheduledTask -TaskName 'devbox - nightly backup' -Confirm:$false
Remove-Item -LiteralPath "$env:ProgramData\devbox" -Recurse -Force
```
