#!/bin/bash
# devbox macOS v3.5.0 - Intune-safe installer, repairer, backup, validation, and restore utility
# Default capacity is 100 GB. Install/repair grows existing images and APFS; shrinking is refused.
# Preview capacity changes with --dry-run resize. Run as the signed-in user, never root.
set -euo pipefail

DEVBOX_VERSION="${DEVBOX_VERSION:-3.5.0}"
DEVBOX_NAME="${DEVBOX_NAME:-devbox}"
DEVBOX_SIZE_GB="${DEVBOX_SIZE_GB:-100}"
DEVBOX_VOLUME_LABEL="${DEVBOX_VOLUME_LABEL:-devbox}"
DEVBOX_BACKUP_HOUR="${DEVBOX_BACKUP_HOUR:-2}"
DEVBOX_BACKUP_MINUTE="${DEVBOX_BACKUP_MINUTE:-0}"
DEVBOX_RETENTION="${DEVBOX_RETENTION:-14}"
DEVBOX_BACKUP_IF_OVERDUE_HOURS="${DEVBOX_BACKUP_IF_OVERDUE_HOURS:-36}"
DEVBOX_LAUNCHD_PREFIX="${DEVBOX_LAUNCHD_PREFIX:-com.blackoutsecure.devbox}"
DEVBOX_REPAIR_MOUNT="${DEVBOX_REPAIR_MOUNT:-true}"
DEVBOX_HIDE_VOLUME="${DEVBOX_HIDE_VOLUME:-false}"
DEVBOX_AUTO_RESTORE="${DEVBOX_AUTO_RESTORE:-true}"
DEVBOX_RESTORE_SEARCH_ALL_MACHINES="${DEVBOX_RESTORE_SEARCH_ALL_MACHINES:-true}"
DEVBOX_VERIFY_BACKUP_HASH="${DEVBOX_VERIFY_BACKUP_HASH:-true}"
DEVBOX_ALLOW_BACKUP_WITHOUT_METADATA="${DEVBOX_ALLOW_BACKUP_WITHOUT_METADATA:-true}"
DEVBOX_VALIDATE_BACKUP_MOUNT="${DEVBOX_VALIDATE_BACKUP_MOUNT:-true}"
DEVBOX_VERIFY_POST_BACKUP_HASH="${DEVBOX_VERIFY_POST_BACKUP_HASH:-true}"
DEVBOX_CONDITIONAL_INSTALL_BACKUP="${DEVBOX_CONDITIONAL_INSTALL_BACKUP:-true}"
DEVBOX_BACKUP_AFTER_RESTORE="${DEVBOX_BACKUP_AFTER_RESTORE:-false}"

DRY_RUN=false
if [[ "${1:-}" == --dry-run ]]; then DRY_RUN=true; shift; fi
MODE="${1:-install}"
COMMAND_ARGUMENT="${2:-}"
if [[ "$DRY_RUN" == true && "$MODE" != resize ]]; then
  echo "ERROR: --dry-run is supported only with resize; no operation was performed." >&2
  exit 2
fi
CURRENT_UID="$(/usr/bin/id -u)"
CURRENT_USER="$(/usr/bin/id -un)"
USER_HOME="$HOME"

[[ "$CURRENT_UID" -ne 0 && "$CURRENT_USER" != root ]] || { echo "ERROR: Run as the signed-in user, not root." >&2; exit 1; }

for value in DEVBOX_SIZE_GB DEVBOX_BACKUP_HOUR DEVBOX_BACKUP_MINUTE DEVBOX_RETENTION DEVBOX_BACKUP_IF_OVERDUE_HOURS; do
  actual="${!value}"
  [[ "$actual" =~ ^[0-9]+$ ]] || { echo "ERROR: $value must be an integer." >&2; exit 1; }
