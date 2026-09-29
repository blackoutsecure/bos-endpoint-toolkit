# Devbox

Devbox provides a disk-image-backed development workspace with automated mounting
and backups. This is a local endpoint capability, not Microsoft Dev Box provisioning.

## Implementations

| Platform | Entry points and documentation | Required privileges |
| --- | --- | --- |
| Windows | [Detection, remediation, and scheduled worker](./windows/README.md) | Administrator or SYSTEM; installation requires Windows 11 Dev Drive support |
| macOS | [Workspace management script](./macos/README.md) | Signed-in user; refuses root |

There is no Linux implementation yet. The Windows and macOS implementations are
independent and use different storage formats, schedulers, and backup mechanisms.
Their versions, configuration formats, and installed locations are unchanged by
the repository reorganization.

## Capacity

Both platforms now default to **100 GB**. Raising the configured size grows an
existing workspace in place during installation or repair, including its
filesystem. A repeated run leaves capacity alone when both layers are already
correct. Smaller requests fail explicitly: no automatic shrink, deletion, or
reformatting is performed.

macOS retains native decimal GB units; Windows retains PowerShell's binary
`1GB` units (GiB). The images are sparse/dynamic, so their virtual capacity is
not immediately allocated on the host disk. Keep enough host storage available
for actual data and backups.

Back up first, close active workspace files before growth, and follow the
platform guide for configuration and preview commands. Scheduled mount/backup
operations do not independently resize an image.

## Package layout

```text
devbox/
  README.md
  windows/
    README.md
    detect-devbox.ps1
    remediate-devbox.ps1
    devbox-worker.ps1
    tests/
      resize-devbox.ps1
  macos/
    README.md
    manage-devbox.sh
    tests/
      resize-devbox.sh
```

The Windows files are one related deployment package. The macOS script handles
its supported operations through modes. Neither implementation depends on a shared
repository runtime or on files from the other OS folder.

Keep platform prerequisites, configuration, examples, and rollback guidance in
the corresponding platform README. Add task-specific templates or supporting
files next to the script that owns them only when needed; do not add empty
dependency folders or duplicate helpers between OS implementations.

## Safe entry points

From the repository root:

```bash
# macOS: read-only inspection
./scripts/devbox/macos/manage-devbox.sh status
./scripts/devbox/macos/manage-devbox.sh --dry-run resize
```

```powershell
# Windows: elevated detection and remediation preview
.\scripts\devbox\windows\detect-devbox.ps1
.\scripts\devbox\windows\remediate-devbox.ps1 -WhatIf
```

macOS `--dry-run resize` previews capacity changes only; it does not attach an
image or write files. Do not substitute an `install`, `repair`, or `validate`
run for a full preview on a configured machine.
Exercise state-changing operations only on a disposable endpoint or scratch
user account, following the platform documentation.

## Repository-path migration

Source paths now begin with `scripts/devbox/macos/` or `scripts/devbox/windows/`
instead of `scripts/macos/` or `scripts/windows/`. Update checkout-relative
commands, raw-file URLs, and deployment source references that used the old
paths. There are no compatibility wrappers at the old paths.

Existing installed scripts, scheduled tasks, LaunchAgents, disk images, and
backups retain their original locations. Moving source files is not an instruction
to reinstall or recreate a workspace.

[Toolkit overview](../../README.md) | [Documentation index](../../docs/README.md)
