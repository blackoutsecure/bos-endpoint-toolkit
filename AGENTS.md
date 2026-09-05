# AGENTS.md

This file provides guidance to agents when working with code in this repository.

## What this is

`bos-endpoint-toolkit` is a set of standalone operational scripts for administering Windows, Linux, and macOS endpoints. It is not a hardening or compliance scanner. The only capability implemented today is **devbox**: a per-user development workspace backed by a disk image - a ReFS Dev Drive VHDX on Windows, an APFS sparsebundle on macOS - plus the scheduled tasks or launchd agents that mount it and back it up nightly under a retention policy. `README.md` calls the toolkit Intune-adjacent; the scripts are platform-native and depend on no management platform, agent, or shared runtime.

The two platform implementations are independent code, not one engine with two front-ends. `scripts/windows/` holds three PowerShell 5.1 scripts for Windows 10/11 that require administrator or SYSTEM and preview through `-WhatIf` via `SupportsShouldProcess`. `scripts/macos/` holds one Bash script for macOS releases whose `diskutil image` subcommand exposes `create`/`attach`/`info`; it previews through its own `--dry-run` flag, runs as the signed-in user, and **refuses to run as root**, because the image, backups, launchd agents, and support files are all user-scoped. `scripts/linux/` and `scripts/shared/` contain only a placeholder `README.md` each - no Linux script and no shared library exist yet.

Elevated privilege is therefore required on Windows and prohibited on macOS. Do not assume symmetry: the privilege model, image format, scheduler, and backup consistency mechanism all differ by design.

Stack. Windows: Windows PowerShell 5.1 (`#requires -Version 5.1`), 64-bit, `Set-StrictMode -Version Latest`, `$ErrorActionPreference = 'Stop'`, relying on `diskpart.exe`, `Get-DiskImage`/`Mount-DiskImage`, `Initialize-Disk`, `New-Partition`, `Format-Volume -DevDrive` (Windows 11 only), `Register-ScheduledTask`, and the `Win32_ShadowCopy` VSS class. macOS: Bash with `#!/bin/bash` and `set -euo pipefail` - despite the "POSIX shell" wording in `README.md` it uses `[[ ]]`, arrays, and brace expansion, so it is Bash, not `sh` - calling `diskutil`, `launchctl`, `plutil`, `ditto`, `scutil`, and `shasum` by absolute path. There is no package manifest, build step, lockfile, or third-party dependency.

## Commands

macOS. `status` is read-only; always preview an apply with `--dry-run` first.

```bash
cd /Volumes/devbox/repos/blackoutsecure/bos-endpoint-toolkit

./scripts/macos/manage-devbox.sh status
./scripts/macos/manage-devbox.sh --dry-run install
./scripts/macos/manage-devbox.sh --dry-run purge

./scripts/macos/manage-devbox.sh install     # or: repair | mount | backup
./scripts/macos/manage-devbox.sh uninstall   # keeps the image and backups
./scripts/macos/manage-devbox.sh purge       # removes the image and backups

DEVBOX_SIZE_GB=25 DEVBOX_HIDE_VOLUME=true ./scripts/macos/manage-devbox.sh --dry-run install
```

Windows, in an elevated 64-bit PowerShell on a disposable endpoint.

```powershell
.\scripts\windows\detect-devbox.ps1              # read-only; COMPLIANT or REMEDIATION_REQUIRED
.\scripts\windows\remediate-devbox.ps1 -WhatIf   # preview every state change
.\scripts\windows\remediate-devbox.ps1           # apply
& "$env:ProgramData\devbox\devbox-worker.ps1" -Mode Status
& "$env:ProgramData\devbox\devbox-worker.ps1" -Mode Backup -WhatIf
```

Lint and syntax. `CONTRIBUTING.md` asks for these "when available"; run them anyway.

