# GhostBSD remote-access backend

Use the generated `manage-remote-access.sh` on a disposable GhostBSD guest with
a FreeBSD 14+ base, Bash (`/usr/local/bin/bash`) and FreeBSD rc.d. Automatic
profiles use `kern.vm_guest`: `vbox`, `hv`, or `none`. Unknown hypervisors fail
instead of being silently treated as physical; select a profile deliberately.
Unsupported bases/OpenRC fail before apply.

## Inspect and preview

```bash
./manage-remote-access.sh config
./manage-remote-access.sh --user desktop status
./manage-remote-access.sh --user desktop --platform virtualbox --dry-run apply
./manage-remote-access.sh firewall
```

`desktop` is an example existing non-root login, not a created account.
The actual account/home are resolved from the guest account database, not root's
`HOME` or `eval`. Homes must already exist, be account-owned and have a safe
absolute path. Complete socket/firewall visibility may require a read-only
inspection from an approved root session.

Guest status returns 0/`COMPLIANT`, 1/`REMEDIATION_REQUIRED`, or 2 for invalid
arguments/capability/detection errors. Native mutation errors are nonzero.
The status report checks health/readiness, not certification of every possible
SSH `Match` or firewall policy.
No arguments still select status; missing user input is an error, not apply.

## Apply

From an approved administrative session; password-based sudo is supported:

```bash
sudo /usr/local/bin/bash ./manage-remote-access.sh --user desktop apply
sudo /usr/local/bin/bash ./manage-remote-access.sh --user desktop rdp
sudo /usr/local/bin/bash ./manage-remote-access.sh --user desktop ssh
```

The full action enables/hardens SSH, then reconciles XRDP and verifies health.
It installs missing `xorg`, `mate`, `xrdp`, and `xorgxrdp` packages. Package
availability/failure is an error, not a warning followed by success.
VirtualBox additionally installs guest additions and enables `vboxguest` and
`vboxservice`; Hyper-V enables the native KVP/VSS daemons.
Physical skips guest-integration changes. No local display driver is forced.

The per-user `~/startwm.sh` starts `dbus-run-session` with MATE, matching
FreeBSD's user-window-manager contract. It is written as the account itself.
See the [FreeBSD port's launcher contract](https://github.com/freebsd/freebsd-ports/blob/main/net/xrdp/files/startwm.sh)
and [upstream listener configuration](https://github.com/neutrinolabs/xrdp/blob/devel/xrdp/xrdp.ini.in).
Existing launchers get a retained first `.bos-remote-access.bak`; `.xsession`,
`.xinitrc` and local display-manager sessions are not overwritten.
XRDP INI edits are section-scoped; the Xorg backend's own `port=-1` stays intact.
Only changed or stopped services are restarted/started; repeat apply does not
deliberately restart an unchanged running service.

Root configuration updates keep first backups beside their targets. Package
installation and rc.d enablement are not transactional and are not automatically
undone after a later failure. Inspect reported errors/backups with console
access rather than repeatedly applying to a production endpoint.
Conflicting operations use `/var/run/bos-ghostbsd-remote-access.lock`; inspect
an unexpected stale lock before manually clearing it.

## Keys and password policy

```bash
sudo /usr/local/bin/bash ./manage-remote-access.sh --user desktop --public-key /path/to/key.pub --dry-run key
sudo /usr/local/bin/bash ./manage-remote-access.sh --user desktop --public-key /path/to/key.pub key
```

Only one validated public-key line is accepted. Existing keys are retained;
SSH files stay user-owned with directory 0700/file 0600. Repeated installs do
not duplicate the exact line. Never give the service a private key.

Ordinary SSH apply preserves the effective password/keyboard-interactive choice,
including an earlier keys-only setting; it does not restrict all logins to one
user or move the SSH port. Existing allowlists/`Match` blocks remain in place.
New keys-only policy is scoped to the selected account, not every SSH user.
Staging uses `sshd -t` and effective `sshd -T` checks before replacing live
configuration. Conflicting port/tunnel policy fails explicitly.

After independently testing the account's public-key login:

```bash
sudo /usr/local/bin/bash ./manage-remote-access.sh --user desktop --keys-only --key-tested --dry-run ssh
sudo /usr/local/bin/bash ./manage-remote-access.sh --user desktop --keys-only --key-tested ssh
```

`--key-tested` is an explicit operator assertion, not a test fabricated by the
script. Keep an existing session and console access while changing auth.
XRDP/PAM still needs the account's desktop credentials.

## Interactive use and optional cleanup

```bash
sudo /usr/local/bin/bash ./manage-remote-access.sh --user desktop wizard
```

A non-terminal wizard fails; it never falls back to unattended full apply.
The wizard does not create accounts or collect private keys. Supply a public
key file before choosing its key action.

The archive's automatic/hard-coded sudo removal is replaced by an explicit,
separate operation:

```bash
sudo /usr/local/bin/bash ./manage-remote-access.sh --sudoers-file /usr/local/etc/sudoers.d/temporary-access --dry-run sudo-cleanup
sudo /usr/local/bin/bash ./manage-remote-access.sh --sudoers-file /usr/local/etc/sudoers.d/temporary-access sudo-cleanup
```

Only a selected regular, extensionless rule containing `NOPASSWD` is eligible.
The rule is moved to a non-loaded `.bos-remote-access.disabled` backup;
sudoers is validated before and after, with restoration on validation failure.
This is never part of full apply, and the service never creates such a rule.
`firewall` is read-only. Existing IPFW/PF rules and their ownership are preserved.

[Service contract and rollout gate](../README.md)
