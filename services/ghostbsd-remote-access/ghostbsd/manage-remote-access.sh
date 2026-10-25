#!/usr/bin/env bash
set -Eeuo pipefail

log() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 2; }
need_cmd() { command -v "$1" >/dev/null || die "Required command is unavailable: $1"; }

# >>> ghostbsd-remote-access:configuration >>>
REMOTE_ACCESS_CONFIGURATION_READY=false
validate_configuration() {
  [[ "$REMOTE_ACCESS_CONFIGURATION_READY" == true ]] ||
    die 'Build first; deploy output/ghostbsd-remote-access/ghostbsd/manage-remote-access.sh.'
}
# <<< ghostbsd-remote-access:configuration <<<

TARGET_USER=''
TARGET_HOME=''
PUBLIC_KEY_FILE=''
SUDOERS_FILE=''
DRY_RUN=false
KEYS_ONLY=false
KEY_TESTED=false
STAGE=''
LOCK_HELD=false
PUBLISH_TEMP=''
ROOT_CHANGED=false

usage() {
  cat <<'USAGE'
Usage: manage-remote-access.sh [options] [status|config|apply|rdp|ssh|key|firewall|sudo-cleanup|wizard]
  --user NAME           Existing non-root desktop/SSH account; required except config/firewall
  --platform PROFILE    auto, virtualbox, hyperv, or physical
  --public-key FILE     Existing OpenSSH public key for the key operation
  --keys-only           Disable password/keyboard-interactive SSH authentication
  --key-tested          Confirm this account's key login was tested in a separate session
  --sudoers-file FILE   Explicit temporary rule under /usr/local/etc/sudoers.d/
  --dry-run             Preview a mutation without changing files, packages, or services
No operation defaults to read-only status. Mutations require root; sudo policy is never installed.
USAGE
}

require_platform() {
  [[ "$(uname -s)" == FreeBSD ]] || die 'This backend requires GhostBSD/FreeBSD, not Linux or macOS.'
  local release
  release="$(uname -r)"
  [[ "${release%%.*}" =~ ^[0-9]+$ ]] || die 'Cannot determine the FreeBSD base version.'
  (( ${release%%.*} >= 14 )) || die 'This backend requires a FreeBSD 14-or-newer base.'
  [[ -r /etc/rc.subr ]] || die 'FreeBSD rc.d is required; OpenRC is not supported.'
  for command in service sysrc sockstat pkg getent sysctl; do need_cmd "$command"; done
}

resolve_platform() {
  [[ "$PLATFORM" == auto ]] || return 0
  local guest
  guest="$(sysctl -n kern.vm_guest)" || die 'Cannot inspect the guest platform.'
  case "$guest" in
    vbox) PLATFORM=virtualbox ;;
    hv) PLATFORM=hyperv ;;
    none) PLATFORM=physical ;;
    *) die "Unsupported automatic guest profile '$guest'; explicitly select a supported profile." ;;
  esac
}

