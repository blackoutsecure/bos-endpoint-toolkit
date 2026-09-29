# Devbox on macOS

[Devbox overview](../README.md) | [Documentation index](../../../docs/README.md)

Bash scripts for the user-scoped macOS Devbox workspace.

## Scripts

### [manage-devbox.sh](./manage-devbox.sh)

Creates and maintains a user-scoped APFS sparsebundle dev workspace mounted at
`/Volumes/devbox`. The script is designed for Intune-adjacent deployment and
general macOS endpoint repair workflows.

Supported modes:

- `install` or `repair`: create or repair the sparsebundle, reconcile its image
  and APFS capacity, mount it, create standard workspace directories, write
  config, and install per-user launchd agents.
- `resize`: reconcile an existing image's capacity without installing agents,
  changing scheduling, or creating backups. Preserve its prior mount state.
- `--dry-run resize`: report the desired capacity and planned inspection/growth
  without attaching the image or writing files.
- `mount`: mount the sparsebundle at `/Volumes/devbox`.
- `backup`: eject the volume if needed, copy the detached sparsebundle to the
  user's Documents folder, validate it, write verification metadata, and apply
  retention.
- `restore [path]`: restore a selected or discovered backup when no live image
  exists, reconcile its capacity, then mount it.
- `validate [live|path]`: validate the live image or a backup. Validation may
  attach the image read-only and writes diagnostic logs; it is not a dry run.
- `status`: print installed version, paths, mount state, latest-backup path,
  requested capacity, and current image size in bytes.
- `uninstall`: remove launchd agents and installed metadata while preserving the
  image and backups.
- `purge`: remove launchd agents, installed metadata, the image, and backups.

## Prerequisites and safe inspection

- Run as the signed-in user, never `root`.
- Use Bash, not `sh`. The script uses Bash arrays and conditional syntax.
- The host needs native `diskutil image create`, `attach`, `info`, and `resize`
  support and `diskutil apfs resizeContainer`, plus `hdiutil`, `launchctl`,
  `plutil`, `ditto`, and the standard macOS utilities used by the script.
  No third-party package or adjacent helper file is required.

Use `status` for read-only inspection and `--dry-run resize` for a capacity
preview. Other modes do not support `--dry-run`; unsupported preview combinations
fail without performing the operation. Test installation, backup, restoration,
and removal only on a disposable Mac or scratch user account.

From the repository root:

```bash
./scripts/devbox/macos/manage-devbox.sh status
./scripts/devbox/macos/manage-devbox.sh --dry-run resize
```

Commands below assume your current directory contains this README and script.

## Configuration

Set environment variables before running the script to override defaults:

| Variable                         | Default                     | Purpose                                   |
| -------------------------------- | --------------------------- | ----------------------------------------- |
| `DEVBOX_VERSION`                 | `3.5.0`                     | Version written to installed metadata.    |
| `DEVBOX_NAME`                    | `devbox`                    | Name used for support files and backups.  |
| `DEVBOX_SIZE_GB`                 | `100`                       | Desired virtual capacity in decimal GB.  |
| `DEVBOX_VOLUME_LABEL`            | `devbox`                    | Volume label and `/Volumes` mount suffix. |
| `DEVBOX_BACKUP_HOUR`             | `2`                         | Daily backup launchd hour.                |
| `DEVBOX_BACKUP_MINUTE`           | `0`                         | Daily backup launchd minute.              |
| `DEVBOX_RETENTION`               | `14`                        | Number of sparsebundle backups to keep.   |
| `DEVBOX_LAUNCHD_PREFIX`          | `com.blackoutsecure.devbox` | LaunchAgent label prefix.                 |
| `DEVBOX_REPAIR_MOUNT`            | `true`                      | Mount during install or repair.           |
| `DEVBOX_BACKUP_IF_OVERDUE_HOURS` | `36`                        | Catch-up backup threshold.                |
| `DEVBOX_HIDE_VOLUME`             | `false`                     | Use `true` to mount with `nobrowse`.      |
| `DEVBOX_AUTO_RESTORE`            | `true`                      | Look for a backup before creating a missing live image. |
| `DEVBOX_RESTORE_SEARCH_ALL_MACHINES` | `true`                  | Search backups from all machine folders. |
| `DEVBOX_VERIFY_BACKUP_HASH`      | `true`                      | Check a backup tree hash when metadata permits it. |
| `DEVBOX_ALLOW_BACKUP_WITHOUT_METADATA` | `true`                | Allow missing or incomplete metadata without a hash comparison. |
| `DEVBOX_VALIDATE_BACKUP_MOUNT`   | `true`                      | Read-only attach and detach during backup validation. |
| `DEVBOX_VERIFY_POST_BACKUP_HASH` | `true`                      | Verify the resulting backup after writing it. |
| `DEVBOX_CONDITIONAL_INSTALL_BACKUP` | `true`                   | Back up an existing workspace when needed during install/repair. |
| `DEVBOX_BACKUP_AFTER_RESTORE`    | `false`                     | Skip an immediate conditional backup after restoring. |

