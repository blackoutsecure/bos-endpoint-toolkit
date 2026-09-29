# AGENTS.md

This file provides guidance to agents when working with code in this repository.

## What this is

`bos-endpoint-toolkit` is a set of standalone operational scripts for administering Windows, Linux, and macOS endpoints. It is not a hardening or compliance scanner. The only capability implemented today is **devbox**: a per-user development workspace backed by a disk image - a ReFS Dev Drive VHDX on Windows, an APFS sparsebundle on macOS - plus the scheduled tasks or launchd agents that mount it and back it up nightly under a retention policy. `README.md` calls the toolkit Intune-adjacent; the scripts are platform-native and depend on no management platform, agent, or shared runtime.

The repository is organized by capability, then OS: `scripts/<capability>/<os>/`. The two Devbox implementations are independent code, not one engine with two front-ends. `scripts/devbox/windows/` holds three PowerShell 5.1 deployment scripts that require administrator or SYSTEM; remediation needs Windows 11 Dev Drive support and previews through `-WhatIf` via `SupportsShouldProcess`. `scripts/devbox/macos/` holds one Bash management script for macOS releases whose `diskutil image` subcommand exposes `create`/`attach`/`info`/`resize`, with APFS container resizing support. It offers `--dry-run resize` only, not a full install/repair preview. It runs as the signed-in user and **refuses to run as root**, because the image, backups, launchd agents, and support files are all user-scoped. No Linux implementation or shared library exists, so there are no placeholder OS/shared folders.

Elevated privilege is therefore required on Windows and prohibited on macOS. Do not assume symmetry: the privilege model, image format, scheduler, and backup consistency mechanism all differ by design.

Stack. Windows: Windows PowerShell 5.1 (`#requires -Version 5.1`), 64-bit, `Set-StrictMode -Version Latest`, `$ErrorActionPreference = 'Stop'`, relying on `diskpart.exe`, `Get-DiskImage`/`Mount-DiskImage`, `Initialize-Disk`, `New-Partition`, `Format-Volume -DevDrive` (Windows 11 only), `Register-ScheduledTask`, and the `Win32_ShadowCopy` VSS class. macOS: Bash with `#!/bin/bash` and `set -euo pipefail`; it uses `[[ ]]`, arrays, and brace expansion, so it is not `sh`. It calls `diskutil`, `hdiutil`, `launchctl`, `plutil`, `ditto`, `scutil`, and `shasum` by absolute path. There is no package manifest, build step, lockfile, or third-party dependency.

## Commands

macOS. `status` and `--dry-run resize` are read-only. There is no full install/repair preview; do not treat an apply mode as a preview. Run the mutating examples below only on a disposable endpoint or scratch user account.

```bash
cd /Volumes/devbox/repos/blackoutsecure/bos-endpoint-toolkit

./scripts/devbox/macos/manage-devbox.sh status
DEVBOX_SIZE_GB=200 ./scripts/devbox/macos/manage-devbox.sh --dry-run resize

./scripts/devbox/macos/manage-devbox.sh install     # or: repair | mount | backup
./scripts/devbox/macos/manage-devbox.sh uninstall   # keeps the image and backups
./scripts/devbox/macos/manage-devbox.sh purge       # removes the image and backups

DEVBOX_SIZE_GB=200 DEVBOX_HIDE_VOLUME=true ./scripts/devbox/macos/manage-devbox.sh install
```

Windows, in an elevated 64-bit PowerShell on a disposable endpoint.

```powershell
.\scripts\devbox\windows\detect-devbox.ps1              # read-only; COMPLIANT or REMEDIATION_REQUIRED
.\scripts\devbox\windows\remediate-devbox.ps1 -WhatIf   # preview every state change
.\scripts\devbox\windows\remediate-devbox.ps1           # apply
& "$env:ProgramData\devbox\devbox-worker.ps1" -Mode Status
& "$env:ProgramData\devbox\devbox-worker.ps1" -Mode Backup -WhatIf
```

Lint and syntax. `CONTRIBUTING.md` asks for these "when available"; run them anyway.

```bash
bash -n scripts/devbox/macos/manage-devbox.sh
shellcheck scripts/devbox/macos/manage-devbox.sh

pwsh -NoProfile -Command "Invoke-ScriptAnalyzer -Path scripts/devbox/windows -Recurse"
pwsh -NoProfile -File /dev/stdin <<'PS'
Get-ChildItem scripts/devbox/windows -Filter *.ps1 | ForEach-Object {
  [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$null) | Out-Null
}
PS
```

## Validating changes

**There is no CI in this repository.** There is no `.github/` directory, no workflow, no managed kicker, and no lint configuration file. Nothing runs on a push or a pull request. Local validation is the entire gate. Dependency-free capacity regression scripts live under each Devbox OS folder's `tests/`.

