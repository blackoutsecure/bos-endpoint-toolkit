# macOS Scripts

POSIX-compatible shell scripts for macOS endpoint administration.

## Scripts

### `manage-devbox.sh`

Creates and maintains a user-scoped APFS sparsebundle dev workspace mounted at
`/Volumes/devbox`. The script is designed for Intune-adjacent deployment and
general macOS endpoint repair workflows.

Supported modes:

- `install` or `repair`: create or repair the sparsebundle, mount it, create
  standard workspace directories, write config, and install per-user launchd
  agents.
- `mount`: mount the sparsebundle at `/Volumes/devbox`.
- `backup`: eject the volume if needed, copy the detached sparsebundle to the
  user's Documents folder, write verification metadata, and apply retention.
- `status`: print current version, paths, mount state, visibility, and launchd
  agent state.
- `uninstall`: remove launchd agents and installed metadata while preserving the
  image and backups.
- `purge`: remove launchd agents, installed metadata, the image, and backups.

Use `--dry-run` before the mode to preview state-changing work:

```sh
./manage-devbox.sh --dry-run install
./manage-devbox.sh status
```

## Configuration

Set environment variables before running the script to override defaults:

| Variable                         | Default                     | Purpose                                   |
| -------------------------------- | --------------------------- | ----------------------------------------- |
| `DEVBOX_VERSION`                 | `3.0.1`                     | Version written to installed metadata.    |
| `DEVBOX_NAME`                    | `devbox`                    | Name used for support files and backups.  |
| `DEVBOX_SIZE_GB`                 | `50`                        | Sparsebundle size in GB.                  |
| `DEVBOX_VOLUME_LABEL`            | `devbox`                    | Volume label and `/Volumes` mount suffix. |
| `DEVBOX_BACKUP_HOUR`             | `2`                         | Daily backup launchd hour.                |
| `DEVBOX_BACKUP_MINUTE`           | `0`                         | Daily backup launchd minute.              |
| `DEVBOX_RETENTION`               | `14`                        | Number of sparsebundle backups to keep.   |
| `DEVBOX_LAUNCHD_PREFIX`          | `com.blackoutsecure.devbox` | LaunchAgent label prefix.                 |
| `DEVBOX_REPAIR_MOUNT`            | `true`                      | Mount during install or repair.           |
| `DEVBOX_BACKUP_IF_OVERDUE_HOURS` | `36`                        | Catch-up backup threshold.                |
| `DEVBOX_HIDE_VOLUME`             | `false`                     | Use `true` to mount with `nobrowse`.      |

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

By default, the volume is browsable in Finder. Set `DEVBOX_HIDE_VOLUME=true` to
mount it with `nobrowse`; it remains usable at `/Volumes/devbox` but is hidden
from normal Finder views.

## Rollback

Use safe uninstall when preserving the image and backups:

```sh
./manage-devbox.sh uninstall
```

Use purge only when the local image and backups should be removed:

```sh
./manage-devbox.sh --dry-run purge
./manage-devbox.sh purge
```
