# Devbox

Devbox provides a disk-image-backed development workspace with automatic mounting
and backups. It is a local endpoint service, not Microsoft Dev Box provisioning.

## Implementations

| Platform | Native backend | Privileges |
| --- | --- | --- |
| [Windows](windows/README.md) | PowerShell 5.1, dynamic ReFS Dev Drive VHDX, Task Scheduler, VSS backups | Administrator or SYSTEM |
| [macOS](macos/README.md) | Bash, APFS sparsebundle, user LaunchAgents, detached-image backups | Signed-in user; refuses root |

There is no Linux storage backend. A future Ubuntu implementation needs a
separately tested image/filesystem, mount authorization, scheduler, and backup
strategy. Do not translate the macOS script by renaming commands.

## Configuration

The [defaults](config/defaults.json) are the single authored source.
The [schema](config/schema.json) references
[common framework definitions](../../framework/schemas/configuration.schema.json).
The build resolves references locally and generates native validation descriptors.
JSON Schema references share definitions, not configuration values.

A partial profile must declare `schemaVersion: 1`:

```json
{
  "schemaVersion": 1,
  "retention": 21,
  "windows": {
    "sizeGiB": 200
  },
  "macos": {
    "sizeGB": 200,
    "hideVolume": true
  }
}
```

Only specified leaves replace defaults; arrays replace rather than concatenate.
Unknown keys, invalid types, unsupported schema versions, unsafe names, and
invalid ranges fail before endpoint mutation.

Resolution is:

1. Validated packaged defaults, including any build-time profile.
2. An explicit configuration file, or installed desired configuration when no
   file is supplied.
3. On macOS, explicit legacy `DEVBOX_*` environment overrides.

Inspection reports the selected file/source and effective values. Explicit
missing files are errors, not requests to fall back. Configuration is desired
state, not a policy-enforcement or secret-storage mechanism; no managed-lock
layer is implied.

Install/repair persists resolved desired configuration atomically. Generated
macOS agents explicitly reference that snapshot; the Windows worker consumes the
runtime state produced from the same desired configuration. Changing a file does
not independently rewrite scheduling: run install/repair to reconcile it.

Keep versions in [service metadata](service.json), not deployment profiles.
The build inserts the Windows version into both detection and remediation.

### Preserve native units

Defaults remain **100 GiB on Windows** (`107374182400` bytes) and
**100 decimal GB on macOS**, rounded up to 4 KiB (`100000002048` bytes).
The schema names the units explicitly; sharing configuration must not silently
change deployed capacities. Both backends grow image and filesystem in place
and refuse automatic shrinking.

The shared backup defaults remain 02:00 local time and 14 retained backups.
The same twelve workspace directory names come from the shared defaults.
Backups are local recovery copies, not an off-device disaster-recovery strategy.

## Build and use

From the repository root:

```text
npm ci --ignore-scripts
npm run build
```

The authoring tree is not a deployment package. Generated entry points contain
their defaults/helpers and require no adjacent configuration or worker source.

```powershell
.\output\devbox\windows\detect-devbox.ps1 -ShowConfiguration
.\output\devbox\windows\detect-devbox.ps1
.\output\devbox\windows\remediate-devbox.ps1 -DesiredConfigPath C:\staging\devbox.json -WhatIf
```

```bash
./output/devbox/macos/manage-devbox.sh config
./output/devbox/macos/manage-devbox.sh --config /path/to/devbox.json status
./output/devbox/macos/manage-devbox.sh --dry-run resize
```

macOS previews capacity only; other mutating modes require a disposable target.
For managed macOS installation, follow the
[signed PKG instructions](macos/README.md#managed-pkg-deployment).

## Compatibility and migration

Source moved from `scripts/devbox/<platform>/` to `services/devbox/<platform>/`.
Deployment URLs must now target generated release artifacts, not authoring
templates. There are no compatibility wrappers at the old source paths.

Installed script/data locations, Windows task names, macOS per-user agent labels,
VHDX/sparsebundle formats, and Windows runtime-state schema 3 are preserved.
Moving source files is not an instruction to recreate a workspace.

Desired configuration is a new, separate schema 1 document; it is not the existing
runtime state or backup manifest.

- Windows retains runtime state in ProgramData and adds `desired-config.json`.
  Apply an explicit profile to change an existing installation.
- macOS reloads installed `desired-config.json`. When only old schema 3
  `config.plist` state exists, it imports the recorded compatible settings and
  reports that settings not recorded there still use packaged defaults.
  Inspect configuration and explicitly set custom capacity before repair.
- New macOS backup metadata uses schema 5 and relative-path tree hashes.
  Existing schema 4 backups retain their old metadata and remain verifiable at
  their original absolute location. Verify there and create a schema 5 backup
  before relocating; do not relabel an old hash as the new format.

Changing service names, agent prefixes, storage locations, or filesystem formats
requires an explicit data/scheduler migration, not a defaults edit.

[Toolkit overview](../../README.md) | [Framework standards](../../framework/README.md)
