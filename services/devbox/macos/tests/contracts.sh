#!/bin/bash
# No image, mount, agent, or endpoint installation is used by these tests.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../../.." && pwd -P)"
SCRIPT="$ROOT/services/devbox/macos/manage-devbox.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/bos-devbox-contracts.XXXXXX")"
cleanup(){ rm -rf "$WORK"; }
trap cleanup EXIT
USER_ROOT="$WORK"
DRY_RUN=true
MODE=status
export USER_ROOT DRY_RUN MODE

sed -n '/^calculate_sparsebundle_tree_hash(){/,/^validate_sparsebundle(){/p' "$SCRIPT" | sed '$d' > "$WORK/functions.sh"
if [[ "$(uname -s)" == MINGW* ]]; then
  echo 'ERROR: Run native hashing contracts on Linux or macOS; Git Bash is not a native endpoint test.' >&2
  exit 1
fi
# shellcheck source=/dev/null
source "$WORK/functions.sh"
log(){ printf '%s\n' "$1" >&2; }
mkdir -p "$WORK/original/bands" "$WORK/relocated/bands"
printf 'canary contents\n' > "$WORK/original/bands/0"
printf 'metadata\n' > "$WORK/original/Info.plist"
cp -R "$WORK/original/." "$WORK/relocated/"
first="$(calculate_sparsebundle_tree_hash "$WORK/original")"
second="$(calculate_sparsebundle_tree_hash "$WORK/relocated")"
[[ "$first" == "$second" ]]
legacy="$(calculate_sparsebundle_tree_hash "$WORK/original" absolute-path-v0)"
reference="$(find "$WORK/original" -type f -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256 | awk '{print $1}')"
[[ "$legacy" == "$reference" ]]
printf 'tampered\n' > "$WORK/relocated/bands/0"
[[ "$(calculate_sparsebundle_tree_hash "$WORK/relocated")" != "$first" ]]
printf 'PASS portable tree hashes survive relocation, detect corruption, and preserve the legacy algorithm\n'

sed -n '/^case "\$MODE" in/,$p' "$SCRIPT" > "$WORK/dispatch.sh"
export IMAGE_PATH=invalid-live COMMAND_ARGUMENT=''
MODE=validate
live_called=false
backup_called=false
validate_backup_artifact(){ live_called=true; return 1; }
verify_backup(){ backup_called=true; return 0; }
# shellcheck source=/dev/null
if source "$WORK/dispatch.sh"; then echo 'ERROR: Invalid live image was reported as valid.' >&2; exit 1; fi
[[ "$live_called" == true && "$backup_called" == false ]]
COMMAND_ARGUMENT=selected-backup
# shellcheck source=/dev/null
source "$WORK/dispatch.sh"
[[ "$backup_called" == true ]]
printf 'PASS live validation failures cannot fall through to a passing backup\n'
