import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import test from 'node:test';
import { serviceRoot } from '../configuration.mjs';

const source = (await readFile(new URL('macos/manage-devbox.sh', serviceRoot), 'utf8')).replaceAll('\r\n', '\n');
const start = source.indexOf('case "$MODE" in\n');
assert.notEqual(start, -1);
const dispatch = source.slice(start);
const bash = process.env.BOS_BASH ?? (process.platform === 'win32'
  ? join(process.env.ProgramFiles, 'Git', 'bin', 'bash.exe') : 'bash');

function validate(argument) {
  const result = spawnSync(bash, ['--noprofile', '--norc', '-s'], {
    input: `set -euo pipefail
MODE=validate
IMAGE_PATH=invalid-live
COMMAND_ARGUMENT='${argument}'
validate_backup_artifact(){ printf 'live:%s\\n' "$1" >&2; return 1; }
verify_backup(){ printf 'backup:%s\\n' "$1" >&2; return 0; }
${dispatch}`,
    encoding: 'utf8',
    timeout: 120000
  });
  if (result.error) throw result.error;
  return result;
}

test('the actual Bash dispatch preserves a failed default live validation', () => {
  const result = validate('');
  assert.equal(result.status, 1);
  assert.equal(result.stderr, 'live:invalid-live\n');
});

test('the actual Bash dispatch validates only an explicitly selected backup', () => {
  const result = validate('selected-backup');
  assert.equal(result.status, 0);
  assert.equal(result.stderr, 'backup:selected-backup\n');
});

const cleanupStart = source.indexOf('cleanup_backup(){');
const cleanupEnd = source.indexOf('\nbackup_devbox(){', cleanupStart);
assert.ok(cleanupStart >= 0 && cleanupEnd > cleanupStart);
const cleanup = source.slice(cleanupStart, cleanupEnd);

test('backup cleanup cannot mask a remount failure as success', () => {
  const result = spawnSync(bash, ['--noprofile', '--norc', '-s'], {
    input: `set -euo pipefail
completed=true
partial=''
remount=true
log(){ printf '%s\\n' "$1" >&2; }
is_mounted(){ return 1; }
mount_devbox(){ return 1; }
release_backup_lock(){ return 0; }
${cleanup}
trap 'cleanup_backup' EXIT
exit 0
`,
    encoding: 'utf8',
    timeout: 120000
  });
  if (result.error) throw result.error;
  assert.equal(result.status, 1);
  assert.match(result.stderr, /could not restore the mount/);
});

const conditionalStart = source.indexOf('conditional_install_backup(){');
const conditionalEnd = source.indexOf('\ninstall_or_repair(){', conditionalStart);
assert.ok(conditionalStart >= 0 && conditionalEnd > conditionalStart);
const conditional = source.slice(conditionalStart, conditionalEnd);

const restoreStart = source.indexOf('restore_devbox(){');
const restoreEnd = source.indexOf('\ncreate_blank_image(){', restoreStart);
assert.ok(restoreStart >= 0 && restoreEnd > restoreStart);
const restore = source.slice(restoreStart, restoreEnd)
  .replaceAll('/usr/bin/ditto', 'copy_fixture')
  .replaceAll('/bin/rm', 'remove_fixture')
  .replaceAll('/bin/mv', 'publish_fixture');

for (const failure of ['none', 'eject', 'cleanup', 'publish']) {
  test(`restore ${failure === 'none' ? 'success' : `${failure} failure`} is preserved when errexit is disabled`, () => {
    const expectedStatus = failure === 'none' ? 0 : 1;
    const result = spawnSync(bash, ['--noprofile', '--norc', '-s'], {
      input: `set -uo pipefail
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
IMAGE_PATH="$fixture/live.sparsebundle"
mkdir "$fixture/backup.sparsebundle"
RESTORE_OCCURRED=false
log(){ printf '%s\\n' "$1"; }
is_mounted(){ return ${failure === 'eject' ? 0 : 1}; }
eject_devbox(){ return 1; }
verify_backup(){ return 0; }
validate_backup_artifact(){ return 0; }
copy_fixture(){ mkdir "$2"; }
remove_fixture(){ ${failure === 'cleanup' ? 'return 1;' : 'rm "$@";'} }
publish_fixture(){ ${failure === 'publish' ? 'return 1;' : 'mv "$1" "$2";'} }
${restore}
restore_devbox "$fixture/backup.sparsebundle"
result=$?
printf 'result=%s restored=%s\\n' "$result" "$RESTORE_OCCURRED"
exit "$result"
`,
      encoding: 'utf8',
      timeout: 120000
    });
    if (result.error) throw result.error;
    assert.equal(result.status, expectedStatus);
    assert.match(result.stdout, new RegExp(`result=${expectedStatus} restored=${expectedStatus ? 'false' : 'true'}`));
    if (expectedStatus) assert.doesNotMatch(result.stdout, /Restore completed/);
  });
}

test('a current backup does not make repeat installation fail or back up again', () => {
  const result = spawnSync(bash, ['--noprofile', '--norc', '-s'], {
    input: `set -euo pipefail
DEVBOX_CONDITIONAL_INSTALL_BACKUP=true
IMAGE_CREATED_THIS_RUN=false
RESTORE_OCCURRED=false
DEVBOX_BACKUP_AFTER_RESTORE=false
DEVBOX_BACKUP_IF_OVERDUE_HOURS=36
LAST_BACKUP_FILE="$(mktemp)"
trap 'rm -f "$LAST_BACKUP_FILE"' EXIT
printf '%s\\n' "$(( $(/bin/date -u +%s) - 60 ))" > "$LAST_BACKUP_FILE"
log(){ printf '%s\\n' "$1"; }
is_true(){ [[ "$1" == true ]]; }
is_mounted(){ return 0; }
find_latest_current_machine_backup(){ printf 'current-backup\\n'; }
backup_devbox(){ printf 'unexpected backup\\n'; return 1; }
${conditional}
conditional_install_backup
`,
    encoding: 'utf8',
    timeout: 120000
  });
  if (result.error) throw result.error;
  assert.equal(result.status, 0);
  assert.equal(result.stdout, 'Current backup exists; conditional backup skipped\n');
});