Narrowest first, then escalate to a real run:

1. Syntax - `bash -n` for the macOS script; a PowerShell AST parse or `Invoke-ScriptAnalyzer` for anything under `scripts/devbox/windows/`.
2. Lint - `shellcheck`, `Invoke-ScriptAnalyzer`.
3. Preview - `-WhatIf` on Windows; on macOS use `status` and `--dry-run resize`. Other macOS apply modes lack preview support and require a disposable target.
4. Real run on a disposable VM or scratch user account for the platform touched: read-only path first (`status`, `detect-devbox.ps1`), then apply, then apply again to confirm it converges rather than repeating work, then rollback (`uninstall`; `purge` only on scratch data).

Reasoning about correctness is not sufficient for behavior changes. These scripts create and format disk images, register SYSTEM scheduled tasks and launchd agents, take VSS snapshots, copy multi-gigabyte images, and delete files under retention. A preview, where implemented, proves the intended plan, not that the apply path works.

Run `bash scripts/devbox/macos/tests/resize-devbox.sh` on a supported Mac for isolated native sparsebundle/APFS tests, and `powershell.exe -NoProfile -File scripts/devbox/windows/tests/resize-devbox.ps1` in a separate process for mocked Windows storage tests. The latter also runs on PowerShell 7, but cannot prove actual Windows 11 ReFS/Dev Drive behavior; native Windows integration validation still requires a disposable target. Neither suite installs agents or tasks or operates on live user images.

For a path-only relocation, compare all script bytes and executable modes against the original files, verify embedded worker code parity, scan path references, and check documentation links. Do not deploy to a configured endpoint just to validate a directory move.

Production endpoints are never a test target, and neither is your own workstation when the change touches image creation, retention deletion, or agent or task registration. macOS `purge` deletes `~/Library/Application Support/devbox` and `~/Documents/devbox/<machine>`; Windows retention deletes backup VHDX files beyond the configured count.

## Architecture

```text
README.md                          Toolkit purpose, layout, rules for adding a script
CONTRIBUTING.md                    Script requirements and manual validation procedure
.gitignore                         Editor/OS files, *.log, reports/, output/
docs/README.md                     Index of capability guides and cross-capability runbooks
scripts/devbox/README.md           Devbox overview, platform entry points, migration notes
scripts/devbox/macos/README.md     Modes, prerequisites, configuration, deployment, rollback
scripts/devbox/macos/manage-devbox.sh
                                  Bash. APFS sparsebundle and two user LaunchAgents.
                                  Modes: install, repair, resize, mount, backup, restore, validate,
                                  status, uninstall, purge. Signed-in user; refuses root.
scripts/devbox/windows/README.md   Prerequisites, Intune settings, detection codes, rollback
scripts/devbox/windows/detect-devbox.ps1
                                  Read-only detection; COMPLIANT or REMEDIATION_REQUIRED.
scripts/devbox/windows/remediate-devbox.ps1
                                  Install/repair: ReFS Dev Drive VHDX, state, worker, tasks.
scripts/devbox/windows/devbox-worker.ps1
                                  Reviewable worker copy. Mount, Backup, Status. Admin/SYSTEM.
```

### Shared library

There is no shared library, sourced helper, or cross-platform runtime contract; every script is self-contained. The worker code in `scripts/devbox/windows/devbox-worker.ps1` is also embedded in `remediate-devbox.ps1` as `$WorkerSource` and written to `$env:ProgramData\devbox\devbox-worker.ps1`. The standalone copy has extra help/comments; the executable code matches. **Edit both implementations together**; nothing enforces parity automatically. A future shared helper needs demonstrated reuse and a documented sourcing contract, and must not blur the privilege split. Do not create an empty shared directory.

### Platform scripts

`scripts/devbox/windows/` is a three-part Intune Remediations package: detection (read-only, exits non-zero to request remediation), remediation (all mutation, gated by `ShouldProcess`), and the worker the registered tasks invoke. State lives in `$env:ProgramData\devbox` (`config.json`, `version.txt`, `devbox-worker.ps1`, `logs/`); the live VHDX in the selected user's `AppData\Local\devbox`; backups in that user's `Documents\devbox\<machine-lowercase>`. Remediation picks the most recently used non-special `Win32_UserProfile` and resolves its Documents known folder from `HKEY_USERS`, deferring with a warning when none resolves rather than guessing. Concurrency uses the named mutexes `Global\DEVBOX_REMEDIATION` and `Global\DEVBOX_BACKUP`. Backups are VSS crash-consistent copies, SHA-256 hashed into a sidecar `.json` manifest, staged through `.partial` and moved into place only on success.

