#!/usr/bin/env bash
set -Eeuo pipefail

guest_path="$1"
if command -v cygpath >/dev/null; then guest_path="$(cygpath -u "$guest_path")"; fi
# shellcheck source=../manage-remote-access.sh
source "$guest_path"

fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT
mkdir "$fixture/home"
printf '%s\n' '#!/bin/sh' 'exec /usr/local/bin/dbus-run-session -- /usr/local/bin/mate-session' > "$fixture/home/startwm.sh"

fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
expect_code() {
  local expected="$1" actual=0
  shift
  ("$@") > "$fixture/assertion.out" 2>&1 || actual=$?
  [[ "$actual" == "$expected" ]] || { cat "$fixture/assertion.out" >&2; fail "Expected $expected, got $actual: $*"; }
}

TARGET_USER='invalid;command'
expect_code 2 resolve_account
require_platform() { :; }
resolve_account() { TARGET_USER=fixture; TARGET_HOME="$fixture/home"; }
sysctl() { printf 'none\n'; }
pkg() { [[ "$1" == info ]] || fail 'Package mutation during inspection/preview.'; }
sysrc() {
  if [[ "${test_rc_read_error:-false}" == true ]]; then return 4; fi
  if [[ "$1" != -n ]]; then
    if [[ "${test_rc_write_error:-false}" == true ]]; then return 9; fi
    fail 'rc.conf mutation during inspection/preview.'
  fi
  if [[ "${test_service_disabled:-false}" == true ]]; then printf 'NO\n'; else printf 'YES\n'; fi
}
service() {
  if [[ "${test_restart_error:-false}" == true && "$2" == onerestart ]]; then return 1; fi
  [[ "$2" == onestatus ]] || fail 'Service mutation during inspection/preview.'
}
sockstat() {
  if [[ "${test_socket_scenario:-normal}" == failed ]]; then return 7; fi
  printf 'USER COMMAND PID FD PROTO LOCAL FOREIGN\n'
  printf 'root xrdp 100 8 tcp4 127.0.0.1:3389 *:*\nroot sshd 101 8 tcp4 *:22 *:*\n'
  case "${test_socket_scenario:-normal}" in
    wildcard) printf 'root xrdp 100 9 tcp6 *:3389 *:*\n' ;;
    extra) printf 'root xrdp 100 9 tcp4 *:3390 *:*\n' ;;
  esac
}
begin_mutation() { fail 'Unexpected mutation path.'; }

expect_code 0 main --user fixture
grep -qx COMPLIANT "$fixture/assertion.out" || fail 'Default operation was not read-only health.'
expect_code 0 main --user fixture --dry-run apply
grep -q 'Would stage' "$fixture/assertion.out" || fail 'Full preview omitted SSH changes.'
grep -q 'XRDP would bind only' "$fixture/assertion.out" || fail 'Full preview omitted RDP changes.'
expect_code 0 main --user fixture --dry-run rdp
expect_code 0 main --user fixture --dry-run ssh
expect_code 2 main --user fixture --keys-only --dry-run ssh
expect_code 2 main --user fixture --platform unknown --dry-run apply
expect_code 2 main --user fixture --key-tested ssh
expect_code 2 main --user fixture --keys-only rdp
expect_code 2 main --user fixture wizard </dev/null
expect_code 2 main --user
expect_code 2 main --user fixture status apply
expect_code 2 main --firewall-disable

(
  test_socket_scenario=wildcard
  expect_code 1 main --user fixture status
  grep -qx REMEDIATION_REQUIRED "$fixture/assertion.out" || fail 'Unsafe listener was reported healthy.'
)
(
  test_socket_scenario=extra
  expect_code 1 check_rdp_listener
)
(
  test_socket_scenario=failed
  expect_code 2 main --user fixture status
)
(
  test_rc_read_error=true
  expect_code 2 service_enabled sshd_enable
)
(
  test_service_disabled=true
  test_rc_write_error=true
  expect_code 1 ensure_service sshd_enable sshd true
)
(
  test_restart_error=true
  expect_code 1 ensure_service sshd_enable sshd true
)