```bash
bash -n scripts/macos/manage-devbox.sh
shellcheck scripts/macos/manage-devbox.sh

pwsh -NoProfile -Command "Invoke-ScriptAnalyzer -Path scripts/windows -Recurse"
pwsh -NoProfile -File /dev/stdin <<'PS'
Get-ChildItem scripts/windows -Filter *.ps1 | ForEach-Object {
  [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$null) | Out-Null
}
PS
```

## Validating changes

**There is no CI in this repository.** There is no `.github/` directory, no workflow, no managed kicker, no test suite, and no lint configuration file. Nothing runs on a push or a pull request. Local validation is the entire gate.

Narrowest first, then escalate to a real run:

1. Syntax - `bash -n` for the macOS script; a PowerShell AST parse or `Invoke-ScriptAnalyzer` for anything under `scripts/windows/`.
2. Lint - `shellcheck`, `Invoke-ScriptAnalyzer`.
3. Preview - `--dry-run` on macOS, `-WhatIf` on Windows, read line by line against your diff.
4. Real run on a disposable VM or scratch user account for the platform touched: read-only path first (`status`, `detect-devbox.ps1`), then apply, then apply again to confirm it converges rather than repeating work, then rollback (`uninstall`; `purge` only on scratch data).

Reasoning about correctness is not sufficient. These scripts create and format disk images, register SYSTEM scheduled tasks and launchd agents, take VSS snapshots, copy multi-gigabyte images, and delete files under retention. A preview proves the intended plan, not that the apply path works - the two follow different branches in every function, so a change reviewed but not executed is unvalidated.

Production endpoints are never a test target, and neither is your own workstation when the change touches image creation, retention deletion, or agent or task registration. macOS `purge` deletes `~/Library/Application Support/devbox` and `~/Documents/devbox/<machine>`; Windows retention deletes backup VHDX files beyond the configured count.

## Architecture

```text
README.md                          Toolkit purpose, layout, rules for adding a script
CONTRIBUTING.md                    Script requirements and manual validation procedure
.gitignore                         Editor/OS files, *.log, reports/, output/
docs/README.md                     Placeholder for runbooks and operational guidance
scripts/shared/README.md           Placeholder; no shared helper code exists
scripts/linux/README.md            Placeholder; no Linux script exists
scripts/macos/README.md            Modes, environment variables, deployment, rollback
scripts/macos/manage-devbox.sh     macOS, Bash. Creates/mounts/backs up an APFS sparsebundle
                                   at /Volumes/devbox and installs two user launchd agents.
                                   Modes: install, repair, mount, backup, status, uninstall,
                                   purge. Signed-in user only; exits if run as root.
scripts/windows/README.md          Intune settings, defaults, detection codes, rollback
scripts/windows/detect-devbox.ps1  Windows. Read-only Intune detection; exits 0 COMPLIANT or
                                   1 REMEDIATION_REQUIRED with problem codes.
scripts/windows/remediate-devbox.ps1  Windows. Idempotent install/repair/upgrade: creates a
                                   dynamic ReFS Dev Drive VHDX, writes ProgramData state,
                                   installs the worker, registers two SYSTEM tasks. Admin.
scripts/windows/devbox-worker.ps1  Windows. Readable copy of the worker remediation embeds
                                   and installs. Modes: Mount, Backup, Status. Admin/SYSTEM.
```

### Shared library

`scripts/shared/` contains a placeholder `README.md` only. There is no shared library, no sourced helper, and no cross-platform contract; every script is self-contained. The one near-duplicate is `devbox-worker.ps1`, which `remediate-devbox.ps1` also embeds byte-for-byte in its `$WorkerSource` here-string and writes to `$env:ProgramData\devbox\devbox-worker.ps1`. The standalone file exists so the installed worker is reviewable. **Edit both together and keep them identical**; nothing enforces it. A future shared helper needs a documented sourcing contract before any script depends on it, and must not blur the privilege split.

### Platform scripts

