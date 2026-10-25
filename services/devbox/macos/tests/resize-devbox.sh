#!/bin/bash
#Native tests use only a new sparsebundle in a private temporary directory.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd -P)"
SCRIPT="$REPOSITORY_ROOT/output/devbox/macos/manage-devbox.sh"
[[ -f "$SCRIPT" ]] || { echo 'ERROR: Run npm run build before the regression suite.' >&2; exit 1; }
WORK="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/devbox-capacity-test.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
USER_ROOT="$WORK/Library/Application Support/devbox-test"
IMAGE_PATH="$USER_ROOT/devbox-test.sparsebundle"
MOUNT_POINT="$WORK/mount"
LOG_PATH="$WORK/operations.log"
LOCK_DIR="$USER_ROOT/.backup.lock"
LOCK_PID_FILE="$LOCK_DIR/pid"
export DEVBOX_HIDE_VOLUME=true DEVBOX_SIZE_GB=1 DRY_RUN=false
mkdir -p "$USER_ROOT" "$MOUNT_POINT"

{
  sed -n '/^log(){/,/^create_mount_directories(){/p' "$SCRIPT" | sed '$d'
  sed -n '/^acquire_backup_lock(){/,/^calculate_sparsebundle_tree_hash(){/p' "$SCRIPT" | sed '$d'
  sed -n '/^devbox_image_size(){/,/^create_or_repair_image(){/p' "$SCRIPT" | sed '$d'
} > "$WORK/functions.sh"
#shellcheck source=/dev/null
source "$WORK/functions.sh"

cleanup_test(){
  local result=$? attachment='' device=''
  trap - EXIT
  if [[ -d "$IMAGE_PATH" ]]; then
    attachment="$(devbox_image_attachment)" || { echo "Test workspace retained for inspection: $WORK" >&2; exit 1; }
    IFS=$'\t' read -r device _ <<< "$attachment"
    if [[ -n "$device" ]] && ! /usr/sbin/diskutil eject "$device" >/dev/null; then
      echo "Could not detach test image; workspace retained: $WORK" >&2
      exit 1
    fi
  fi
  if [[ "$result" == 0 ]]; then
    /bin/rm -rf "$WORK"
  else
    echo "Failed test evidence retained: $WORK" >&2
  fi
  exit "$result"
}
trap cleanup_test EXIT

/usr/bin/plutil -extract macos.sizeGB raw -expect integer -o - "$REPOSITORY_ROOT/services/devbox/config/defaults.json" | grep -qx 100
/usr/sbin/diskutil image create blank --format UDSB --size 1g --fs APFS \
  --volumeName "DevboxResizeTest-$$" "$IMAGE_PATH" >/dev/null
initial="$(devbox_image_size)"

HOME="$WORK" DEVBOX_NAME=devbox-test /usr/bin/env -u DEVBOX_SIZE_GB \
  /bin/bash "$SCRIPT" --dry-run resize > "$WORK/default-preview.log"
grep -qF 'requested: 100000002048 bytes' "$WORK/default-preview.log"
HOME="$WORK" DEVBOX_NAME=devbox-test DEVBOX_SIZE_GB=08 \
  /bin/bash "$SCRIPT" --dry-run resize > "$WORK/leading-zero.log"
grep -qF 'requested: 8000000000 bytes' "$WORK/leading-zero.log"
for invalid in 0 65537 9999999999999999999 1.5; do
  if HOME="$WORK" DEVBOX_NAME=devbox-test DEVBOX_SIZE_GB="$invalid" \
    /bin/bash "$SCRIPT" --dry-run resize > "$WORK/invalid.log" 2>&1; then
    echo "Invalid size accepted: $invalid" >&2
    exit 1
  fi
  grep -qF 'ERROR:' "$WORK/invalid.log"
done
if HOME="$WORK" /bin/bash "$SCRIPT" --dry-run repair > "$WORK/unsupported-preview.log" 2>&1; then
  echo 'An unsupported preview mode was accepted.' >&2
  exit 1
fi
grep -qF 'no operation was performed' "$WORK/unsupported-preview.log"

bad_home="$WORK/invalid-home"
mkdir -p "$bad_home/Library/Application Support/devbox-test/devbox-test.sparsebundle"
printf 'invalid metadata\n' > "$bad_home/Library/Application Support/devbox-test/devbox-test.sparsebundle/Info.plist"
if HOME="$bad_home" DEVBOX_NAME=devbox-test DEVBOX_VOLUME_LABEL="DevboxResizeTest-$$" \
  /bin/bash "$SCRIPT" status > "$WORK/invalid-status.log" 2>&1; then
  echo 'Status accepted invalid capacity metadata.' >&2
  exit 1
fi
[[ ! -e "$bad_home/Library/Application Support/devbox-test/devbox-test.log" ]]

DEVBOX_SIZE_GB=2 DRY_RUN=true resize_devbox > "$WORK/preview.log"
[[ "$(devbox_image_size)" == "$initial" ]]
[[ ! -e "$LOCK_DIR" && ! -e "$LOG_PATH" ]]
[[ ! -e "$USER_ROOT/devbox-test.log" && ! -e "$WORK/Library/LaunchAgents" ]]
grep -qF 'Would temporarily detach' "$WORK/preview.log"
printf 'PASS resize preview writes no image, lock, or operation log\n'