cat > "$fixture/xrdp.ini" <<'INI'
[Globals]
port=3389
port=3390
security_layer=negotiate
[Xorg]
port=-1
INI
set_ini "$fixture/xrdp.ini" Globals port tcp://127.0.0.1:3389 "$fixture/xrdp.new"
[[ "$(grep -c '^port=tcp://127.0.0.1:3389$' "$fixture/xrdp.new")" == 1 ]] || fail 'INI update duplicated a global key.'
grep -qx 'port=-1' "$fixture/xrdp.new" || fail 'INI update changed the Xorg backend port.'
grep -qx 'security_layer=negotiate' "$fixture/xrdp.new" || fail 'INI update lost unrelated configuration.'
expect_code 2 set_ini "$fixture/xrdp.ini" Missing port value "$fixture/missing.ini"

cat > "$fixture/sshd_config" <<'SSH'
Port 22
PasswordAuthentication yes
Match User another
    X11Forwarding yes
SSH
build_sshd_config "$fixture/sshd_config" "$fixture/sshd.new"
build_sshd_config "$fixture/sshd.new" "$fixture/sshd.again"
cmp "$fixture/sshd.new" "$fixture/sshd.again" || fail 'SSH staging is not idempotent.'
grep -qx 'Match User another' "$fixture/sshd.new" || fail 'SSH staging removed Match policy.'
grep -qx '    X11Forwarding yes' "$fixture/sshd.new" || fail 'SSH staging rewrote scoped policy.'
printf '%s\n' '# >>> bos-ghostbsd-remote-access >>>' > "$fixture/malformed"
expect_code 2 build_sshd_config "$fixture/malformed" "$fixture/rejected"
(
  TARGET_USER=fixture
  KEYS_ONLY=true
  build_sshd_config "$fixture/sshd_config" "$fixture/scoped-keys"
  build_sshd_config "$fixture/scoped-keys" "$fixture/scoped-again"
  cmp "$fixture/scoped-keys" "$fixture/scoped-again" || fail 'Keys-only staging was not idempotent.'
  grep -qx 'PasswordAuthentication yes' "$fixture/scoped-keys" || fail 'Keys-only rewrote the existing global auth choice.'
  grep -qx 'Match User fixture' "$fixture/scoped-keys" || fail 'Keys-only was not scoped to the selected account.'
  KEYS_ONLY=false
  build_sshd_config "$fixture/scoped-keys" "$fixture/scoped-preserved"
  cmp "$fixture/scoped-keys" "$fixture/scoped-preserved" || fail 'Ordinary SSH apply removed an existing keys-only choice.'
)

TARGET_USER=fixture
TARGET_HOME="$fixture/home"
su() { bash -s -- "$fixture/home" "${test_key_base64:-}"; }
printf 'existing local session\n' > "$fixture/home/.xsession"
printf 'custom launcher\n' > "$fixture/home/startwm.sh"
install_session
install_session
grep -qx 'custom launcher' "$fixture/home/startwm.sh.bos-remote-access.bak" || fail 'The original launcher backup was lost.'
grep -qx 'existing local session' "$fixture/home/.xsession" || fail 'The local session was changed.'

mkdir "$fixture/home/.ssh"
printf 'existing-key-without-newline' > "$fixture/home/.ssh/authorized_keys"
PUBLIC_KEY_FILE="$fixture/key.pub"
printf 'ssh-ed25519 fixture-public-data fixture\n' > "$PUBLIC_KEY_FILE"
test_key_base64="$(base64 < "$PUBLIC_KEY_FILE" | tr -d '\r\n')"
install_key
install_key
grep -qx 'existing-key-without-newline' "$fixture/home/.ssh/authorized_keys" || fail 'Existing key data was damaged.'
[[ "$(grep -c '^ssh-ed25519 fixture-public-data fixture$' "$fixture/home/.ssh/authorized_keys")" == 1 ]] || fail 'Key install was not append-only/idempotent.'
printf 'PRIVATE\nMATERIAL\n' > "$fixture/private"
PUBLIC_KEY_FILE="$fixture/private"
expect_code 2 validate_public_key

printf 'old\n' > "$fixture/root-config"
printf 'new\n' > "$fixture/staged"
publish_root "$fixture/staged" "$fixture/root-config" 0600
ROOT_CHANGED=false
publish_root "$fixture/staged" "$fixture/root-config" 0600
[[ "$ROOT_CHANGED" == false ]] || fail 'Unchanged root configuration was republished.'
grep -qx old "$fixture/root-config.bos-remote-access.bak" || fail 'The first configuration backup was not preserved.'
printf 'PASS guest read-only, preview, failure, configuration, session, and key contracts\n'