## Changing capacity

`DEVBOX_SIZE_GB` accepts whole numbers from 1 through 65536. One GB means
1,000,000,000 bytes, rounded up to the image's 4 KiB alignment. Usable APFS space
is slightly smaller because of partition and filesystem metadata.

The default grows an existing 50 GB workspace to 100 GB on the next install or
repair using this script. Supply the desired setting on every install, repair,
restore, or resize run when using a non-default capacity:

```bash
# Preview first, then back up and close active files before applying:
DEVBOX_SIZE_GB=200 ./manage-devbox.sh --dry-run resize
DEVBOX_SIZE_GB=200 ./manage-devbox.sh resize

# A normal repair also reconciles capacity, along with its other repair work:
DEVBOX_SIZE_GB=200 ./manage-devbox.sh repair
```

Run a copy of the script from outside the mounted Devbox, with your working
directory outside it too. Image growth temporarily detaches the volume and
restores its previous mount location/visibility afterward. A busy image is not
forcibly detached; close applications/files and retry. The existing backup lock
also prevents resizing while a backup is running.

Resizing grows the existing APFS container as well as the sparsebundle. If a
previous attempt enlarged only the image, rerunning finishes filesystem growth
without recreating the image. If capacity is already correct, no growth occurs.
Backups remain unchanged. A requested size below the existing image's capacity
fails explicitly; reducing size requires a separate, planned data migration.

The preview reads image capacity but does not mount the image to inspect APFS.
Actual attachment, partition layout, free-space limits, and busy-volume checks
therefore still occur during apply. Keep a verified backup before changing size.

## Capacity regression tests

From the repository root on a supported Mac, as a non-root user:

```bash
bash scripts/devbox/macos/tests/resize-devbox.sh
```

The dependency-free tests extract the resize helpers, create a private temporary
sparsebundle, grow it to 100 GB, verify a preserved canary file, and test previews,
shrink refusal, backup locking, partial-growth recovery, and repeat-run no-ops.
They never install LaunchAgents or use the live Devbox. Successful runs detach
and remove their test image; failures print any retained test workspace.

## Deployment Notes

Run the script as the signed-in user. Do not run it as `root`; the LaunchAgents,
support files, sparsebundle, and backups are intentionally user-scoped.

Recommended Intune settings:

- Run as signed-in user.
- Hide notifications.
- Run daily.
- Retry up to 3 times.

The default install creates support files below
`~/Library/Application Support/devbox`, mounts the volume at `/Volumes/devbox`,
and stores backups below `~/Documents/devbox/<machine-name>`.

Deploy [manage-devbox.sh](./manage-devbox.sh) from this folder. Install/repair
copies the script to `~/Library/Application Support/devbox/devbox.sh`; the
LaunchAgents use that installed copy, not its repository location. Moving the
source folder does not change installed paths, existing data, or scheduling.

By default, the volume is browsable in Finder. Set `DEVBOX_HIDE_VOLUME=true` to
mount it with `nobrowse`; it remains usable at `/Volumes/devbox` but is hidden
from normal Finder views.

## Rollback

Use safe uninstall when preserving the image and backups:

```bash
./manage-devbox.sh uninstall
```

Use purge only when the local image and backups should be removed:

```bash
./manage-devbox.sh purge
```

`purge` has no preview in the current script. Confirm that the image and backups
can be discarded before running it; never use it to test the repository layout.
