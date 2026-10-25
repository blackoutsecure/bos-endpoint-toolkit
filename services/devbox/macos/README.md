# Devbox on macOS

[Devbox overview](../README.md) | [Framework](../../../framework/README.md)

Devbox manages a user-scoped APFS sparsebundle mounted at `/Volumes/devbox`.
Its native Bash backend supports command-line use and managed deployment without
requiring Node.js, Rust, a GUI, or a resident agent.

## Prerequisites and safe inspection

- Run as the signed-in user, never root.
- Use Bash, not `sh`; the code uses arrays and Bash conditionals.
- The host needs `diskutil image create`, `attach`, `info`, and `resize`,
  `diskutil apfs resizeContainer`, and the native `hdiutil`, `launchctl`,
  `plutil`, `ditto`, and hashing utilities used by the script.
- Configuration uses native plutil JSON/key-path support. Verify actual host
  capabilities; an older macOS version with a diskutil binary is not sufficient.

On the build machine, from the repository root:

```text
npm ci --ignore-scripts
npm run build
```

Deploy `output/devbox/macos/manage-devbox.sh`, not the authoring template in this
directory. It embeds configuration defaults and validation; no adjacent source
file or third-party endpoint dependency is needed.

Examples below use a CLI variable set from the repository root:

```bash
CLI="$(pwd)/output/devbox/macos/manage-devbox.sh"
"$CLI" config
"$CLI" status
"$CLI" --dry-run resize
```

`config` and `status` are read-only. `--dry-run resize` does not attach images,
write files, or create locks. Other modes do not have a complete preview;
unsupported dry-run combinations fail without applying. Test mutations only
on a disposable Mac or scratch user account.

## Modes

| Mode | Behavior |
| --- | --- |
| `config` | Print effective JSON to stdout and configuration-source information to stderr. |
| `status` | Print installed version, paths, mount state, latest backup, and capacity. |
| `install`, `repair` | Reconcile image/filesystem capacity, directories, desired/runtime state, installed CLI, and user agents. |
| `resize` | Grow existing image/filesystem without installing agents; preserve previous attachment state. |
| `mount` | Mount the image and ensure workspace directories. |
| `backup` | Detach, copy, validate, hash, publish metadata, apply retention, and restore mount state. |
| `restore [path]` | Restore a selected/discovered backup only when the live image is absent, then reconcile capacity and mount. |
| `validate [live\|path]` | Validate the requested artifact; live failures never fall through to a good backup. May attach read-only and log. |
| `uninstall` | Remove user automation and metadata; retain image and backups. |
| `purge` | Remove user automation, image, and backups. Destructive; no preview. |

## Configuration

See the [shared defaults](../config/defaults.json) and
[schema](../config/schema.json). Current implementation version is `3.6.0`,
owned by [service metadata](../service.json), not a deployment setting.

```bash
"$CLI" --config /path/to/devbox.json config
"$CLI" --config /path/to/devbox.json status
```

