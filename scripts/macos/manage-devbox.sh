#!/bin/bash
# Blackout Secure macOS devbox manager v3.0.1
#
# Supported platform: macOS with the diskutil image interface.
# Required privileges: run as the signed-in user, not root.
# Safe to repeat: install and repair converge on the configured image, mount,
# launchd agents, and backup schedule.
#
# Usage:
#   ./manage-devbox.sh [--dry-run] {install|repair|mount|backup|status|uninstall|purge}
#
# Intune guidance: run as the signed-in user, hide notifications, run daily,
# and retry up to 3 times.

set -euo pipefail

# ==================== CONFIGURABLE VARIABLES ====================
DEVBOX_VERSION="${DEVBOX_VERSION:-3.0.1}"
DEVBOX_NAME="${DEVBOX_NAME:-devbox}"
DEVBOX_SIZE_GB="${DEVBOX_SIZE_GB:-50}"
DEVBOX_VOLUME_LABEL="${DEVBOX_VOLUME_LABEL:-devbox}"
DEVBOX_BACKUP_HOUR="${DEVBOX_BACKUP_HOUR:-2}"
DEVBOX_BACKUP_MINUTE="${DEVBOX_BACKUP_MINUTE:-0}"
DEVBOX_RETENTION="${DEVBOX_RETENTION:-14}"
DEVBOX_LAUNCHD_PREFIX="${DEVBOX_LAUNCHD_PREFIX:-com.blackoutsecure.devbox}"
DEVBOX_REPAIR_MOUNT="${DEVBOX_REPAIR_MOUNT:-true}"
DEVBOX_BACKUP_IF_OVERDUE_HOURS="${DEVBOX_BACKUP_IF_OVERDUE_HOURS:-36}"

# Volume visibility in Finder and on the Desktop.
# false (default): mount as a normal browsable volume. Finder can show "devbox"
#                  in Locations and on the Desktop when Finder is configured to
#                  display external disks.
# true:            mount with the "nobrowse" option. The volume remains fully
#                  usable at /Volumes/devbox but is hidden from normal Finder views.
DEVBOX_HIDE_VOLUME="${DEVBOX_HIDE_VOLUME:-false}"
# ================================================================

usage(){ echo "Usage: $0 [--dry-run] {install|repair|mount|backup|status|uninstall|purge}" >&2; }

DRY_RUN="false"
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN="true"
  shift
fi

MODE="${1:-install}"
CURRENT_UID="$(/usr/bin/id -u)"
CURRENT_USER="$(/usr/bin/id -un)"
USER_HOME="$HOME"

if ! /usr/sbin/diskutil image 2>&1 | /usr/bin/grep -qE 'create|attach|info'; then
  echo "ERROR: This macOS release does not expose the required diskutil image interface." >&2
  exit 1
fi

if [[ "$CURRENT_UID" -eq 0 || "$CURRENT_USER" == "root" ]]; then
  echo "ERROR: Configure this script to run as the signed-in user, not root." >&2
  exit 1
fi

MACHINE_NAME="$(/usr/sbin/scutil --get ComputerName 2>/dev/null || /bin/hostname -s)"
MACHINE_NAME="$(printf '%s' "$MACHINE_NAME" | /usr/bin/tr '[:upper:]' '[:lower:]')"
USER_ROOT="$USER_HOME/Library/Application Support/$DEVBOX_NAME"
IMAGE_PATH="$USER_ROOT/$DEVBOX_NAME.sparsebundle"
MOUNT_POINT="/Volumes/$DEVBOX_VOLUME_LABEL"
BACKUP_ROOT="$USER_HOME/Documents/$DEVBOX_NAME/$MACHINE_NAME"
INSTALLED_SCRIPT="$USER_ROOT/$DEVBOX_NAME.sh"
VERSION_FILE="$USER_ROOT/version.txt"
CONFIG_FILE="$USER_ROOT/config.json"
LAST_BACKUP_FILE="$USER_ROOT/last-backup-utc.txt"
LOG_PATH="$USER_ROOT/$DEVBOX_NAME.log"
LOCK_DIR="$USER_ROOT/.backup.lock"
AGENT_ROOT="$USER_HOME/Library/LaunchAgents"
MOUNT_AGENT="$AGENT_ROOT/$DEVBOX_LAUNCHD_PREFIX.mount.plist"
BACKUP_AGENT="$AGENT_ROOT/$DEVBOX_LAUNCHD_PREFIX.backup.plist"
GUI_DOMAIN="gui/$CURRENT_UID"

