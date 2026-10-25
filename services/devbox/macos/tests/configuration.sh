#!/bin/bash
# Private HOME and fixtures only; no image, mount, agent, or installation operations.
set -euo pipefail
[[ "$(uname -s)" == Darwin ]] || { echo 'ERROR: These configuration tests require native macOS plutil.' >&2; exit 1; }
ROOT="$(cd "$(dirname "$0")/../../../.." && pwd -P)"
SCRIPT="$ROOT/output/devbox/macos/manage-devbox.sh"
[[ -f "$SCRIPT" ]] || { echo 'ERROR: Run npm run build first.' >&2; exit 1; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/bos-devbox-config.XXXXXX")"
cleanup(){ rm -rf "$WORK"; }
trap cleanup EXIT
trap 'printf "ERROR: macOS configuration contract failed at line %s\n" "$LINENO" >&2' ERR
export HOME="$WORK/home"
mkdir -p "$HOME"
for key in $(env | sed -n 's/^\(DEVBOX_[A-Z_]*\)=.*/\1/p'); do unset "$key"; done

bash "$SCRIPT" config > "$WORK/default.json"
[[ "$(/usr/bin/plutil -extract macos.sizeGB raw -o - "$WORK/default.json")" == 100 ]]
[[ "$(/usr/bin/plutil -extract windows.sizeGiB raw -o - "$WORK/default.json")" == 100 ]]
cat > "$WORK/profile.json" <<'JSON'
{
  "schemaVersion": 1.0,
  "retention": 21.0,
  "workspaceDirectories": ["native-fixture"],
  "windows": {"sizeGiB": 150.0},
  "macos": {"sizeGB": 200.0, "hideVolume": true, "volumeLabel": "Workspace Tools"}
}
JSON
bash "$SCRIPT" --config "$WORK/profile.json" config > "$WORK/resolved.json"
[[ "$(/usr/bin/plutil -extract retention raw -o - "$WORK/resolved.json")" == 21 ]]
[[ "$(/usr/bin/plutil -extract macos.hideVolume raw -o - "$WORK/resolved.json")" == true ]]
[[ "$(/usr/bin/plutil -extract macos.sizeGB raw -o - "$WORK/resolved.json")" == 200 ]]
[[ "$(/usr/bin/plutil -extract macos.volumeLabel raw -o - "$WORK/resolved.json")" == 'Workspace Tools' ]]
[[ "$(/usr/bin/plutil -extract windows.sizeGiB raw -o - "$WORK/resolved.json")" == 150 ]]
[[ "$(/usr/bin/plutil -extract workspaceDirectories.0 raw -o - "$WORK/resolved.json")" == native-fixture ]]
mkdir -p "$HOME/Library/Application Support/devbox"
cp "$WORK/resolved.json" "$HOME/Library/Application Support/devbox/desired-config.json"
bash "$SCRIPT" config > "$WORK/reloaded.json"
/usr/bin/plutil -convert json -r -o "$WORK/resolved.sorted.json" "$WORK/resolved.json"
/usr/bin/plutil -convert json -r -o "$WORK/reloaded.sorted.json" "$WORK/reloaded.json"
cmp "$WORK/resolved.sorted.json" "$WORK/reloaded.sorted.json"
DEVBOX_SIZE_GB=08 DEVBOX_RETENTION=7 bash "$SCRIPT" config > "$WORK/environment.json"
[[ "$(/usr/bin/plutil -extract macos.sizeGB raw -o - "$WORK/environment.json")" == 8 ]]
[[ "$(/usr/bin/plutil -extract retention raw -o - "$WORK/environment.json")" == 7 ]]
[[ ! -e "$HOME/Library/LaunchAgents" && ! -e "$HOME/Library/Application Support/devbox/devbox.log" ]]
printf 'PASS defaults, profile merging, persisted configuration, environment precedence, and read-only inspection\n'

sed 's/"name": "devbox"/"name": "custom-devbox"/' "$SCRIPT" > "$WORK/custom-cli.sh"
mkdir -p "$HOME/Library/Application Support/custom-devbox"
printf '{"schemaVersion":1,"name":"custom-devbox","retention":9}\n' > "$HOME/Library/Application Support/custom-devbox/desired-config.json"
bash "$WORK/custom-cli.sh" config > "$WORK/custom.json"
[[ "$(/usr/bin/plutil -extract name raw -o - "$WORK/custom.json")" == custom-devbox ]]
[[ "$(/usr/bin/plutil -extract retention raw -o - "$WORK/custom.json")" == 9 ]]
printf 'PASS custom packaged names discover only their own installed desired configuration\n'

LEGACY_HOME="$WORK/legacy-home"
LEGACY_STATE="$LEGACY_HOME/Library/Application Support/devbox/config.plist"
mkdir -p "$(dirname "$LEGACY_STATE")"
/usr/bin/plutil -create xml1 "$LEGACY_STATE"
/usr/bin/plutil -insert schemaVersion -integer 3 "$LEGACY_STATE"
/usr/bin/plutil -insert retention -integer 19 "$LEGACY_STATE"
/usr/bin/plutil -insert hideVolume -bool true "$LEGACY_STATE"
/usr/bin/plutil -insert mountPoint -string '/Volumes/Legacy Workspace' "$LEGACY_STATE"
HOME="$LEGACY_HOME" bash "$SCRIPT" config > "$WORK/legacy.json"
[[ "$(/usr/bin/plutil -extract retention raw -o - "$WORK/legacy.json")" == 19 ]]
[[ "$(/usr/bin/plutil -extract macos.hideVolume raw -o - "$WORK/legacy.json")" == true ]]
[[ "$(/usr/bin/plutil -extract macos.volumeLabel raw -o - "$WORK/legacy.json")" == 'Legacy Workspace' ]]
[[ "$(/usr/bin/plutil -extract windows.sizeGiB raw -o - "$WORK/legacy.json")" == 100 ]]
/usr/bin/plutil -insert name -string $'devbox\n' "$LEGACY_STATE"
if HOME="$LEGACY_HOME" bash "$SCRIPT" config > "$WORK/invalid-legacy-name.log" 2>&1; then
  echo 'ERROR: A legacy name ending in a line feed was accepted.' >&2; exit 1
fi
/usr/bin/plutil -remove name "$LEGACY_STATE"
/usr/bin/plutil -replace mountPoint -string $'/Volumes/Legacy Workspace\n' "$LEGACY_STATE"
if HOME="$LEGACY_HOME" bash "$SCRIPT" config > "$WORK/invalid-legacy-mount.log" 2>&1; then
  echo 'ERROR: A legacy mount point ending in a line feed was accepted.' >&2; exit 1
fi
/usr/bin/plutil -replace mountPoint -string '/Volumes/Legacy Workspace' "$LEGACY_STATE"
/usr/bin/plutil -replace schemaVersion -integer 99 "$LEGACY_STATE"
if HOME="$LEGACY_HOME" bash "$SCRIPT" config > "$WORK/invalid-legacy.log" 2>&1; then
  echo 'ERROR: Unsupported legacy state schema was accepted.' >&2; exit 1
fi
printf 'PASS legacy scalar settings are preserved and unsupported state schemas are rejected\n'

for invalid in \
  '{}' 'null' '[]' '[{"schemaVersion":1}]' '{"schemaVersion":2}' '{"schemaVersion":"1"}' \
  '{"schemaVersion":1,"retension":14}' '{"schemaVersion":1,"macos":{"sizeGb":100}}' \
  '{"schemaVersion":1,"macos":null}' '{"schemaVersion":1,"name":"../escape"}' \
  '{"schemaVersion":1,"retention":0}' '{"schemaVersion":1,"retention":"14"}' \
  '{"schemaVersion":1,"macos":{"hideVolume":"true"}}' \
  '{"schemaVersion":1,"name":"devbox\n"}' \
  '{"schemaVersion":1,"macos":{"volumeLabel":"Workspace\n"}}' \
  '{"schemaVersion":1,"workspaceDirectories":["repos\n"]}' \
  '{"schemaVersion":1,"windows":{"preferredDriveLetters":["V\n"]}}' \
  '{"schemaVersion":1,"workspaceDirectories":["repos","repos"]}'; do
  printf '%s\n' "$invalid" > "$WORK/invalid.json"
  if bash "$SCRIPT" --config "$WORK/invalid.json" config > "$WORK/invalid-output.log" 2>&1; then
    echo "ERROR: Invalid configuration accepted: $invalid" >&2; exit 1
  fi
done
if DEVBOX_HIDE_VOLUME=invalid bash "$SCRIPT" config > "$WORK/invalid-env.log" 2>&1; then
  echo 'ERROR: Invalid boolean environment value accepted.' >&2; exit 1
fi
for setting in 'DEVBOX_NAME=devbox' 'DEVBOX_VOLUME_LABEL=Workspace Tools' 'DEVBOX_SIZE_GB=8' 'DEVBOX_HIDE_VOLUME=true'; do
  if /usr/bin/env "$setting"$'\n' bash "$SCRIPT" config > "$WORK/invalid-newline-env.log" 2>&1; then
    echo "ERROR: Environment value ending in a line feed was accepted: ${setting%%=*}" >&2; exit 1
  fi
done
if bash "$SCRIPT" --config "$WORK/missing.json" config > "$WORK/missing.log" 2>&1; then
  echo 'ERROR: Missing explicit configuration silently fell back.' >&2; exit 1
fi
printf 'PASS invalid, missing, unknown, unsafe, and incorrectly typed configuration is rejected\n'

sed -n '/^write_agents(){/,/^apply_backup_retention(){/p' "$SCRIPT" | sed '$d' > "$WORK/agents.sh"
sed -n '/^plist_create(){/,/^write_config(){/p' "$SCRIPT" | sed '$d' > "$WORK/plists.sh"
# shellcheck source=/dev/null
source "$WORK/plists.sh"
# shellcheck source=/dev/null
source "$WORK/agents.sh"
AGENT_ROOT="$WORK/agents"
DEVBOX_LAUNCHD_PREFIX=com.blackoutsecure.devbox
MOUNT_AGENT="$AGENT_ROOT/$DEVBOX_LAUNCHD_PREFIX.mount.plist"
BACKUP_AGENT="$AGENT_ROOT/$DEVBOX_LAUNCHD_PREFIX.backup.plist"
INSTALLED_SCRIPT="$WORK/user & space/devbox.sh"
DESIRED_CONFIG_FILE="$WORK/user & space/desired-config.json"
export LOG_PATH="$WORK/user & space/devbox.log"
export DEVBOX_BACKUP_HOUR=2 DEVBOX_BACKUP_MINUTE=0
# Do not invoke write_agents: that would call launchctl. Test its serialization before registration.
sed '/^  for plist in "\$MOUNT_AGENT" "\$BACKUP_AGENT"; do/,$d' "$WORK/agents.sh" > "$WORK/serialize.sh"
printf '}\n' >> "$WORK/serialize.sh"
# shellcheck source=/dev/null
source "$WORK/serialize.sh"
write_agents
[[ "$(/usr/bin/plutil -extract ProgramArguments.3 raw -o - "$BACKUP_AGENT")" == "$DESIRED_CONFIG_FILE" ]]
[[ "$(/usr/bin/plutil -extract ProgramArguments.1 raw -o - "$MOUNT_AGENT")" == "$INSTALLED_SCRIPT" ]]
printf 'PASS generated user agents retain explicit configuration paths and XML-sensitive user paths\n'

sed -n '/^calculate_sparsebundle_tree_hash(){/,/^validate_sparsebundle(){/p' "$SCRIPT" | sed '$d' > "$WORK/hash.sh"
sed -n '/^metadata_path_for(){/,/^find_latest_backup_in_root(){/p' "$SCRIPT" | sed '$d' > "$WORK/metadata.sh"
# shellcheck source=/dev/null
source "$WORK/hash.sh"
# shellcheck source=/dev/null
source "$WORK/metadata.sh"
log(){ printf '%s\n' "$1"; }
is_true(){ [[ "$1" == true ]]; }
validate_backup_artifact(){ return 0; }
export USER_ROOT="$WORK" MACHINE_NAME=test-fixture
export DEVBOX_VERSION
DEVBOX_VERSION="$(/usr/bin/plutil -extract versions.macos raw -o - "$ROOT/services/devbox/service.json")"
export DEVBOX_VERIFY_BACKUP_HASH=true DEVBOX_ALLOW_BACKUP_WITHOUT_METADATA=false DEVBOX_VALIDATE_BACKUP_MOUNT=false
ORIGINAL="$WORK/original.sparsebundle"
RELOCATED="$WORK/relocated.sparsebundle"
mkdir -p "$ORIGINAL/bands"
printf 'canary\n' > "$ORIGINAL/bands/0"
HASH="$(calculate_sparsebundle_tree_hash "$ORIGINAL")"
write_backup_metadata "$ORIGINAL.plist" "$ORIGINAL" "$HASH"
verify_backup "$ORIGINAL"
cp -R "$ORIGINAL" "$RELOCATED"; cp "$ORIGINAL.plist" "$RELOCATED.plist"
verify_backup "$RELOCATED"
printf 'corruption\n' > "$RELOCATED/bands/0"
if verify_backup "$RELOCATED"; then echo 'ERROR: Corrupted backup was accepted.' >&2; exit 1; fi
printf 'PASS v5 metadata survives relocation and rejects corrupted backup contents\n'

HASH="$(calculate_sparsebundle_tree_hash "$ORIGINAL" absolute-path-v0)"
/usr/bin/plutil -replace schemaVersion -integer 4 "$ORIGINAL.plist"
/usr/bin/plutil -remove treeHashFormat "$ORIGINAL.plist"
/usr/bin/plutil -replace sha256Tree -string "$HASH" "$ORIGINAL.plist"
verify_backup "$ORIGINAL"
cp "$ORIGINAL.plist" "$RELOCATED.plist"
if verify_backup "$RELOCATED"; then echo 'ERROR: Relocated legacy metadata was accepted.' >&2; exit 1; fi
/usr/bin/plutil -replace schemaVersion -integer 99 "$ORIGINAL.plist"
/usr/bin/plutil -replace verified -bool false "$ORIGINAL.plist"
DEVBOX_ALLOW_BACKUP_WITHOUT_METADATA=true
if verify_backup "$ORIGINAL"; then echo 'ERROR: Unknown metadata schema fell through to incomplete-metadata allowance.' >&2; exit 1; fi
printf 'PASS legacy hashes remain valid in place and unknown schemas fail explicitly\n'