`scripts/devbox/macos/` is one multi-mode script. State lives under `~/Library/Application Support/devbox`; the image is `devbox.sparsebundle`; the mount point is `/Volumes/devbox`, browsable unless `DEVBOX_HIDE_VOLUME=true` mounts it `nobrowse`. Install copies the script from `$0` to `$USER_ROOT/devbox.sh` and points both LaunchAgents (`com.blackoutsecure.devbox.mount`, `.backup`) at that installed copy, independent of the repository layout. Backup ejects, copies the detached sparsebundle with `ditto`, validates it, writes plist metadata, applies retention, and remounts. Concurrency is a `mkdir` lock directory with cleanup traps. Windows uses JSON backup metadata with schema version 3; current macOS backup metadata is plist schema version 4. Both retain the same twelve workspace directories, 02:00 backup, and 14-backup retention.

Both platforms default to 100 GB and reconcile existing image and filesystem capacity during install/repair. macOS preserves native decimal GB/4 KiB alignment; Windows preserves PowerShell GiB units. A larger target grows in place; a smaller one fails rather than shrinking, deleting, or reformatting. The resize paths share the backup concurrency guards, re-resolve disk identity after attachment, and finish filesystem-only growth on retry. macOS also reconciles on `restore` and explicit `resize`, preserving the pre-resize mount state. Windows remediation ends mounted as before, and detection checks both capacity layers; keep `$DevboxSizeGB` identical in detection and remediation. Scheduled mount/backup modes do not resize.

There is no `scripts/devbox/linux/` implementation. A Linux implementation needs its own image format, scheduler, and privilege decision, not a search-and-replace port of the macOS script. Create its directory only when adding an implementation.

### Documentation

`docs/README.md` indexes the capability guides. Keep purpose and OS entry points in `scripts/devbox/README.md`, platform details in each OS `README.md`, and cross-capability runbooks under `docs/`. Update platform documentation and script headers together when behavior, prerequisites, defaults, or privileges change. Keep related deployment scripts together; an independent task may get its own subfolder with required templates/resources. Document external prerequisites rather than bundling installed dependencies. Update external deployment source paths when relocating files; installed state paths must not change incidentally.

## Safety invariants

- Prefer read-only inspection over mutation. `status` and `detect-devbox.ps1` stay read-only, and a new capability ships its reporting path before its apply path.
- Require explicit confirmation before changes to endpoint configuration and preview support for new state-changing operations: shell scripts take `--dry-run`, PowerShell scripts declare `SupportsShouldProcess` and wrap every mutation in `ShouldProcess`. macOS supports `--dry-run resize` only; never use another apply operation as a preview.
- Make every operation idempotent and re-runnable; install, repair, and upgrade converge, and a second run is a no-op.
- Back up or stage before overwriting. Write through `.tmp`/`.partial` and move into place only on success, as the config, plist, and backup paths already do. Never truncate in place.
- Never disable a security control to make a check pass - no weakened execution policy beyond the scoped `-ExecutionPolicy Bypass` used for task invocation, no disabled VSS, Defender, SIP, TCC, or Gatekeeper, no broadened ACLs to dodge an access error.
- Never collect or log user data, credentials, or device identifiers beyond what the task needs. The scripts record a machine name, user SID, and profile paths; treat that as the ceiling. Tokens, tenant IDs, and internal URLs never appear.
- Keep elevated-privilege operations narrowly scoped and clearly marked: Windows scripts declare `#requires -RunAsAdministrator` and state privileges in the header, the macOS script actively refuses root. Do not add `sudo` to the macOS path.
- Guard concurrency. Any mutation reachable from a scheduler holds a mutex or lock directory.

## Conventions

macOS shell: `#!/bin/bash`, `set -euo pipefail`, a header stating platform, privileges, repeat safety, usage, and Intune guidance. Tunables use `"${VAR:-default}"` overrides near the top of the script. System binaries are called by absolute path so a modified `PATH` cannot substitute them, and every expansion is quoted. One `log()` helper takes a message and level (`INFO`/`WARN`/`ERROR`/`SUCCESS`) and skips file writes in dry-run and status modes. Resizing returns before mutation when `DRY_RUN=true`, logging its plan. Root is not requested - it is rejected:

```bash
if [[ "$CURRENT_UID" -eq 0 || "$CURRENT_USER" == "root" ]]; then
  echo "ERROR: Configure this script to run as the signed-in user, not root." >&2
  exit 1
fi
```

Platform capability is detected, not assumed: macOS probes `diskutil image` for `create|attach|info`; Windows checks that `diskpart.exe` and the disk cmdlets resolve and that `Format-Volume` exposes `-DevDrive` before touching anything.