resolve_account() {
  [[ "$TARGET_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die 'Supply --user with a valid existing non-root account.'
  local record account uid account_shell
  record="$(getent passwd "$TARGET_USER")" || die 'The requested account does not exist.'
  IFS=: read -r account _ uid _ _ TARGET_HOME account_shell <<< "$record"
  [[ "$account" == "$TARGET_USER" && "$uid" =~ ^[0-9]+$ && "$uid" != 0 ]] ||
    die 'A non-root account is required.'
  case "$account_shell" in */nologin|*/false|'') die 'An interactive login account is required.' ;; esac
  [[ "$TARGET_HOME" =~ ^/[A-Za-z0-9_./-]+$ && "$TARGET_HOME" != / &&
     -d "$TARGET_HOME" && ! -L "$TARGET_HOME" ]] || die 'The account needs an existing, non-symlink home with a safe absolute path.'
  [[ "$(stat -f '%u' "$TARGET_HOME")" == "$uid" ]] || die 'The account must own its home directory.'
}

service_enabled() {
  local value result=0
  value="$(sysrc -n "$1")" || result=$?
  if (( result > 1 )); then die "Cannot read rc.conf setting: $1"; fi
  [[ "$value" == YES || "$value" == yes ]]
}

ensure_service() {
  local rcvar="$1" name="$2" restart="${3:-false}"
  if ! service_enabled "$rcvar"; then sysrc "$rcvar=YES" || return 1; fi
  if service "$name" onestatus; then
    if [[ "$restart" == true ]]; then service "$name" onerestart || return 1; fi
  else
    service "$name" onestart || return 1
  fi
  service "$name" onestatus
}

check_rdp_listener() {
  local sockets
  sockets="$(sockstat -46 -l)" || die 'Cannot inspect listening sockets.'
  awk -v port="$RDP_PORT" '
    $2 == "xrdp" {
      if ($6 == "127.0.0.1:" port) found=1
      else unsafe=1
    }
    END { exit !(found && !unsafe) }
  ' <<< "$sockets"
}

check_ssh_listener() {
  local sockets
  sockets="$(sockstat -46 -l)" || die 'Cannot inspect listening sockets.'
  awk -v port="$SSH_PORT" '$2 == "sshd" && $6 ~ (":" port "$") { found=1 } END { exit !found }' <<< "$sockets"
}

status() {
  local failed=0 pair rcvar name package
  for package in xorg mate xrdp xorgxrdp; do
    if pkg info -e "$package"; then log "Package present: $package"; else warn "Package missing: $package"; failed=1; fi
  done
  for pair in dbus_enable:dbus xrdp_enable:xrdp xrdp_sesman_enable:xrdp-sesman sshd_enable:sshd; do
    rcvar="${pair%%:*}"; name="${pair#*:}"
    if service_enabled "$rcvar"; then log "Enabled: $name"; else warn "Disabled: $name"; failed=1; fi
    if service "$name" onestatus; then log "Running: $name"; else warn "Not running: $name"; failed=1; fi
  done
  if [[ "$PLATFORM" == virtualbox ]]; then
    for pair in vboxguest_enable:vboxguest vboxservice_enable:vboxservice; do
      if ! service_enabled "${pair%%:*}" || ! service "${pair#*:}" onestatus; then warn "Guest integration missing: $pair"; failed=1; fi
    done
  elif [[ "$PLATFORM" == hyperv ]]; then
    for name in hv_kvp_daemon hv_vss_daemon; do
      if ! service_enabled "${name}_enable" || ! service "$name" onestatus; then warn "Guest integration missing: $name"; failed=1; fi
    done
  fi
  if ! check_rdp_listener; then warn "XRDP must listen only on 127.0.0.1:$RDP_PORT."; failed=1; fi
  if ! check_ssh_listener; then warn "SSHD is not listening on expected port $SSH_PORT."; failed=1; fi
  if [[ ! -f "$TARGET_HOME/startwm.sh" || -L "$TARGET_HOME/startwm.sh" ]] ||
     ! grep -Fqx 'exec /usr/local/bin/dbus-run-session -- /usr/local/bin/mate-session' "$TARGET_HOME/startwm.sh"; then
    warn 'The selected account is missing the managed MATE session launcher.'
    failed=1
  fi
  if (( failed )); then printf 'REMEDIATION_REQUIRED\n'; return 1; fi
  printf 'COMPLIANT\n'
}

cleanup() {
  local result="$1"
  trap - EXIT
  if [[ -n "$PUBLISH_TEMP" ]] && ! rm -f -- "$PUBLISH_TEMP"; then warn 'Cannot remove staged configuration.'; result=1; fi
  if [[ -n "$STAGE" ]]; then
    if [[ "$STAGE" == /var/tmp/bos-ghostbsd-remote-access.* ]]; then
      if ! rm -rf -- "$STAGE"; then warn 'Cannot remove private staging directory.'; result=1; fi
    else
      warn 'Refusing cleanup of an unexpected staging path.'
      result=1
    fi
  fi
  if [[ "$LOCK_HELD" == true ]] && ! rmdir /var/run/bos-ghostbsd-remote-access.lock; then
    warn 'Cannot release the operation lock.'
    result=1
  fi
  exit "$result"
}

begin_mutation() {
  [[ "$(id -u)" == 0 ]] || die 'Apply requires root. Use an approved sudo session or the local console; passwordless sudo is not required.'
  umask 077
  mkdir /var/run/bos-ghostbsd-remote-access.lock || die 'Another operation or a stale lock exists; inspect it before retrying.'
  LOCK_HELD=true
  trap 'cleanup "$?"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  STAGE="$(mktemp -d /var/tmp/bos-ghostbsd-remote-access.XXXXXXXX)"
}

publish_root() {
  local source="$1" target="$2" mode="$3" comparison=0
  [[ -f "$target" && ! -L "$target" && ! -L "$target.bos-remote-access.bak" ]] ||
    die "Refusing an absent or symlinked managed configuration: $target"
  cmp -s "$source" "$target" || comparison=$?
  (( comparison <= 1 )) || die "Cannot compare configuration: $target"
  (( comparison == 1 )) || return 0
  if [[ ! -e "$target.bos-remote-access.bak" ]]; then cp -p "$target" "$target.bos-remote-access.bak"; fi
  PUBLISH_TEMP="$(mktemp "$(dirname "$target")/.bos-remote-access.XXXXXXXX")"
  install -m "$mode" "$source" "$PUBLISH_TEMP"
  mv -f -- "$PUBLISH_TEMP" "$target"
  PUBLISH_TEMP=''
  ROOT_CHANGED=true
}

set_ini() {
  local source="$1" section="$2" key="$3" value="$4" output="$5"
  awk -v section="$section" -v key="$key" -v value="$value" '
    function finish() { if (inside && !written) { print key "=" value; written=1 } }
    /^[[:space:]]*\[/ {
      finish()
      inside=($0 == "[" section "]")
      if (inside) seen=1
    }
    inside && $0 ~ ("^[[:space:]]*" key "[[:space:]]*=") {
      if (!written) print key "=" value
      written=1
      next
    }
    { print }
    END { finish(); if (!seen) exit 2 }
  ' "$source" > "$output" || die "Cannot update [$section] $key in the installed INI format."
}

install_session() {
  # Run home-directory writes as the account, not root, including symlink races.
  su -m "$TARGET_USER" -c "/usr/local/bin/bash -s -- '$TARGET_HOME'" <<'SESSION'
set -Eeuo pipefail
home="$1"
target="$home/startwm.sh"
[[ ! -L "$target" && ! -L "$target.bos-remote-access.bak" ]] || { echo '[ERROR] Refusing a symlinked user launcher.' >&2; exit 2; }
stage="$(mktemp "$home/.bos-startwm.XXXXXXXX")"
trap 'rm -f -- "$stage"' EXIT
printf '%s\n' '#!/bin/sh' 'exec /usr/local/bin/dbus-run-session -- /usr/local/bin/mate-session' > "$stage"
comparison=0
if [[ -e "$target" ]]; then cmp -s "$stage" "$target" || comparison=$?; else comparison=1; fi
(( comparison <= 1 )) || { echo '[ERROR] Cannot compare the user launcher.' >&2; exit 2; }
if (( comparison == 1 )); then
  if [[ -e "$target" && ! -e "$target.bos-remote-access.bak" ]]; then cp -p "$target" "$target.bos-remote-access.bak"; fi
  chmod 0755 "$stage"
  mv -f -- "$stage" "$target"
fi
SESSION
}

apply_rdp() {
  local missing=() package sesman_changed rdp_changed
  for package in xorg mate xrdp xorgxrdp; do if ! pkg info -e "$package"; then missing+=("$package"); fi; done
  if (( ${#missing[@]} )); then pkg install -y "${missing[@]}"; fi
  if [[ "$PLATFORM" == virtualbox ]]; then
    if ! pkg info -e virtualbox-ose-additions; then pkg install -y virtualbox-ose-additions; fi
    ensure_service vboxguest_enable vboxguest
    ensure_service vboxservice_enable vboxservice
  elif [[ "$PLATFORM" == hyperv ]]; then
    ensure_service hv_kvp_daemon_enable hv_kvp_daemon
    ensure_service hv_vss_daemon_enable hv_vss_daemon
  fi
  install_session
  [[ -f /usr/local/etc/xrdp/xrdp.ini && -f /usr/local/etc/xrdp/sesman.ini ]] || die 'XRDP package configuration files are missing.'
  set_ini /usr/local/etc/xrdp/xrdp.ini Globals port "tcp://127.0.0.1:$RDP_PORT" "$STAGE/xrdp.ini"
  set_ini /usr/local/etc/xrdp/sesman.ini Globals EnableUserWindowManager true "$STAGE/sesman.1"
  set_ini "$STAGE/sesman.1" Globals UserWindowManager startwm.sh "$STAGE/sesman.2"
  set_ini "$STAGE/sesman.2" Security AllowRootLogin false "$STAGE/sesman.ini"
  ROOT_CHANGED=false
  publish_root "$STAGE/xrdp.ini" /usr/local/etc/xrdp/xrdp.ini 0644
  rdp_changed="$ROOT_CHANGED"
  ROOT_CHANGED=false
  publish_root "$STAGE/sesman.ini" /usr/local/etc/xrdp/sesman.ini 0644
  sesman_changed="$ROOT_CHANGED"
  ensure_service dbus_enable dbus
  ensure_service xrdp_sesman_enable xrdp-sesman "$sesman_changed"
  ensure_service xrdp_enable xrdp "$rdp_changed"
  check_rdp_listener || die 'XRDP verification failed: expected an exclusively loopback listener.'
}

validate_public_key() {
  [[ -f "$PUBLIC_KEY_FILE" ]] || die 'Supply --public-key with an existing OpenSSH public key.'
  local key
  key="$(cat "$PUBLIC_KEY_FILE")"
  [[ -n "$key" && "$key" != *$'\n'* && "$key" != *$'\r'* ]] || die 'Supply exactly one public-key line.'
  case "$key" in ssh-ed25519\ *|ecdsa-sha2-*\ *|ssh-rsa\ *) ;; *) die 'Unsupported public-key format.' ;; esac
  ssh-keygen -l -f "$PUBLIC_KEY_FILE" >/dev/null || die 'The public key is invalid.'
}

install_key() {
  local encoded
  encoded="$(base64 < "$PUBLIC_KEY_FILE" | tr -d '\r\n')"
  su -m "$TARGET_USER" -c "/usr/local/bin/bash -s -- '$TARGET_HOME' '$encoded'" <<'KEY'
set -Eeuo pipefail
home="$1"
key="$(printf '%s' "$2" | base64 -d)"
directory="$home/.ssh"
target="$directory/authorized_keys"
[[ ! -L "$directory" && ! -L "$target" ]] || { echo '[ERROR] Refusing symlinked SSH paths.' >&2; exit 2; }
umask 077
mkdir -p "$directory"
chmod 0700 "$directory"
touch "$target"
chmod 0600 "$target"
result=0
grep -Fqx -- "$key" "$target" || result=$?
case "$result" in 0) exit 0 ;; 1) ;; *) echo '[ERROR] Cannot inspect existing keys.' >&2; exit 2 ;; esac
stage="$(mktemp "$directory/.bos-authorized-keys.XXXXXXXX")"
trap 'rm -f -- "$stage"' EXIT
cat "$target" > "$stage"
if [[ -s "$stage" ]]; then printf '\n' >> "$stage"; fi
printf '%s\n' "$key" >> "$stage"
chmod 0600 "$stage"
mv -f -- "$stage" "$target"
KEY
}