done
(( ${#DEVBOX_SIZE_GB} <= 5 && 10#$DEVBOX_SIZE_GB >= 1 && 10#$DEVBOX_SIZE_GB <= 65536 )) || { echo "ERROR: Devbox size must be between 1 and 65536 GB." >&2; exit 1; }
DEVBOX_SIZE_GB=$((10#$DEVBOX_SIZE_GB))
(( DEVBOX_RETENTION >= 1 && DEVBOX_BACKUP_IF_OVERDUE_HOURS >= 1 )) || { echo "ERROR: Retention and overdue hours must be at least 1." >&2; exit 1; }
(( DEVBOX_BACKUP_HOUR <= 23 && DEVBOX_BACKUP_MINUTE <= 59 )) || { echo "ERROR: Invalid backup time." >&2; exit 1; }

MACHINE_NAME="$(/usr/sbin/scutil --get ComputerName 2>/dev/null || /bin/hostname -s)"
MACHINE_NAME="$(/usr/bin/printf '%s' "$MACHINE_NAME" | /usr/bin/tr '[:upper:]' '[:lower:]')"
USER_ROOT="$USER_HOME/Library/Application Support/$DEVBOX_NAME"
IMAGE_PATH="$USER_ROOT/$DEVBOX_NAME.sparsebundle"
MOUNT_POINT="/Volumes/$DEVBOX_VOLUME_LABEL"
BACKUP_BASE="$USER_HOME/Documents/$DEVBOX_NAME"
BACKUP_ROOT="$BACKUP_BASE/$MACHINE_NAME"
INSTALLED_SCRIPT="$USER_ROOT/$DEVBOX_NAME.sh"
VERSION_FILE="$USER_ROOT/version.txt"
CONFIG_FILE="$USER_ROOT/config.plist"
LAST_BACKUP_FILE="$USER_ROOT/last-backup-utc.txt"
LOG_PATH="$USER_ROOT/$DEVBOX_NAME.log"
LOCK_DIR="$USER_ROOT/.backup.lock"
LOCK_PID_FILE="$LOCK_DIR/pid"
AGENT_ROOT="$USER_HOME/Library/LaunchAgents"
MOUNT_AGENT="$AGENT_ROOT/$DEVBOX_LAUNCHD_PREFIX.mount.plist"
BACKUP_AGENT="$AGENT_ROOT/$DEVBOX_LAUNCHD_PREFIX.backup.plist"
GUI_DOMAIN="gui/$CURRENT_UID"
RESTORE_OCCURRED=false
IMAGE_CREATED_THIS_RUN=false

log(){
  if [[ "$DRY_RUN" == true ]]; then /usr/bin/printf 'DRY-RUN [%s] %s\n' "${2:-INFO}" "$1"; return 0; fi
  if [[ "${MODE:-}" == status ]]; then /usr/bin/printf '%s [%s] %s\n' "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" "${2:-INFO}" "$1"; return 0; fi
  /bin/mkdir -p "$USER_ROOT"; /usr/bin/printf '%s [%s] %s\n' "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" "${2:-INFO}" "$1" | /usr/bin/tee -a "$LOG_PATH"
}
is_true(){ [[ "${1:-false}" == true ]]; }
is_mounted(){ /sbin/mount | /usr/bin/grep -Fq "on $MOUNT_POINT "; }

mount_devbox(){
  is_mounted && { log "Already mounted: $MOUNT_POINT" SUCCESS; return 0; }
  [[ -d "$IMAGE_PATH" ]] || { log "Image missing: $IMAGE_PATH" ERROR; return 1; }
  log "Mounting devbox at $MOUNT_POINT" INFO
  if is_true "$DEVBOX_HIDE_VOLUME"; then
    /usr/sbin/diskutil image attach --mountOptions nobrowse --mountPoint "$MOUNT_POINT" "$IMAGE_PATH" >/dev/null
  else
    /usr/sbin/diskutil image attach --mountPoint "$MOUNT_POINT" "$IMAGE_PATH" >/dev/null
  fi
  is_mounted || { log "Mount verification failed: $MOUNT_POINT" ERROR; return 1; }
  log "Mounted: $MOUNT_POINT (hidden=$DEVBOX_HIDE_VOLUME)" SUCCESS
}

eject_devbox(){
  is_mounted || return 0
  log "Ejecting devbox at $MOUNT_POINT" INFO
  /usr/sbin/diskutil eject "$MOUNT_POINT" >/dev/null || { log "Unable to eject: $MOUNT_POINT" ERROR; return 1; }
  log "Ejected: $MOUNT_POINT" SUCCESS
}

create_mount_directories(){
  is_mounted || return 0
  /bin/mkdir -p "$MOUNT_POINT"/{repos,projects,agent-workspaces,ai,data,tools,scripts,temp,package-caches,build-output,docker,archives}
}

plist_create(){ /bin/rm -f "$1"; /usr/bin/plutil -create xml1 "$1"; }
plist_put_string(){ /usr/bin/plutil -insert "$2" -string "$3" "$1"; }
plist_put_integer(){ /usr/bin/plutil -insert "$2" -integer "$3" "$1"; }
plist_put_bool(){ /usr/bin/plutil -insert "$2" -bool "$3" "$1"; }
plist_read(){ /usr/bin/plutil -extract "$2" raw -o - "$1" 2>/dev/null; }

write_config(){
  local tmp="$CONFIG_FILE.tmp"
  /bin/mkdir -p "$USER_ROOT" "$BACKUP_ROOT"; plist_create "$tmp"
  plist_put_integer "$tmp" schemaVersion 3
  plist_put_string "$tmp" version "$DEVBOX_VERSION"
  plist_put_string "$tmp" name "$DEVBOX_NAME"
  plist_put_string "$tmp" machineName "$MACHINE_NAME"
  plist_put_string "$tmp" imagePath "$IMAGE_PATH"
  plist_put_string "$tmp" mountPoint "$MOUNT_POINT"
  plist_put_string "$tmp" backupBase "$BACKUP_BASE"
  plist_put_string "$tmp" backupRoot "$BACKUP_ROOT"
  plist_put_integer "$tmp" retention "$DEVBOX_RETENTION"
  plist_put_integer "$tmp" backupHour "$DEVBOX_BACKUP_HOUR"
  plist_put_integer "$tmp" backupMinute "$DEVBOX_BACKUP_MINUTE"
  plist_put_bool "$tmp" hideVolume "$DEVBOX_HIDE_VOLUME"
  plist_put_bool "$tmp" autoRestore "$DEVBOX_AUTO_RESTORE"
  plist_put_bool "$tmp" conditionalInstallBackup "$DEVBOX_CONDITIONAL_INSTALL_BACKUP"
  plist_put_bool "$tmp" backupAfterRestore "$DEVBOX_BACKUP_AFTER_RESTORE"
  /usr/bin/plutil -lint "$tmp" >/dev/null
  /bin/chmod 600 "$tmp"; /bin/mv "$tmp" "$CONFIG_FILE"
  log "Configuration written: $CONFIG_FILE" SUCCESS
}

acquire_backup_lock(){
  local pid=""
  if /bin/mkdir "$LOCK_DIR" 2>/dev/null; then /usr/bin/printf '%s\n' "$$" > "$LOCK_PID_FILE"; return 0; fi
  [[ -f "$LOCK_PID_FILE" ]] && pid="$(/bin/cat "$LOCK_PID_FILE" 2>/dev/null || true)"
  if [[ "$pid" =~ ^[0-9]+$ ]] && /bin/kill -0 "$pid" 2>/dev/null; then log "Backup already running with process ID $pid" WARN; return 1; fi
  log "Removing stale backup lock" WARN; /bin/rm -rf "$LOCK_DIR"; /bin/mkdir "$LOCK_DIR"; /usr/bin/printf '%s\n' "$$" > "$LOCK_PID_FILE"
}
release_backup_lock(){ /bin/rm -rf "$LOCK_DIR"; }

calculate_sparsebundle_tree_hash(){
  local bundle="$1" hash_file
  [[ -d "$bundle" ]] || return 1
  hash_file="$(/usr/bin/mktemp "$USER_ROOT/.hashes.XXXXXX")"
  if ! /usr/bin/find "$bundle" -type f -print0 | /usr/bin/sort -z | /usr/bin/xargs -0 /usr/bin/shasum -a 256 > "$hash_file" || [[ ! -s "$hash_file" ]]; then /bin/rm -f "$hash_file"; return 1; fi
  /usr/bin/shasum -a 256 "$hash_file" | /usr/bin/awk '{print $1}'
  /bin/rm -f "$hash_file"
}

validate_sparsebundle(){
  [[ -d "$1" ]] || { log "Sparsebundle does not exist: $1" ERROR; return 1; }
  log "Validating sparsebundle structure: $1" INFO
  /usr/sbin/diskutil image info "$1" >/dev/null 2>&1 || { log "Sparsebundle structure validation failed: $1" ERROR; return 1; }
  log "Sparsebundle structure validation passed: $1" SUCCESS
}

validate_backup_mount(){
  local bundle="$1" output device attempt=1
  is_true "$DEVBOX_VALIDATE_BACKUP_MOUNT" || { log "Read-only attach validation is disabled" WARN; return 0; }
  log "Performing read-only attach validation: $bundle" INFO
  output="$(/usr/bin/hdiutil attach -readonly -nomount "$bundle" 2>&1)" || { log "Read-only attach validation failed: $bundle" ERROR; log "$output" ERROR; return 1; }
  device="$(/usr/bin/printf '%s\n' "$output" | /usr/bin/awk '/^\/dev\/disk[0-9]+[[:space:]]/ {print $1; exit}')"
  [[ -n "$device" ]] || device="$(/usr/bin/printf '%s\n' "$output" | /usr/bin/awk '/^\/dev\// {print $1; exit}')"
  [[ -n "$device" ]] || { log "Attach returned no device identifier" ERROR; return 1; }
  while (( attempt <= 3 )); do /usr/bin/hdiutil detach "$device" >/dev/null 2>&1 && { log "Read-only attach validation passed: $bundle" SUCCESS; return 0; }; /bin/sleep 1; attempt=$((attempt+1)); done
  log "Validation device could not be detached: $device" ERROR; return 1
}
validate_backup_artifact(){ validate_sparsebundle "$1" && validate_backup_mount "$1"; }

metadata_path_for(){ /usr/bin/printf '%s.plist\n' "$1"; }
write_backup_metadata(){
  local metadata="$1" destination="$2" hash="$3" tmp="$1.tmp"
  plist_create "$tmp"
  plist_put_integer "$tmp" schemaVersion 4
  plist_put_string "$tmp" version "$DEVBOX_VERSION"
  plist_put_string "$tmp" machineName "$MACHINE_NAME"
  plist_put_string "$tmp" createdUtc "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
  plist_put_string "$tmp" backup "$destination"
  plist_put_string "$tmp" sha256Tree "$hash"
  plist_put_bool "$tmp" verified true
  plist_put_string "$tmp" consistency "detached APFS sparsebundle copy"
  plist_put_bool "$tmp" structureValidated true
  plist_put_bool "$tmp" readOnlyAttachValidated "$DEVBOX_VALIDATE_BACKUP_MOUNT"
  /usr/bin/plutil -lint "$tmp" >/dev/null || { /bin/rm -f "$tmp"; return 1; }
  /bin/chmod 600 "$tmp"; /bin/mv "$tmp" "$metadata"; log "Backup metadata validated: $metadata" SUCCESS
}

verify_backup(){
  local backup="$1" metadata expected actual verified
  metadata="$(metadata_path_for "$backup")"
  validate_backup_artifact "$backup" || return 1
  is_true "$DEVBOX_VERIFY_BACKUP_HASH" || { log "Backup hash verification is disabled" WARN; return 0; }
  if [[ ! -f "$metadata" ]] || ! /usr/bin/plutil -lint "$metadata" >/dev/null 2>&1; then
    is_true "$DEVBOX_ALLOW_BACKUP_WITHOUT_METADATA" && { log "Plist metadata unavailable; hash verification skipped" WARN; return 0; }
    log "Valid backup metadata is required: $metadata" ERROR; return 1
  fi
  verified="$(plist_read "$metadata" verified || /usr/bin/printf false)"
  expected="$(plist_read "$metadata" sha256Tree || true)"
  if [[ "$verified" != true || ! "$expected" =~ ^[[:xdigit:]]{64}$ ]]; then
    is_true "$DEVBOX_ALLOW_BACKUP_WITHOUT_METADATA" && { log "Metadata incomplete; hash verification skipped" WARN; return 0; }
    return 1
  fi
  actual="$(calculate_sparsebundle_tree_hash "$backup")"
  [[ "$actual" == "$expected" ]] || { log "Backup tree-hash verification failed: $backup" ERROR; return 1; }
  log "Backup tree-hash verification passed: $backup" SUCCESS
}

find_latest_backup_in_root(){
  local root="$1" candidate mtime newest="" newest_mtime=0
  [[ -d "$root" ]] || return 1
  while IFS= read -r -d '' candidate; do
    mtime="$(/usr/bin/stat -f '%m' "$candidate" 2>/dev/null || echo 0)"
    [[ "$mtime" =~ ^[0-9]+$ ]] && (( mtime > newest_mtime )) && { newest="$candidate"; newest_mtime="$mtime"; }
  done < <(/usr/bin/find "$root" -type d -name "$DEVBOX_NAME-*.sparsebundle" -print0 2>/dev/null)
  [[ -n "$newest" ]] || return 1; /usr/bin/printf '%s\n' "$newest"
}
find_latest_backup(){ is_true "$DEVBOX_RESTORE_SEARCH_ALL_MACHINES" && find_latest_backup_in_root "$BACKUP_BASE" || find_latest_backup_in_root "$BACKUP_ROOT"; }
find_latest_current_machine_backup(){ find_latest_backup_in_root "$BACKUP_ROOT"; }

restore_devbox(){
  local source="${1:-}" partial="$IMAGE_PATH.restore-partial"
  is_mounted && eject_devbox
  [[ ! -e "$IMAGE_PATH" ]] || { log "Restore refused because live image exists: $IMAGE_PATH" ERROR; return 1; }
  [[ -n "$source" ]] || source="$(find_latest_backup || true)"
  [[ -n "$source" ]] || { log "No backup sparsebundle was found" WARN; return 2; }
  [[ -d "$source" && "$source" == *.sparsebundle ]] || { log "Invalid restore source: $source" ERROR; return 1; }
  /bin/rm -rf "$partial"; verify_backup "$source" || { log "Restore aborted because backup validation failed" ERROR; return 1; }
  log "Restoring devbox from: $source" INFO
  /usr/bin/ditto "$source" "$partial" || { /bin/rm -rf "$partial"; return 1; }
  validate_backup_artifact "$partial" || { /bin/rm -rf "$partial"; return 1; }
  /bin/mv "$partial" "$IMAGE_PATH"; RESTORE_OCCURRED=true; log "Restore completed: $IMAGE_PATH" SUCCESS
}

create_blank_image(){
  log "Creating ${DEVBOX_SIZE_GB}GB APFS sparsebundle: $IMAGE_PATH" INFO
  /usr/sbin/diskutil image create blank --format UDSB --size "${DEVBOX_SIZE_GB}g" --fs APFS --volumeName "$DEVBOX_VOLUME_LABEL" "$IMAGE_PATH" >/dev/null
  validate_sparsebundle "$IMAGE_PATH" || { /bin/rm -rf "$IMAGE_PATH"; return 1; }
  IMAGE_CREATED_THIS_RUN=true
}

devbox_image_size(){
  local size
  [[ -d "$IMAGE_PATH" && ! -L "$IMAGE_PATH" ]] || { log "Expected a local sparsebundle directory: $IMAGE_PATH" ERROR >&2; return 1; }
  size="$(/usr/bin/plutil -extract size raw -o - "$IMAGE_PATH/Info.plist")" \
    || { log "Cannot read virtual image capacity: $IMAGE_PATH" ERROR >&2; return 1; }
  [[ "$size" =~ ^[0-9]+$ && "$size" -gt 0 ]] || { log "Invalid virtual image capacity: $IMAGE_PATH" ERROR >&2; return 1; }
  /usr/bin/printf '%s\n' "$size"
}

devbox_image_attachment(){ #Output: whole-image device and its mount point, or empty when detached.
  local info count index path canonical entities entity device="" mounted="" point
  canonical="$(cd "$IMAGE_PATH" && pwd -P)" || return 1
  info="$(/usr/bin/hdiutil info -plist)" || { log "Could not inspect attached disk images" ERROR >&2; return 1; }
  count="$(/usr/bin/plutil -extract images raw -o - - <<< "$info")" || return 1
  [[ "$count" =~ ^[0-9]+$ ]] || return 1
  for ((index=0; index<count; index++)); do
    path="$(/usr/bin/plutil -extract "images.$index.image-path" raw -o - - <<< "$info")" || return 1
    [[ "$path" == "$IMAGE_PATH" || "$path" == "$canonical" ]] || continue
    device="$(/usr/bin/plutil -extract "images.$index.system-entities.0.dev-entry" raw -o - - <<< "$info")" || return 1
    [[ "$device" =~ ^/dev/disk[0-9]+$ ]] || { log "Image attachment is not a whole virtual disk" ERROR >&2; return 1; }
    entities="$(/usr/bin/plutil -extract "images.$index.system-entities" raw -o - - <<< "$info")" || return 1
    for ((entity=0; entity<entities; entity++)); do
      point="$(/usr/bin/plutil -extract "images.$index.system-entities.$entity.mount-point" raw -o - - <<< "$info" 2>/dev/null)" || point=''
      [[ -n "$point" ]] || continue
      [[ -z "$mounted" && "$point" == "$MOUNT_POINT" ]] \
        || { log "Devbox is attached at an unexpected or additional mount point; eject it before resizing" ERROR >&2; return 1; }
      mounted="$point"
    done
    /usr/bin/printf '%s\t%s\n' "$device" "$mounted"
    return 0
  done
}

devbox_apfs_store(){ #Input: whole device proven to belong to IMAGE_PATH. Output: its last APFS partition.
  local layout count index content store='' candidate
  layout="$(/usr/sbin/diskutil list -plist "$1")" || return 1
  content="$(/usr/bin/plutil -extract AllDisksAndPartitions.0.Content raw -o - - <<< "$layout")" || return 1
  [[ "$content" == GUID_partition_scheme ]] || { log "Devbox requires its existing GPT layout; refusing to repartition" ERROR >&2; return 1; }
  count="$(/usr/bin/plutil -extract AllDisksAndPartitions.0.Partitions raw -o - - <<< "$layout")" || return 1
  for ((index=0; index<count; index++)); do
    content="$(/usr/bin/plutil -extract "AllDisksAndPartitions.0.Partitions.$index.Content" raw -o - - <<< "$layout")" || return 1
    [[ "$content" == Apple_APFS ]] || continue
    [[ -z "$store" && "$index" -eq $((count-1)) ]] \
      || { log "Expected one final APFS partition; refusing to change this image layout" ERROR >&2; return 1; }
    candidate="$(/usr/bin/plutil -extract "AllDisksAndPartitions.0.Partitions.$index.DeviceIdentifier" raw -o - - <<< "$layout")" || return 1
    [[ "$candidate" =~ ^disk[0-9]+s[0-9]+$ && "$candidate" == "${1#/dev/}"s* ]] || return 1
    store="$candidate"
  done
  [[ -n "$store" ]] || { log "No APFS data partition found in the Devbox image" ERROR >&2; return 1; }
  /usr/bin/printf '%s\n' "$store"
}

devbox_apfs_sizes(){ #Output: current and maximum size of a verified image partition.
  local limits current maximum
  limits="$(/usr/sbin/diskutil apfs resizeContainer "$1" limits -plist)" || return 1
  current="$(/usr/bin/plutil -extract CurrentSize raw -o - - <<< "$limits")" || return 1
  maximum="$(/usr/bin/plutil -extract MaximumSize raw -o - - <<< "$limits")" || return 1
  [[ "$current" =~ ^[0-9]+$ && "$maximum" =~ ^[0-9]+$ && "$current" -gt 0 && "$maximum" -gt 0 ]] || return 1
  /usr/bin/printf '%s %s\n' "$current" "$maximum"
}

resize_devbox(){ #Reconcile virtual image and usable APFS capacity without formatting or shrinking.
  (
    desired=$(((DEVBOX_SIZE_GB * 1000000000 + 4095) / 4096 * 4096))
    current="$(devbox_image_size)" || exit 1
    if (( desired < current )); then
      log "Requested ${DEVBOX_SIZE_GB}GB is smaller than the existing $current-byte image. Automatic shrinking is refused; increase the setting or migrate data to a new image." ERROR
      exit 1
    fi
    if [[ "$DRY_RUN" == true ]]; then
      log "Current image: $current bytes; requested: $desired bytes" INFO
      (( current == desired )) || log "Would temporarily detach this image and grow it to ${DEVBOX_SIZE_GB}GB" INFO
      log "Would inspect its APFS partition, grow into available image space if needed, and restore the original mount state" INFO
      exit 0
    fi
    acquire_backup_lock || exit 1
    probe_device='' attachment_pending=false original_attached=false original_mounted=false restore_attachment=false
    trap '
      result=$?
      trap - EXIT
      if [[ "$attachment_pending" == true && -z "$probe_device" ]]; then
        if attachment="$(devbox_image_attachment)"; then
          read -r probe_device _ <<< "$attachment"
        else
          log "Could not identify the resize inspection attachment for $IMAGE_PATH; inspect and eject that image before retrying" ERROR
          result=1
          restore_attachment=false
        fi
      fi
      if [[ -n "$probe_device" ]]; then
        if ! /usr/sbin/diskutil eject "$probe_device" >/dev/null; then
          log "Could not detach resize inspection device $probe_device; original mount state was not restored" ERROR
          result=1
          restore_attachment=false
        fi
      fi
      if [[ "$restore_attachment" == true ]]; then
        if [[ "$original_mounted" == true ]]; then
          if ! mount_devbox; then log "Resize finished or failed, but Devbox could not be remounted; run mount after resolving the error" ERROR; result=1; fi
        elif [[ "$original_attached" == true ]]; then
          if ! /usr/sbin/diskutil image attach --noMount "$IMAGE_PATH" >/dev/null; then log "Could not restore the original image attachment" ERROR; result=1; fi
        fi
      fi
      if ! release_backup_lock; then log "Could not release the Devbox capacity lock" ERROR; result=1; fi
      exit "$result"
    ' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    current="$(devbox_image_size)" || exit 1
    (( desired >= current )) || { log "Image capacity changed while waiting; refusing to shrink it" ERROR; exit 1; }
    attachment="$(devbox_image_attachment)" || { log "Could not establish the Devbox image attachment" ERROR; exit 1; }
    device='' mounted=''
    IFS=$'\t' read -r device mounted <<< "$attachment"
    [[ -z "$device" ]] || original_attached=true
    [[ -z "$mounted" ]] || original_mounted=true
    attach_for_resize(){
      local details identifier
      attachment_pending=true
      details="$(/usr/sbin/diskutil image attach --noMount --plist "$IMAGE_PATH")" || return 1
      identifier="$(/usr/bin/plutil -extract system-entities.0.dev-entry raw -o - - <<< "$details")" || return 1
      identifier="${identifier#/dev/}"
      [[ "$identifier" =~ ^disk[0-9]+$ ]] || return 1
      device="/dev/$identifier"
      probe_device="$device"
      attachment_pending=false
    }
    [[ -n "$device" ]] || attach_for_resize || { log "Could not attach the image for capacity inspection" ERROR; exit 1; }
    store="$(devbox_apfs_store "$device")" || { log "Could not validate the APFS resize target" ERROR; exit 1; }
    sizes="$(devbox_apfs_sizes "$store")" || { log "Could not read supported APFS sizes" ERROR; exit 1; }
    read -r fs_current fs_maximum <<< "$sizes"
    if (( current == desired && fs_current >= fs_maximum )); then
      log "Devbox capacity is already ${DEVBOX_SIZE_GB}GB; APFS uses the available image space" SUCCESS
      exit 0
    fi
    #Detach even for filesystem-only recovery: APFS resize may remount at a different path.
    /usr/sbin/diskutil eject "$device" >/dev/null \
      || { log "Devbox is busy. Close files, run the script from outside Devbox, and retry; no capacity change was made" ERROR; exit 1; }
    probe_device=''
    restore_attachment=true
    if (( current < desired )); then
      log "Growing image from $current to $desired bytes (${DEVBOX_SIZE_GB}GB)" INFO
      /usr/sbin/diskutil image resize --size "$desired" "$IMAGE_PATH" \
        || { log "Image growth failed; the existing image was not replaced. Resolve the error and rerun repair" ERROR; exit 1; }
    fi
    [[ "$(devbox_image_size)" == "$desired" ]] || { log "Image growth did not reach the requested capacity" ERROR; exit 1; }
    attach_for_resize || { log "Could not inspect APFS after image growth; rerun repair" ERROR; exit 1; }
    store="$(devbox_apfs_store "$device")" || { log "Could not validate APFS after image growth; rerun repair" ERROR; exit 1; }
    sizes="$(devbox_apfs_sizes "$store")" || { log "Could not inspect APFS capacity after image growth; rerun repair" ERROR; exit 1; }
    read -r fs_current fs_maximum <<< "$sizes"
    if (( fs_current < fs_maximum )); then
      log "Growing the existing APFS container to fill its image" INFO
      /usr/sbin/diskutil apfs resizeContainer "$store" 0 \
        || { log "The image is enlarged but APFS growth failed; data was not reformatted. Rerun repair" ERROR; exit 1; }
      sizes="$(devbox_apfs_sizes "$store")" || { log "Could not verify APFS growth; rerun repair" ERROR; exit 1; }
      read -r fs_current fs_maximum <<< "$sizes"
      (( fs_current >= fs_maximum )) || { log "APFS did not grow to the available capacity; rerun repair" ERROR; exit 1; }
    fi
    log "Devbox image and APFS capacity reconciled to ${DEVBOX_SIZE_GB}GB" SUCCESS
  )
}

create_or_repair_image(){
  local result=2
  /bin/mkdir -p "$USER_ROOT"
  if [[ -d "$IMAGE_PATH" ]]; then log "Existing live sparsebundle found" SUCCESS
  else
    if is_true "$DEVBOX_AUTO_RESTORE"; then
      log "Live image is missing; searching for a backup" INFO
      set +e; restore_devbox; result=$?; set -e
      case "$result" in 0) ;; 2) log "No backup found; creating a new sparsebundle" WARN ;; *) log "Restore failed; refusing blank replacement" ERROR; return 1 ;; esac
    fi
    [[ -d "$IMAGE_PATH" ]] || create_blank_image
  fi
  resize_devbox || return 1
  is_true "$DEVBOX_REPAIR_MOUNT" && mount_devbox
  create_mount_directories
}

write_agents(){
  /bin/mkdir -p "$AGENT_ROOT"
  /bin/cat > "$MOUNT_AGENT.tmp" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>Label</key><string>$DEVBOX_LAUNCHD_PREFIX.mount</string><key>ProgramArguments</key><array><string>/bin/bash</string><string>$INSTALLED_SCRIPT</string><string>mount</string></array><key>RunAtLoad</key><true/><key>StandardOutPath</key><string>$LOG_PATH</string><key>StandardErrorPath</key><string>$LOG_PATH</string></dict></plist>
PLIST
  /bin/cat > "$BACKUP_AGENT.tmp" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>Label</key><string>$DEVBOX_LAUNCHD_PREFIX.backup</string><key>ProgramArguments</key><array><string>/bin/bash</string><string>$INSTALLED_SCRIPT</string><string>backup</string></array><key>StartCalendarInterval</key><dict><key>Hour</key><integer>$DEVBOX_BACKUP_HOUR</integer><key>Minute</key><integer>$DEVBOX_BACKUP_MINUTE</integer></dict><key>StandardOutPath</key><string>$LOG_PATH</string><key>StandardErrorPath</key><string>$LOG_PATH</string></dict></plist>
PLIST
  /usr/bin/plutil -lint "$MOUNT_AGENT.tmp" >/dev/null; /usr/bin/plutil -lint "$BACKUP_AGENT.tmp" >/dev/null
  /bin/mv "$MOUNT_AGENT.tmp" "$MOUNT_AGENT"; /bin/mv "$BACKUP_AGENT.tmp" "$BACKUP_AGENT"; /bin/chmod 600 "$MOUNT_AGENT" "$BACKUP_AGENT"
  for plist in "$MOUNT_AGENT" "$BACKUP_AGENT"; do /bin/launchctl bootout "$GUI_DOMAIN" "$plist" 2>/dev/null || true; /bin/launchctl bootstrap "$GUI_DOMAIN" "$plist"; done
}

apply_backup_retention(){
  local n=0 old
  while IFS= read -r old; do n=$((n+1)); if (( n > DEVBOX_RETENTION )); then log "Removing expired backup: $old" INFO; /bin/rm -rf "$old"; /bin/rm -f "$(metadata_path_for "$old")"; fi; done < <(/usr/bin/find "$BACKUP_ROOT" -maxdepth 1 -type d -name "$DEVBOX_NAME-*.sparsebundle" -print0 2>/dev/null | /usr/bin/xargs -0 /bin/ls -dt 2>/dev/null || true)
}

backup_devbox(){
  local was_mounted=false remount=false completed=false destination="" partial="" metadata="" hash stamp
  acquire_backup_lock || return 1
  cleanup(){ local status=$?; [[ "${completed:-false}" == true ]] || { [[ -n "${partial:-}" && -e "${partial:-}" ]] && /bin/rm -rf "$partial"; }; [[ "${remount:-false}" == true ]] && ! is_mounted && mount_devbox || true; release_backup_lock; trap - EXIT INT TERM HUP; return "$status"; }
  trap cleanup EXIT INT TERM HUP
  [[ -d "$IMAGE_PATH" ]] || { log "Cannot back up because live sparsebundle is missing" ERROR; return 1; }
  /bin/mkdir -p "$BACKUP_ROOT"
  if is_mounted; then was_mounted=true; remount=true; eject_devbox || return 1; fi
  stamp="$(/bin/date +%Y-%m-%d_%H%M%S)"; destination="$BACKUP_ROOT/$DEVBOX_NAME-$stamp.sparsebundle"; partial="$destination.partial"; metadata="$(metadata_path_for "$destination")"
  /bin/rm -rf "$partial"; log "Creating detached sparsebundle backup: $destination" INFO
  /usr/bin/ditto "$IMAGE_PATH" "$partial" || return 1
  validate_backup_artifact "$partial" || return 1
  /bin/mv "$partial" "$destination"; partial=""
  validate_backup_artifact "$destination" || { /bin/rm -rf "$destination"; return 1; }
  hash="$(calculate_sparsebundle_tree_hash "$destination")"; [[ "$hash" =~ ^[[:xdigit:]]{64}$ ]] || { /bin/rm -rf "$destination"; return 1; }
  write_backup_metadata "$metadata" "$destination" "$hash" || { /bin/rm -rf "$destination" "$metadata"; return 1; }
  if is_true "$DEVBOX_VERIFY_POST_BACKUP_HASH"; then verify_backup "$destination" || { /bin/rm -rf "$destination" "$metadata"; return 1; }; fi
  /bin/cp "$metadata" "$BACKUP_ROOT/$DEVBOX_NAME-latest.plist"; /bin/chmod 600 "$BACKUP_ROOT/$DEVBOX_NAME-latest.plist"
  /bin/date -u +%s > "$LAST_BACKUP_FILE"; /bin/chmod 600 "$LAST_BACKUP_FILE"; apply_backup_retention
  if [[ "$was_mounted" == true ]]; then mount_devbox; remount=false; fi
  completed=true; log "Backup completed and validated: $destination" SUCCESS
}

conditional_install_backup(){
  local latest last now threshold reason=""
  is_true "$DEVBOX_CONDITIONAL_INSTALL_BACKUP" || return 0
  if [[ "$IMAGE_CREATED_THIS_RUN" == true ]]; then log "Skipping conditional backup because this run created a new empty sparsebundle" INFO; return 0; fi
  if [[ "$RESTORE_OCCURRED" == true ]] && ! is_true "$DEVBOX_BACKUP_AFTER_RESTORE"; then log "Skipping immediate backup after restore" INFO; return 0; fi
  is_mounted || { log "Conditional backup skipped because devbox is not mounted" WARN; return 0; }
  latest="$(find_latest_current_machine_backup || true)"
  if [[ -z "$latest" ]]; then reason="no backup exists for the current machine"
  elif [[ ! -f "$LAST_BACKUP_FILE" ]]; then reason="no successful backup timestamp exists"
  else
    last="$(/bin/cat "$LAST_BACKUP_FILE" 2>/dev/null || echo 0)"; now="$(/bin/date -u +%s)"; threshold=$((DEVBOX_BACKUP_IF_OVERDUE_HOURS*3600))
    [[ "$last" =~ ^[0-9]+$ ]] || reason="the backup timestamp is invalid"
    [[ -n "$reason" ]] || { (( last > now )) && reason="the backup timestamp is in the future"; }
    [[ -n "$reason" ]] || { (( now-last > threshold )) && reason="the last successful backup is overdue"; }
  fi
  [[ -n "$reason" ]] || { log "Current backup exists; conditional backup skipped" INFO; return 0; }
  log "Conditional backup triggered because $reason" INFO; backup_devbox
}

install_or_repair(){
  /bin/mkdir -p "$USER_ROOT"
  [[ -f "$INSTALLED_SCRIPT" ]] && /usr/bin/cmp -s "$0" "$INSTALLED_SCRIPT" || { /bin/cp "$0" "$INSTALLED_SCRIPT"; /bin/chmod 700 "$INSTALLED_SCRIPT"; }
  create_or_repair_image; write_config; write_agents; /usr/bin/printf '%s\n' "$DEVBOX_VERSION" > "$VERSION_FILE"; /bin/chmod 600 "$VERSION_FILE"; conditional_install_backup; log "devbox $DEVBOX_VERSION install/repair completed" SUCCESS
}

status_devbox(){
  local image_size
  echo "version=$([[ -f "$VERSION_FILE" ]] && /bin/cat "$VERSION_FILE" || echo missing)"; echo "image=$IMAGE_PATH"; echo "mount=$MOUNT_POINT"; echo "config=$CONFIG_FILE"; echo "backupRoot=$BACKUP_ROOT"; is_mounted && echo mounted=true || echo mounted=false; echo "latestBackup=$(find_latest_backup || echo none)"
  echo "desiredSizeGB=$DEVBOX_SIZE_GB"
  if [[ -d "$IMAGE_PATH" ]]; then
    image_size="$(devbox_image_size)" || return 1
    /usr/bin/printf 'imageSizeBytes=%s\n' "$image_size"
  fi
}

uninstall_devbox(){
  local purge="${1:-false}"
  for plist in "$MOUNT_AGENT" "$BACKUP_AGENT"; do /bin/launchctl bootout "$GUI_DOMAIN" "$plist" 2>/dev/null || true; /bin/rm -f "$plist"; done
  eject_devbox || true
  if [[ "$purge" == true ]]; then /bin/rm -rf "$USER_ROOT" "$BACKUP_ROOT"; else /bin/rm -f "$INSTALLED_SCRIPT" "$VERSION_FILE" "$CONFIG_FILE" "$LAST_BACKUP_FILE"; log "Safe uninstall completed; image and backups preserved" SUCCESS; fi
}

case "$MODE" in
  install|repair) install_or_repair ;;
  mount) mount_devbox; create_mount_directories ;;
  backup) backup_devbox ;;
  resize) resize_devbox ;;
  restore) restore_devbox "$COMMAND_ARGUMENT"; resize_devbox; mount_devbox; create_mount_directories ;;
  validate) [[ "${COMMAND_ARGUMENT:-live}" == live ]] && validate_backup_artifact "$IMAGE_PATH" || verify_backup "${COMMAND_ARGUMENT:-$(find_latest_backup)}" ;;
  status) status_devbox ;;
  uninstall) uninstall_devbox false ;;
  purge) uninstall_devbox true ;;
  *) echo "Usage: $0 {install|repair|mount|backup|resize|restore [path]|validate [live|path]|status|uninstall|purge}; preview capacity with --dry-run resize" >&2; exit 2 ;;
esac