`scripts/windows/` is a three-part Intune Remediations package: detection (read-only, exits non-zero to request remediation), remediation (all mutation, gated by `ShouldProcess`), and the worker the registered tasks invoke. State lives in `$env:ProgramData\devbox` (`config.json`, `version.txt`, `devbox-worker.ps1`, `logs/`); the live VHDX in the selected user's `AppData\Local\devbox`; backups in that user's `Documents\devbox\<machine-lowercase>`. Remediation picks the most recently used non-special `Win32_UserProfile` and resolves its Documents known folder from `HKEY_USERS`, deferring with a warning when none resolves rather than guessing. Concurrency uses the named mutexes `Global\DEVBOX_REMEDIATION` and `Global\DEVBOX_BACKUP`. Backups are VSS crash-consistent copies, SHA-256 hashed into a sidecar `.json` manifest, staged through `.partial` and moved into place only on success.

`scripts/macos/` is one multi-mode script. State lives under `~/Library/Application Support/devbox`; the image is `devbox.sparsebundle`; the mount point is `/Volumes/devbox`, browsable unless `DEVBOX_HIDE_VOLUME=true` mounts it `nobrowse`. Install copies the script to `$USER_ROOT/devbox.sh` and points both launchd agents (`com.blackoutsecure.devbox.mount`, `.backup`) at that copy, so the working tree and the scheduled copy drift if only one is updated. Backup ejects, `ditto`s the detached sparsebundle, computes a tree hash, writes a manifest, applies retention, remounts; concurrency is a `mkdir` lock directory with an `EXIT` trap. Both platforms share the same twelve workspace directories, 50 GB default size, 02:00 backup, 14-backup retention, and `schemaVersion: 3` manifest shape - keep those aligned.

`scripts/linux/` has no scripts. A Linux implementation needs its own image format, scheduler, and privilege decision, not a search-and-replace port of the macOS script.

### Documentation

`docs/README.md` is an empty placeholder for runbooks. Real per-script documentation is the platform `README.md` plus the header comment in each script stating supported platform, required privileges, and repeat safety. Update both in the same change as any behaviour, prerequisite, default, or privilege change. The platform READMEs duplicate every default in a table, so a default changed in code but not in the table is a silent documentation defect.

## Safety invariants

- Prefer read-only inspection over mutation. `status` and `detect-devbox.ps1` stay read-only, and a new capability ships its reporting path before its apply path.
- Require explicit confirmation before any change to endpoint configuration: shell scripts take `--dry-run`, PowerShell scripts declare `SupportsShouldProcess` and wrap every mutation in `ShouldProcess`. A mutation unreachable through the preview path is a defect.
- Make every operation idempotent and re-runnable; install, repair, and upgrade converge, and a second run is a no-op.
- Back up or stage before overwriting. Write through `.tmp`/`.partial` and move into place only on success, as the config, plist, and backup paths already do. Never truncate in place.
- Never disable a security control to make a check pass - no weakened execution policy beyond the scoped `-ExecutionPolicy Bypass` used for task invocation, no disabled VSS, Defender, SIP, TCC, or Gatekeeper, no broadened ACLs to dodge an access error.
- Never collect or log user data, credentials, or device identifiers beyond what the task needs. The scripts record a machine name, user SID, and profile paths; treat that as the ceiling. Tokens, tenant IDs, and internal URLs never appear.
- Keep elevated-privilege operations narrowly scoped and clearly marked: Windows scripts declare `#requires -RunAsAdministrator` and state privileges in the header, the macOS script actively refuses root. Do not add `sudo` to the macOS path.
- Guard concurrency. Any mutation reachable from a scheduler holds a mutex or lock directory.

## Conventions