build_sshd_config() {
  local original="$1" output="$2"
  local account_start="# >>> bos-ghostbsd-remote-access:keys-only:$TARGET_USER >>>"
  local account_end="# <<< bos-ghostbsd-remote-access:keys-only:$TARGET_USER <<<"
  {
    printf '%s\n' '# >>> bos-ghostbsd-remote-access >>>' \
      'PermitRootLogin no' 'PubkeyAuthentication yes' 'PermitEmptyPasswords no' \
      'X11Forwarding no' 'MaxAuthTries 3' 'LoginGraceTime 30' 'UseDNS no' \
      '# <<< bos-ghostbsd-remote-access <<<'
    awk -v keys_only="$KEYS_ONLY" -v account_start="$account_start" -v account_end="$account_end" '
      /^# >>> bos-ghostbsd-remote-access >>>$/ { if (inside || seen) exit 2; inside=1; seen=1; next }
      /^# <<< bos-ghostbsd-remote-access <<</ { if (!inside) exit 2; inside=0; next }
      keys_only == "true" && $0 == account_start { if (account_inside || account_seen) exit 2; account_inside=1; account_seen=1; next }
      keys_only == "true" && $0 == account_end { if (!account_inside) exit 2; account_inside=0; next }
      !inside && !account_inside { print }
      END { if (inside || account_inside) exit 2 }
    ' "$original" || die 'Malformed managed SSH block; inspect the existing configuration.'
    if [[ "$KEYS_ONLY" == true ]]; then
      printf '%s\n' "$account_start" "Match User $TARGET_USER" \
        '    PasswordAuthentication no' '    KbdInteractiveAuthentication no' "$account_end"
    fi
  } > "$output" || die 'Malformed managed SSH block; inspect the existing configuration.'
}