A partial profile declares `schemaVersion: 1`; macOS-specific settings live under
`macos`. The [service guide](../README.md#configuration) defines shared settings,
merge semantics, units, and migrations. Explicit missing/invalid files fail.
An explicit profile replaces the installed snapshot as the input for that run,
while unspecified values come from packaged defaults.
Without an explicit file, an adjacent desired configuration is preferred;
otherwise discovery uses the packaged service name, never an unrelated
installation's default-name configuration.

Legacy `DEVBOX_*` environment overrides remain supported; the schema's `x-env`
annotations define their mapping. They apply after file configuration, must have
valid types/ranges, and are captured during install/repair. For example:

```bash
DEVBOX_SIZE_GB=200 DEVBOX_HIDE_VOLUME=true "$CLI" --dry-run resize
```

`DEVBOX_VERSION` is release-owned; a differing old version override fails
explicitly and must be removed rather than spoofing installed metadata.

Install/repair atomically persists effective desired configuration alongside the
installed CLI. Generated mount/backup agents pass that file explicitly, so
custom settings survive unattended execution. Changing configuration alone does
not rewrite agent schedules; reconcile it with install/repair.

When no desired file exists, compatible settings recorded in legacy schema 3
`config.plist` are read with a visible migration notice. Old state did not record
every environment override, including capacity; inspect configuration and supply
any missing customization before repair.

Default installed locations remain:

- CLI/image/state: `~/Library/Application Support/devbox`
- Desired configuration: `desired-config.json` beside the installed CLI
- Image: `devbox.sparsebundle`
- Mount point: `/Volumes/devbox`
- Backups: `~/Documents/devbox/<machine-name>`
- User agents: `~/Library/LaunchAgents/com.blackoutsecure.devbox.{mount,backup}.plist`

The volume remains browsable by default. `macos.hideVolume: true` uses `nobrowse`;
it does not change the mount location. Do not change names, labels, or prefixes
as an implicit migration of existing data.

## Changing capacity

`macos.sizeGB` (or `DEVBOX_SIZE_GB`) accepts whole numbers from 1 through 65536.
One GB is 1,000,000,000 bytes, rounded up to 4 KiB alignment. APFS usable space
is slightly smaller. The default is still 100 GB.

```bash
DEVBOX_SIZE_GB=200 "$CLI" --dry-run resize
# On a disposable target after a verified backup:
DEVBOX_SIZE_GB=200 "$CLI" resize
```

Use a CLI copy and working directory outside the mounted Devbox. A busy volume
is not forcibly detached. Resizing shares the backup lock, validates disk identity,
grows image and APFS in place, preserves mount/attachment state, and refuses
shrinking. Retry to finish filesystem-only growth after a partial failure;
never recreate or reformat the existing image.

Explicit `resize` does not rewrite desired configuration or schedules. Persist
a new setting through install/repair before relying on later maintenance runs.
Scheduled mount/backup operations never resize.

## Backup compatibility

New schema 5 metadata records `treeHashFormat: relative-path-v1`. Hashing uses
deterministic relative paths and contents, so relocating a backup and its metadata
does not invalidate it.

Schema 4 metadata remains unchanged and uses the legacy absolute-path hash.
Verify those backups at their recorded original absolute location and create a
schema 5 backup before relocation. A relocated schema 4 backup fails explicitly;
the script does not skip verification or silently rewrite its metadata.
Unknown hash/schema formats fail explicitly.

Restore refuses to continue after failed ejection or staging cleanup. If the
final move into the live-image location fails, recovery returns an error without
claiming completion; the validated `<image-path>.restore-partial` remains for
inspection. Preserve it and the original backup while resolving the filesystem
error. A subsequent restore clears that staging path and recopies the backup.

Backup and validation may take time, need privacy permission for the destination,
and are not read-only previews. Local backups on the same machine do not replace
off-device recovery.

## Managed PKG deployment

The build stages a deterministic payload below `output/devbox/macos/package-root`.
It contains:

- `/usr/local/libexec/bos-endpoint-toolkit/devbox/manage-devbox.sh`
- `/Library/Application Support/BlackoutSecure/EndpointToolkit/devbox/desired-config.json`
- `/Library/LaunchAgents/com.blackoutsecure.devbox.initialize.plist`
- License/notice under `/usr/local/share/doc/bos-endpoint-toolkit/devbox`

The initialization label follows a customized launchd prefix. This machine-owned
LaunchAgent runs as each eligible GUI user at login and initializes/updates their
existing user-scoped installation. There is no root postinstall workspace
creation, LaunchDaemon, sudo, or persistent polling process.

For a test package on a macOS build machine:

```bash
bash tools/package-macos.sh --unsigned
```

For release, use an existing approved Developer ID Installer identity and
notarytool keychain profile:

```bash
bash tools/package-macos.sh \
  --sign "Developer ID Installer: Organization (TEAMID)" \
  --notary-profile approved-notary-profile
```

The tool signs the flat package, waits for notarization (10-minute bound),
staples, and verifies the result before publishing it. It does not create,
export, or commit credentials. Unsigned packages are clearly labeled validation
artifacts and are never equivalent to signed release packages.

Deploy with the management product's supported arbitrary-PKG mechanism, receipt
version/custom detection, and tested update/removal behavior. PKG installation
and managed-app lifecycle are different capabilities; verify product support.
No `.app` is required. A future optional GUI must share the CLI engine and must
not be selected merely because no terminal is attached.

An already logged-in user may need to log out/in before the newly installed
initialization agent is loaded. Do not run the CLI as root to accelerate setup.
Choose a consistent profile for the fleet; changing its service name or prefix
requires a separate migration.

Signed packages and root privileges do not bypass TCC/privacy controls.
Validate Documents access in a real managed user session. Configuration profiles
do not automatically configure this JSON CLI; the package or explicit CLI
argument must deliver the configuration it actually reads.

Direct Intune script deployment can still run the generated standalone script as
the signed-in user; do not choose root. Inspect first, then use a documented
schedule/retry policy. Node/npm are build-machine requirements only.

## Capacity regression tests

```bash
npm run build
bash services/devbox/macos/tests/contracts.sh
bash services/devbox/macos/tests/configuration.sh
bash services/devbox/macos/tests/resize-devbox.sh
```

Contracts test portable hashes and validation dispatch without disks. Native
configuration tests use private HOME/configuration and serialize agents without
registering them. The capacity suite uses a private temporary sparsebundle,
preserves a canary through real growth, and tests previews, no-op repeats,
locking, shrink refusal, partial recovery, and attachment restoration.
Run it only on a supported non-root disposable Mac; failure retains evidence.

## Rollback

For a managed package, first remove/unload its global initialization agent through
your deployment tooling, or the next login will reinstall the user automation.
Remove machine-owned payload/configuration only after fleet removal requirements
are understood; forgetting an agent while deleting its executable leaves broken
login jobs. Removing a package receipt alone does not uninstall its payload.

Then run, as the affected user:

```bash
"$CLI" uninstall
```

This retains the live image and backups. Uninstall/purge refuses to continue
past a failed eject. Purge is separate and destructive:

```bash
"$CLI" purge
```

Never use purge as a layout, packaging, or deployment test. Preserve any required
backups before retiring automation.