macOS shell: `#!/bin/bash`, `set -euo pipefail`, a header stating platform, privileges, repeat safety, usage, and Intune guidance. Tunables are `"${VAR:-default}"` overrides inside a fenced `CONFIGURABLE VARIABLES` block. System binaries are called by absolute path so a modified `PATH` cannot substitute them, and every expansion is quoted. One `log()` helper takes a message and level (`INFO`/`WARN`/`ERROR`/`SUCCESS`) and skips the log file in dry-run; previews go through `dry_run_notice`. Each mutating function returns early on `[[ "$DRY_RUN" == "true" ]]` with a `would ...` line rather than branching inside the work. Root is not requested - it is rejected:

```bash
if [[ "$CURRENT_UID" -eq 0 || "$CURRENT_USER" == "root" ]]; then
  echo "ERROR: Configure this script to run as the signed-in user, not root." >&2
  exit 1
fi
```

Platform capability is detected, not assumed: macOS probes `diskutil image` for `create|attach|info`; Windows checks that `diskpart.exe` and the disk cmdlets resolve and that `Format-Volume` exposes `-DevDrive` before touching anything.

PowerShell: `#requires -Version 5.1` plus `#requires -RunAsAdministrator` where elevation is needed, comment-based help with `.SYNOPSIS`, `.DESCRIPTION`, and a `.NOTES` block naming platform, privileges, and repeat safety, then `Set-StrictMode -Version Latest` and `$ErrorActionPreference = 'Stop'`. Mutating scripts use `[CmdletBinding(SupportsShouldProcess = $true)]` and gate each change on `$PSCmdlet.ShouldProcess(<target>, <description>)`. Paths are always `-LiteralPath`. `Write-DevboxLog -Message -Level` emits `WHATIF:` output instead of writing when `$WhatIfPreference` is set. Failures `throw` into one top-level `try/catch/finally` that logs, releases the mutex, and exits non-zero. Detection speaks a fixed vocabulary - `COMPLIANT`, `REMEDIATION_REQUIRED: <CODE;CODE>`, `DETECTION_ERROR: <message>` - treat those as a contract.

Adding a check or remediation: kebab-case filename in the matching platform directory; the platform's header block; the tunable in `CONFIGURABLE VARIABLES`; every mutation routed through `--dry-run` or `ShouldProcess`; the existing logging helper; a concurrency guard; and the platform `README.md` table updated. When a capability should exist on both platforms, keep the state schema, defaults, mode names, and manifest shape identical and change both together.

## Blackout Secure conventions

These apply to every repository in the `blackoutsecure` organization.

### Branch model

- `dev` is the default branch and where all work lands.
- `main` is the promoted stable runtime that consumers reference through `@main`.
- Version tags (`vX.Y.Z` and a floating `vX`) point at promoted runtime commits.
- Promotion is driven from `bos-automation-hub`. Do not push directly to `main` and do not
  move tags by hand.

This repository follows that model - `dev` is default, `origin/main` exists behind it - but has no version tags yet. Script versions are tracked in-file: `DEVBOX_VERSION` `3.0.1` on macOS, `$DevboxVersion` `2.1.0` on Windows, with `detect-devbox.ps1` asserting `$RequiredVersion`. Bump those together with their README tables.

### Centrally managed files - do not hand-edit here

`blackoutsecure/bos-automation-hub` distributes community health and lint configuration
files through `bos-managed-file-sync-action`. Where a file in this repository carries a
managed-file-sync delimiter block, change the source under the hub's `sync-files/`, never
the copy here.

No file here carries a delimiter block today. `LICENSE` and `NOTICE` are present and are the org-standard Apache-2.0 pair, byte-identical to the hub's `sync-files/legal/LICENSE`, so enabling `license_service` is a no-op rather than a rewrite. `CODE_OF_CONDUCT.md`, `SECURITY.md`, and `SUPPORT.md` are still absent. `README.md` and `CONTRIBUTING.md` are repo-authored; expect them to be replaced if the sync is enabled.

### Licensing