verify_sshd_policy() {
  local config="$1" password="$2" keyboard="$3" effective root_effective
  sshd -t -f "$config" || return 1
  effective="$(sshd -T -f "$config" -C "user=$TARGET_USER,host=localhost,addr=127.0.0.1")" || return 1
  root_effective="$(sshd -T -f "$config" -C 'user=root,host=localhost,addr=127.0.0.1')" || return 1
  grep -qx 'permitrootlogin no' <<< "$root_effective" &&
    grep -qx 'pubkeyauthentication yes' <<< "$effective" &&
    grep -qx "passwordauthentication $password" <<< "$effective" &&
    grep -qx "kbdinteractiveauthentication $keyboard" <<< "$effective" &&
    grep -qx "port $SSH_PORT" <<< "$effective" &&
    grep -qx 'disableforwarding no' <<< "$effective" &&
    grep -Eq '^allowtcpforwarding (yes|local)$' <<< "$effective" &&
    awk -v endpoint="127.0.0.1:$RDP_PORT" '$1 == "permitopen" { for (i=2; i<=NF; i++) if ($i == "any" || $i == endpoint) found=1 } END { exit !found }' <<< "$effective"
}

apply_ssh() {
  local effective password keyboard changed
  [[ ! -L /etc/ssh/sshd_config && -f /etc/ssh/sshd_config ]] || die 'A regular sshd_config is required.'
  if [[ "$KEYS_ONLY" == true ]]; then
    [[ "$KEY_TESTED" == true ]] || die 'Keys-only SSH requires --key-tested after a separate successful login.'
    [[ ! -L "$TARGET_HOME/.ssh" && ! -L "$TARGET_HOME/.ssh/authorized_keys" ]] || die 'Refusing symlinked authorized keys.'
    ssh-keygen -l -f "$TARGET_HOME/.ssh/authorized_keys" >/dev/null || die 'Keys-only SSH requires valid installed authorized keys.'
  fi
  ssh-keygen -A
  effective="$(sshd -T -f /etc/ssh/sshd_config -C "user=$TARGET_USER,host=localhost,addr=127.0.0.1")"
  password="$(awk '$1 == "passwordauthentication" { print $2 }' <<< "$effective")"
  keyboard="$(awk '$1 == "kbdinteractiveauthentication" { print $2 }' <<< "$effective")"
  [[ "$password" =~ ^(yes|no)$ && "$keyboard" =~ ^(yes|no)$ ]] || die 'Cannot inspect current SSH authentication settings.'
  if [[ "$KEYS_ONLY" == true ]]; then password=no; keyboard=no; fi
  build_sshd_config /etc/ssh/sshd_config "$STAGE/sshd_config"
  verify_sshd_policy "$STAGE/sshd_config" "$password" "$keyboard" ||
    die 'Staged SSH policy is invalid or conflicts with port/tunnel/Match restrictions. Live SSH configuration was not replaced.'
  cp -p /etc/ssh/sshd_config "$STAGE/sshd.previous"
  ROOT_CHANGED=false
  publish_root "$STAGE/sshd_config" /etc/ssh/sshd_config 0600
  changed="$ROOT_CHANGED"
  if ! ensure_service sshd_enable sshd "$changed" || ! check_ssh_listener; then
    warn 'SSH verification failed. Restoring the configuration from this operation.'
    publish_root "$STAGE/sshd.previous" /etc/ssh/sshd_config 0600
    ensure_service sshd_enable sshd true || die 'SSH rollback restart failed; recover from the console.'
    die 'SSH apply failed; the previous configuration was restored.'
  fi
}