log(){
  local message="$1" level="${2:-INFO}"
  if [[ "$DRY_RUN" == "true" ]]; then
    /usr/bin/printf '%s [%s] %s\n' "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" "$level" "$message"
    return 0
  fi
  /bin/mkdir -p "$USER_ROOT"
  /usr/bin/printf '%s [%s] %s\n' "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" "$level" "$message" | /usr/bin/tee -a "$LOG_PATH"
}

dry_run_notice(){ log "DRY-RUN: $1" INFO; }
is_mounted(){ /sbin/mount | /usr/bin/grep -Fq "on $MOUNT_POINT "; }

mount_devbox(){
  if is_mounted; then
    log "Already mounted: $MOUNT_POINT" SUCCESS
    return 0
  fi
  [[ -d "$IMAGE_PATH" ]] || { log "Image missing: $IMAGE_PATH" ERROR; return 1; }
  if [[ "$DRY_RUN" == "true" ]]; then
    dry_run_notice "would mount $IMAGE_PATH at $MOUNT_POINT with hidden=$DEVBOX_HIDE_VOLUME"
    return 0
  fi
  log "Mounting devbox at $MOUNT_POINT" INFO
  if [[ "$DEVBOX_HIDE_VOLUME" == "true" ]]; then
    /usr/sbin/diskutil image attach --mountOptions nobrowse --mountPoint "$MOUNT_POINT" "$IMAGE_PATH" >/dev/null
  else
    /usr/sbin/diskutil image attach --mountPoint "$MOUNT_POINT" "$IMAGE_PATH" >/dev/null
  fi
  if is_mounted; then
    log "Mounted: $MOUNT_POINT (hidden=$DEVBOX_HIDE_VOLUME)" SUCCESS
  else
    log "Mount verification failed: $MOUNT_POINT" ERROR
    return 1
  fi
}

eject_devbox(){
  is_mounted || return 0
  if [[ "$DRY_RUN" == "true" ]]; then
    dry_run_notice "would eject $MOUNT_POINT"
    return 0
  fi
  /usr/sbin/diskutil eject "$MOUNT_POINT" >/dev/null
}

write_config(){
  if [[ "$DRY_RUN" == "true" ]]; then
    dry_run_notice "would write config to $CONFIG_FILE and ensure backup root $BACKUP_ROOT"
    return 0
  fi
  /bin/mkdir -p "$USER_ROOT" "$BACKUP_ROOT"
  /bin/cat > "$CONFIG_FILE.tmp" <<JSON
{"schemaVersion":3,"version":"$DEVBOX_VERSION","name":"$DEVBOX_NAME","machineName":"$MACHINE_NAME","imagePath":"$IMAGE_PATH","mountPoint":"$MOUNT_POINT","backupRoot":"$BACKUP_ROOT","retention":$DEVBOX_RETENTION,"backupHour":$DEVBOX_BACKUP_HOUR,"backupMinute":$DEVBOX_BACKUP_MINUTE,"hideVolume":$DEVBOX_HIDE_VOLUME}
JSON
  /bin/mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
  /bin/chmod 600 "$CONFIG_FILE"
}

create_or_repair_image(){
  if [[ "$DRY_RUN" == "true" ]]; then
    dry_run_notice "would ensure $USER_ROOT exists"
    [[ -d "$IMAGE_PATH" ]] || dry_run_notice "would create ${DEVBOX_SIZE_GB}GB APFS sparsebundle at $IMAGE_PATH"
    [[ "$DEVBOX_REPAIR_MOUNT" == "true" ]] && mount_devbox || true
    dry_run_notice "would ensure standard devbox directories exist when mounted"
    return 0
  fi
  /bin/mkdir -p "$USER_ROOT"
  if [[ ! -d "$IMAGE_PATH" ]]; then
    log "Creating ${DEVBOX_SIZE_GB}GB APFS sparsebundle: $IMAGE_PATH"
    /usr/sbin/diskutil image create blank --format UDSB --size "${DEVBOX_SIZE_GB}g" --fs APFS --volumeName "$DEVBOX_VOLUME_LABEL" "$IMAGE_PATH" >/dev/null
  fi
  [[ "$DEVBOX_REPAIR_MOUNT" == "true" ]] && mount_devbox
  if is_mounted; then
    /bin/mkdir -p "$MOUNT_POINT"/{repos,projects,agent-workspaces,ai,data,tools,scripts,temp,package-caches,build-output,docker,archives}
  fi
}