This repository is Apache-2.0, matching every other public `bos-*` repository. It is a public toolkit, not an internal asset, so it takes the organization default rather than the proprietary licence used by `int-blackoutsecure-site`, `bos-skillforge-labs`, and `bos-skillforge-platform`. Keep `LICENSE` byte-identical to the hub source and keep the `NOTICE` attribution line in step with the project name; do not select `proprietary_license_service` here.

### CI gate

Where a repository is wired to it, pushes and pull requests run the hub's reusable
`bos-universal-security.yml`, reported as a single required check: markdownlint, yamllint,
shellcheck, actionlint, `bos-code-scanning-kit`, CodeQL, dependency review, and compliance
checks for the canonical README header and a conventional-commit PR title.

This repository is not wired to it - no `.github/` directory and no workflow of any kind. `origin/chore/seed-bos-universal-gatekeeper-kicker` exists but has not landed on `dev`.

Every `uses:` reference in a workflow must be a commit SHA with a trailing version comment,
for example `actions/checkout@<sha> # v4.2.2`. That applies to the first workflow added here.

## Boundaries

### Always

- Run the syntax check, then the linter, then a preview, then a real run on a disposable VM or scratch account for the platform touched.
- Route every state change through `--dry-run` on macOS and `ShouldProcess` on Windows, and confirm the preview names the change you made.
- Apply twice and confirm convergence rather than repeated work.
- Update the platform `README.md` and the script header alongside any behaviour, default, prerequisite, or privilege change.
- Keep `scripts/windows/devbox-worker.ps1` byte-identical to the `$WorkerSource` here-string in `remediate-devbox.ps1`.
- Keep macOS user-scoped and Windows explicitly elevated, with privileges stated in the header.
- Write through `.tmp` or `.partial` and move into place only on success.

### Ask first

- Adding a remediation that changes endpoint security configuration - execution policy, scheduled task principals, launchd agent scope, ACLs, VSS, Defender, SIP, TCC, Gatekeeper.
- Changing any default: image size, mount point, drive letters, backup hour, retention count, launchd label prefix, state or backup paths, volume visibility. Each is documented and deployed, so a change silently reconfigures existing endpoints.
- Anything requiring new elevated privileges, a broader task principal, or a wider credential scope - in particular introducing `sudo` into the macOS path.
- Changing the `config.json` schema (`schemaVersion: 3`), the backup manifest shape, or the `COMPLIANT` / `REMEDIATION_REQUIRED` / `DETECTION_ERROR` vocabulary that Intune reporting depends on.
- Bumping `DEVBOX_VERSION` or `$DevboxVersion`, which forces remediation on every endpoint through the `VERSION_MISMATCH` code.
- Adding a shared helper under `scripts/shared/`, a first script under `scripts/linux/`, a third-party dependency, or the first workflow under `.github/`.

### Never

- Never run against a production endpoint during development, including your own workstation when the change touches image creation, retention deletion, or agent or task registration.
- Never commit real host inventories, endpoint identifiers, machine names, user SIDs, profile paths, `config.json` or manifest output, `devbox.log`, backups, disk images, credentials, tokens, tenant IDs, or internal URLs. `*.log`, `reports/`, and `output/` are gitignored as a backstop, not permission.
- Never weaken or disable a security control to make output look clean - no lowered execution policy, disabled VSS or Defender, broadened ACLs, suppressed error, blanket `shellcheck disable`, or `|| true` around a failing check.
- Never push directly to `main` or move a version tag by hand; promotion runs from the hub.
- Never add a mutation that bypasses `--dry-run` or `ShouldProcess`, remove the macOS root refusal, or drop `set -euo pipefail`, `Set-StrictMode`, or `$ErrorActionPreference`.
- Never remove a concurrency guard - the `Global\DEVBOX_*` mutexes or the macOS lock directory and its `EXIT` trap.
- Never delete user data outside the documented retention and `purge` paths, and never edit the macOS script while it is running, since Bash reads it incrementally.