firewall_report() {
  log 'Firewall policy is not replaced, flushed, disabled, or enabled by this service.'
  local enabled result=0
  enabled="$(sysrc -n firewall_enable)" || result=$?
  (( result <= 1 )) || die 'Cannot inspect firewall configuration.'
  printf 'firewall_enable=%s\n' "${enabled:-unset}"
  if [[ "$enabled" == YES || "$enabled" == yes ]]; then
    need_cmd ipfw
    ipfw list
  fi
  log "Allow expected SSH port $SSH_PORT through your existing policy. XRDP stays on loopback."
}

disable_temporary_sudo() {
  [[ "$SUDOERS_FILE" =~ ^/usr/local/etc/sudoers.d/[A-Za-z0-9_-]+$ ]] ||
    die 'Supply an explicit temporary rule basename under /usr/local/etc/sudoers.d/ (no extension or traversal).'
  [[ -f "$SUDOERS_FILE" && ! -L "$SUDOERS_FILE" && ! -e "$SUDOERS_FILE.bos-remote-access.disabled" ]] ||
    die 'The temporary rule must be a regular file without an existing disabled backup.'
  grep -q NOPASSWD "$SUDOERS_FILE" || die 'The selected rule does not contain NOPASSWD; refusing unrelated policy changes.'
  if [[ "$DRY_RUN" == true ]]; then log 'Would disable the explicitly selected temporary sudo rule and validate sudoers.'; return; fi
  need_cmd visudo
  visudo -c
  mv -- "$SUDOERS_FILE" "$SUDOERS_FILE.bos-remote-access.disabled"
  if ! visudo -c; then
    mv -- "$SUDOERS_FILE.bos-remote-access.disabled" "$SUDOERS_FILE"
    die 'Sudoers validation failed; the temporary rule was restored.'
  fi
  log 'Temporary rule disabled; the non-loaded backup is retained beside it.'
}