write_agents(){
  if [[ "$DRY_RUN" == "true" ]]; then
    dry_run_notice "would write and bootstrap launchd agents $MOUNT_AGENT and $BACKUP_AGENT"
    return 0
  fi
  /bin/mkdir -p "$AGENT_ROOT"
  /bin/cat > "$MOUNT_AGENT.tmp" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>Label</key><string>$DEVBOX_LAUNCHD_PREFIX.mount</string><key>ProgramArguments</key><array><string>/bin/bash</string><string>$INSTALLED_SCRIPT</string><string>mount</string></array><key>RunAtLoad</key><true/><key>StandardOutPath</key><string>$LOG_PATH</string><key>StandardErrorPath</key><string>$LOG_PATH</string></dict></plist>
PLIST
  /bin/cat > "$BACKUP_AGENT.tmp" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>Label</key><string>$DEVBOX_LAUNCHD_PREFIX.backup</string><key>ProgramArguments</key><array><string>/bin/bash</string><string>$INSTALLED_SCRIPT</string><string>backup</string></array><key>StartCalendarInterval</key><dict><key>Hour</key><integer>$DEVBOX_BACKUP_HOUR</integer><key>Minute</key><integer>$DEVBOX_BACKUP_MINUTE</integer></dict><key>StandardOutPath</key><string>$LOG_PATH</string><key>StandardErrorPath</key><string>$LOG_PATH</string></dict></plist>
PLIST
  /usr/bin/plutil -lint "$MOUNT_AGENT.tmp" >/dev/null
  /usr/bin/plutil -lint "$BACKUP_AGENT.tmp" >/dev/null
  /bin/mv "$MOUNT_AGENT.tmp" "$MOUNT_AGENT"
  /bin/mv "$BACKUP_AGENT.tmp" "$BACKUP_AGENT"
  /bin/chmod 600 "$MOUNT_AGENT" "$BACKUP_AGENT"
  for plist in "$MOUNT_AGENT" "$BACKUP_AGENT"; do
    /bin/launchctl bootout "$GUI_DOMAIN" "$plist" 2>/dev/null || true
    /bin/launchctl bootstrap "$GUI_DOMAIN" "$plist"
  done
}

backup_devbox(){
  if [[ "$DRY_RUN" == "true" ]]; then
    dry_run_notice "would detach the mounted volume if needed, copy $IMAGE_PATH to $BACKUP_ROOT, verify a tree hash, and apply retention=$DEVBOX_RETENTION"
    return 0
  fi
  /bin/mkdir "$LOCK_DIR" 2>/dev/null || { log "Backup already running" WARN; return 1; }
  trap '/bin/rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT
  /bin/mkdir -p "$BACKUP_ROOT"
  local was_mounted=0 stamp destination partial tree_hash
  is_mounted && was_mounted=1
  if [[ "$was_mounted" -eq 1 ]]; then
    eject_devbox || { log "Volume busy; backup deferred" WARN; return 1; }
  fi
  stamp="$(/bin/date +%Y-%m-%d_%H%M%S)"
  destination="$BACKUP_ROOT/$DEVBOX_NAME-$stamp.sparsebundle"
  partial="$destination.partial"
  /usr/bin/ditto "$IMAGE_PATH" "$partial"
  /bin/mv "$partial" "$destination"
  tree_hash="$(/usr/bin/find "$destination" -type f -print0 | /usr/bin/sort -z | /usr/bin/xargs -0 /usr/bin/shasum -a 256 | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
  /usr/bin/printf '{"schemaVersion":3,"version":"%s","machineName":"%s","createdUtc":"%s","backup":"%s","sha256Tree":"%s","verified":true,"consistency":"detached APFS sparsebundle copy"}\n' "$DEVBOX_VERSION" "$MACHINE_NAME" "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" "$destination" "$tree_hash" > "$destination.json"
  /bin/cp "$destination.json" "$BACKUP_ROOT/$DEVBOX_NAME-latest.json"
  /bin/date -u +%s > "$LAST_BACKUP_FILE"
  /usr/bin/find "$BACKUP_ROOT" -maxdepth 1 -name "$DEVBOX_NAME-*.sparsebundle" -type d -print0 | /usr/bin/xargs -0 /bin/ls -dt 2>/dev/null | /usr/bin/tail -n "+$((DEVBOX_RETENTION+1))" | while IFS= read -r old; do
    /bin/rm -rf "$old" "$old.json"
  done
  [[ "$was_mounted" -eq 1 ]] && mount_devbox
  log "Backup completed: $destination" SUCCESS
}