PowerShell: `#requires -Version 5.1` plus `#requires -RunAsAdministrator` where elevation is needed, comment-based help with `.SYNOPSIS`, `.DESCRIPTION`, and a `.NOTES` block naming platform, privileges, and repeat safety, then `Set-StrictMode -Version Latest` and `$ErrorActionPreference = 'Stop'`. Mutating scripts use `[CmdletBinding(SupportsShouldProcess = $true)]` and gate each change on `$PSCmdlet.ShouldProcess(<target>, <description>)`. Paths are always `-LiteralPath`. `Write-DevboxLog -Message -Level` emits `WHATIF:` output instead of writing when `$WhatIfPreference` is set. Failures `throw` into one top-level `try/catch/finally` that logs, releases the mutex, and exits non-zero. Detection speaks a fixed vocabulary - `COMPLIANT`, `REMEDIATION_REQUIRED: <CODE;CODE>`, `DETECTION_ERROR: <message>` - treat those as a contract.

Adding a check or remediation: use `scripts/<capability>/<os>/` and a kebab-case filename; the platform's header block; documented tunables; every new mutation routed through `--dry-run` or `ShouldProcess`; the existing logging helper; a concurrency guard; and updated capability/platform READMEs. Keep related scripts together. Preserve intentional platform differences in privilege, storage, scheduling, and metadata; do not silently change deployed formats while reorganizing source.

## Blackout Secure conventions

These apply to every repository in the `blackoutsecure` organization.

### Branch model

- `dev` is the default branch and where all work lands.
- `main` is the promoted stable runtime that consumers reference through `@main`.
- Version tags (`vX.Y.Z` and a floating `vX`) point at promoted runtime commits.
- Promotion is driven from `bos-automation-hub`. Do not push directly to `main` and do not
  move tags by hand.

This repository follows that model - `dev` is default, `origin/main` exists behind it - but has no version tags yet. Script versions are tracked in-file: `DEVBOX_VERSION` `3.5.0` on macOS, `$DevboxVersion` `2.1.0` on Windows, with `detect-devbox.ps1` asserting `$RequiredVersion`. Bump those together with their README tables only when changing the respective deployed implementation, not for a path-only move.

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
- Give new state-changing macOS paths `--dry-run` support and keep Windows changes behind `ShouldProcess`. macOS preview support is currently limited to resizing; other apply modes require disposable-target validation.
- Apply twice and confirm convergence rather than repeated work.
- Update the platform `README.md` and the script header alongside any behaviour, default, prerequisite, or privilege change.
- Keep executable code in `scripts/devbox/windows/devbox-worker.ps1` aligned with the `$WorkerSource` here-string in `remediate-devbox.ps1`; the standalone help/comments are additional documentation.
- Keep macOS user-scoped and Windows explicitly elevated, with privileges stated in the header.
- Write through `.tmp` or `.partial` and move into place only on success.

### Ask first

- Adding a remediation that changes endpoint security configuration - execution policy, scheduled task principals, launchd agent scope, ACLs, VSS, Defender, SIP, TCC, Gatekeeper.
- Changing any default: image size, mount point, drive letters, backup hour, retention count, launchd label prefix, state or backup paths, volume visibility. Each is documented and deployed, so a change silently reconfigures existing endpoints.
- Anything requiring new elevated privileges, a broader task principal, or a wider credential scope - in particular introducing `sudo` into the macOS path.
- Changing the `config.json` schema (`schemaVersion: 3`), the backup manifest shape, or the `COMPLIANT` / `REMEDIATION_REQUIRED` / `DETECTION_ERROR` vocabulary that Intune reporting depends on.
- Bumping `DEVBOX_VERSION` or `$DevboxVersion`, which forces remediation on every endpoint through the `VERSION_MISMATCH` code.
- Adding a shared runtime helper, a first Linux implementation under `scripts/<capability>/linux/`, a third-party dependency, or the first workflow under `.github/`.

### Never

- Never run against a production endpoint during development, including your own workstation when the change touches image creation, retention deletion, or agent or task registration.
- Never commit real host inventories, endpoint identifiers, machine names, user SIDs, profile paths, `config.json` or manifest output, `devbox.log`, backups, disk images, credentials, tokens, tenant IDs, or internal URLs. `*.log`, `reports/`, and `output/` are gitignored as a backstop, not permission.
- Never weaken or disable a security control to make output look clean - no lowered execution policy, disabled VSS or Defender, broadened ACLs, suppressed error, blanket `shellcheck disable`, or `|| true` around a failing check.
- Never push directly to `main` or move a version tag by hand; promotion runs from the hub.
- Never add a mutation that bypasses `--dry-run` or `ShouldProcess`, remove the macOS root refusal, or drop `set -euo pipefail`, `Set-StrictMode`, or `$ErrorActionPreference`.
- Never remove a concurrency guard - the `Global\DEVBOX_*` mutexes or the macOS lock directory and its `EXIT` trap.
- Never delete user data outside the documented retention and `purge` paths, and never edit the macOS script while it is running, since Bash reads it incrementally.