preview() {
  case "$1" in
    apply|rdp)
      log "Would install missing XRDP/Xorg/MATE packages and $PLATFORM integration, reconcile the account launcher and XRDP INI files, and enable/start affected rc.d services."
      log "XRDP would bind only to 127.0.0.1:$RDP_PORT; existing local display and firewall policy are preserved."
      ;;
  esac
  case "$1" in
    apply|ssh)
      log "Would stage, validate, back up and atomically publish SSH hardening; preserve the expected SSH port $SSH_PORT and current password policy."
      if [[ "$KEYS_ONLY" == true ]]; then
        [[ "$KEY_TESTED" == true ]] || die 'Keys-only SSH requires --key-tested.'
        log 'Would select keys-only authentication after checking installed keys.'
      fi
      ;;
    key) log 'Would append the validated public key as the target user, retaining existing keys.' ;;
  esac
}

wizard() {
  [[ -t 0 ]] || die 'Wizard requires a terminal; unattended use must name an operation.'
  local choice
  while true; do
    printf '\nGhostBSD Remote Access\n1) Status\n2) Preview full apply\n3) Apply\n4) SSH only\n5) RDP only\n6) Install supplied public key\n7) Firewall report\n0) Exit\n'
    read -r choice || die 'Wizard input ended.'
    case "$choice" in
      0) return 0 ;;
      1) status || warn 'Health checks require attention.' ;;
      2) preview apply ;;
      3|4|5|6)
        case "$choice" in 3) choice=apply ;; 4) choice=ssh ;; 5) choice=rdp ;; 6) choice=key ;; esac
        if [[ "$DRY_RUN" == true ]]; then preview "$choice"; continue; fi
        [[ "$choice" != key ]] || validate_public_key
        begin_mutation
        case "$choice" in
          apply) apply_ssh; apply_rdp; status ;;
          ssh) apply_ssh ;;
          rdp) apply_rdp ;;
          key) install_key ;;
        esac
        return 0
        ;;
      7) firewall_report ;;
      *) warn 'Unknown selection.' ;;
    esac
  done
}