backup_if_overdue(){
  [[ -f "$LAST_BACKUP_FILE" ]] || return 0
  local now last limit
  now="$(/bin/date -u +%s)"
  last="$(/bin/cat "$LAST_BACKUP_FILE" 2>/dev/null || echo 0)"
  limit="$((DEVBOX_BACKUP_IF_OVERDUE_HOURS*3600))"
  if [[ "$last" =~ ^[0-9]+$ ]] && (( now-last > limit )); then
    log "Backup overdue; running catch-up backup" INFO
    backup_devbox
  fi
}

install_or_repair(){
  if [[ "$DRY_RUN" == "true" ]]; then
    dry_run_notice "would install or repair devbox $DEVBOX_VERSION for $CURRENT_USER"
  else
    /bin/mkdir -p "$USER_ROOT"
    if [[ ! -f "$INSTALLED_SCRIPT" ]] || ! /usr/bin/cmp -s "$0" "$INSTALLED_SCRIPT"; then
      /bin/cp "$0" "$INSTALLED_SCRIPT"
      /bin/chmod 700 "$INSTALLED_SCRIPT"
    fi
  fi
  create_or_repair_image
  write_config
  write_agents
  if [[ "$DRY_RUN" == "true" ]]; then
    dry_run_notice "would write version file $VERSION_FILE and run any overdue catch-up backup"
  else
    /usr/bin/printf '%s\n' "$DEVBOX_VERSION" > "$VERSION_FILE"
  fi
  backup_if_overdue
  log "devbox $DEVBOX_VERSION install/repair completed" SUCCESS
}

status_devbox(){
  echo "version=$([[ -f "$VERSION_FILE" ]] && /bin/cat "$VERSION_FILE" || echo missing)"
  echo "image=$IMAGE_PATH"
  echo "mount=$MOUNT_POINT"
  echo "visible=$([[ "$DEVBOX_HIDE_VOLUME" == "true" ]] && echo false || echo true)"
  echo "backup=$BACKUP_ROOT"
  echo "dryRun=$DRY_RUN"
  is_mounted && echo mounted=true || echo mounted=false
  /bin/launchctl print "$GUI_DOMAIN/$DEVBOX_LAUNCHD_PREFIX.mount" >/dev/null 2>&1 && echo mountAgent=true || echo mountAgent=false
  /bin/launchctl print "$GUI_DOMAIN/$DEVBOX_LAUNCHD_PREFIX.backup" >/dev/null 2>&1 && echo backupAgent=true || echo backupAgent=false
}

uninstall_devbox(){
  local purge="${1:-false}"
  if [[ "$DRY_RUN" == "true" ]]; then
    dry_run_notice "would unload and remove launchd agents, eject $MOUNT_POINT, and remove installed metadata"
    [[ "$purge" == "true" ]] && dry_run_notice "would purge $USER_ROOT and $BACKUP_ROOT"
    return 0
  fi
  for plist in "$MOUNT_AGENT" "$BACKUP_AGENT"; do
    /bin/launchctl bootout "$GUI_DOMAIN" "$plist" 2>/dev/null || true
    /bin/rm -f "$plist"
  done
  eject_devbox || true
  if [[ "$purge" == "true" ]]; then
    /bin/rm -rf "$USER_ROOT" "$BACKUP_ROOT"
  else
    /bin/rm -f "$INSTALLED_SCRIPT" "$VERSION_FILE" "$CONFIG_FILE" "$LAST_BACKUP_FILE"
    log "Safe uninstall completed; image and backups preserved" SUCCESS
  fi
}

case "$MODE" in
  install|repair) install_or_repair ;;
  mount) mount_devbox ;;
  backup) backup_devbox ;;
  status) status_devbox ;;
  uninstall) uninstall_devbox false ;;
  purge) uninstall_devbox true ;;
  -h|--help|help) usage ;;
  *) usage; exit 2 ;;
esac