mount_devbox >/dev/null
printf 'Retain this data through capacity growth.\n' > "$MOUNT_POINT/canary.txt"
expected="$(/usr/bin/shasum -a 256 "$MOUNT_POINT/canary.txt" | awk '{print $1}')"
DEVBOX_SIZE_GB=2
resize_devbox > "$WORK/growth.log"
[[ "$(devbox_image_size)" == 2000003072 ]]
is_mounted
[[ "$(/usr/bin/shasum -a 256 "$MOUNT_POINT/canary.txt" | awk '{print $1}')" == "$expected" ]]
[[ ! -e "$LOCK_DIR" ]]
printf 'PASS mounted image and filesystem grow while preserving data and mount location\n'

resize_devbox > "$WORK/repeat.log"
grep -qF 'capacity is already 2GB' "$WORK/repeat.log"
if grep -q 'Growing' "$WORK/repeat.log"; then echo 'Repeated resize changed capacity.' >&2; exit 1; fi
is_mounted
printf 'PASS repeated capacity reconciliation is a no-op\n'

if DEVBOX_SIZE_GB=1 resize_devbox > "$WORK/shrink.log" 2>&1; then
  echo 'Shrinking was not refused.' >&2
  exit 1
fi
grep -qF 'Automatic shrinking is refused' "$WORK/shrink.log"
[[ "$(devbox_image_size)" == 2000003072 ]]
is_mounted
printf 'PASS shrink requests fail without changing data or mount state\n'

mkdir "$LOCK_DIR"
printf '%s\n' "$$" > "$LOCK_PID_FILE"
if DEVBOX_SIZE_GB=3 resize_devbox > "$WORK/locked.log" 2>&1; then
  echo 'An active backup lock was ignored.' >&2
  exit 1
fi
[[ "$(devbox_image_size)" == 2000003072 ]]
rm "$LOCK_PID_FILE"
rmdir "$LOCK_DIR"
printf 'PASS active backups block capacity changes\n'

eject_devbox >/dev/null
/usr/sbin/diskutil image resize --image-only --size 3g "$IMAGE_PATH" >/dev/null
DEVBOX_SIZE_GB=3
resize_devbox > "$WORK/recovery.log"
[[ "$(devbox_image_size)" == 3000000512 ]]
[[ -z "$(devbox_image_attachment)" ]]
grep -qF 'Growing the existing APFS container' "$WORK/recovery.log"
mount_devbox >/dev/null
[[ "$(/usr/bin/shasum -a 256 "$MOUNT_POINT/canary.txt" | awk '{print $1}')" == "$expected" ]]
resize_devbox > "$WORK/recovery-repeat.log"
grep -qF 'capacity is already 3GB' "$WORK/recovery-repeat.log"
printf 'PASS filesystem-only recovery completes and is idempotent\n'

DEVBOX_SIZE_GB=100
resize_devbox > "$WORK/default-growth.log"
[[ "$(devbox_image_size)" == 100000002048 ]]
is_mounted
[[ "$(/usr/bin/shasum -a 256 "$MOUNT_POINT/canary.txt" | awk '{print $1}')" == "$expected" ]]
resize_devbox > "$WORK/default-repeat.log"
grep -qF 'capacity is already 100GB' "$WORK/default-repeat.log"
printf 'PASS actual 100 GB image and APFS growth preserve data and converge on rerun\n'

eject_devbox >/dev/null
/usr/sbin/diskutil image attach --noMount "$IMAGE_PATH" >/dev/null
DEVBOX_SIZE_GB=101
resize_devbox > "$WORK/attached-growth.log"
[[ "$(devbox_image_size)" == 101000003584 ]]
attachment="$(devbox_image_attachment)"
IFS=$'\t' read -r device mounted <<< "$attachment"
[[ -n "$device" && -z "$mounted" ]]
resize_devbox > "$WORK/attached-repeat.log"
[[ "$(devbox_image_attachment)" == "$attachment" ]]
/usr/sbin/diskutil eject "$device" >/dev/null
mount_devbox >/dev/null
[[ "$(/usr/bin/shasum -a 256 "$MOUNT_POINT/canary.txt" | awk '{print $1}')" == "$expected" ]]
eject_devbox >/dev/null
printf 'PASS attached-but-unmounted images retain their original state across growth and reruns\n'

devbox_apfs_store(){ echo 'Simulated APFS layout query failure.' >&2; return 1; }
if resize_devbox > "$WORK/inspection-failure.log" 2>&1; then
  echo 'Failed APFS inspection was ignored.' >&2
  exit 1
fi
grep -qF 'Could not validate the APFS resize target' "$WORK/inspection-failure.log"
[[ -z "$(devbox_image_attachment)" && ! -e "$LOCK_DIR" ]]
#shellcheck source=/dev/null
source "$WORK/functions.sh"
printf 'PASS failed inspection releases its temporary attachment and backup lock\n'