main() {
  local mode='' argument
  while (( $# )); do
    argument="$1"; shift
    case "$argument" in
      --user|--platform|--public-key|--sudoers-file)
        (( $# )) && [[ -n "$1" ]] || die "Missing value for $argument."
        case "$argument" in
          --user) TARGET_USER="$1" ;;
          --platform) PLATFORM="$1" ;;
          --public-key) PUBLIC_KEY_FILE="$1" ;;
          --sudoers-file) SUDOERS_FILE="$1" ;;
        esac
        shift
        ;;
      --dry-run) DRY_RUN=true ;;
      --keys-only) KEYS_ONLY=true ;;
      --key-tested) KEY_TESTED=true ;;
      --help|-h) usage; return 0 ;;
      status|config|apply|rdp|ssh|key|firewall|sudo-cleanup|wizard)
        [[ -z "$mode" ]] || die 'Specify exactly one operation.'
        mode="$argument"
        ;;
      *) die "Unknown argument: $argument" ;;
    esac
  done
  mode="${mode:-status}"
  if [[ "$KEYS_ONLY" == true && "$mode" != apply && "$mode" != ssh && "$mode" != wizard ]]; then die '--keys-only applies only to apply, ssh, or wizard.'; fi
  if [[ "$KEY_TESTED" == true && "$KEYS_ONLY" != true ]]; then die '--key-tested requires --keys-only.'; fi
  validate_configuration
  if [[ "$mode" == config ]]; then
    printf 'schemaVersion=%s\nplatform=%s\nsshPort=%s\nrdpPort=%s\n' "$SCHEMA_VERSION" "$PLATFORM" "$SSH_PORT" "$RDP_PORT"
    return 0
  fi
  require_platform
  resolve_platform
  case "$mode" in firewall|sudo-cleanup) ;; *) resolve_account ;; esac
  case "$mode" in
    status) status ;;
    firewall) firewall_report ;;
    wizard) wizard ;;
    apply|rdp|ssh|key|sudo-cleanup)
      [[ "$mode" != key ]] || validate_public_key
      if [[ "$DRY_RUN" == true ]]; then
        if [[ "$mode" == sudo-cleanup ]]; then disable_temporary_sudo; else preview "$mode"; fi
        return 0
      fi
      begin_mutation
      case "$mode" in
        apply) apply_ssh; apply_rdp; status ;;
        rdp) apply_rdp ;;
        ssh) apply_ssh ;;
        key) install_key ;;
        sudo-cleanup) disable_temporary_sudo ;;
      esac
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
