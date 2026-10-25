# GhostBSD Remote Access

Provision and inspect a GhostBSD MATE/XRDP endpoint, onboard SSH keys, and open
desktop sessions through an SSH tunnel. The name describes the archive's actual
scope better than "RDP setup" or a general-purpose endpoint remediation service.

## Implementations

| Backend | Role | Privileges |
| --- | --- | --- |
| [GhostBSD](ghostbsd/README.md) | FreeBSD rc.d, Xorg/MATE/XRDP, guest integration, SSH, health checks | Read-only inspection without elevation; apply requires an approved root/sudo session |
| [Windows](windows/README.md) | Operator CLI/wizard, VirtualBox settings, public-key onboarding, remote apply, tunneled MSTSC | Normal user; guest apply prompts through approved sudo |

The guest backend targets GhostBSD with a FreeBSD 14+ base, Bash, and rc.d.
It supports VirtualBox, Hyper-V, and physical profiles. It does not implement
OpenRC, Linux, a Windows RDP server, or a general compliance scanner.
Native GhostBSD/VirtualBox/Hyper-V deployment still requires the disposable
integration gate below; portable tests are not platform certification.

## Build and configuration

From the repository root:

```text
npm run build
npm test
npm run check
```

Deploy the standalone scripts generated under
`output/ghostbsd-remote-access/ghostbsd/` and
`output/ghostbsd-remote-access/windows/`, not authoring templates.
The Windows artifact embeds exactly the generated guest script. Remote apply
does not need the original ZIP, a checkout, or a second script beside it.
Both platform directories include the toolkit LICENSE and NOTICE.

[Defaults](config/defaults.json) and [schema](config/schema.json) are the source
of truth. Optional **build-time** profiles declare `schemaVersion: 1`; unknown
keys, invalid types, unsafe strings, unsupported versions, equal guest SSH/RDP
ports, and out-of-range values fail before this service writes artifacts.

```json
{
  "schemaVersion": 1,
  "platform": "hyperv",
  "hostName": "192.0.2.10",
  "hostSshPort": 22
}
```

```text
npm run build -- --service ghostbsd-remote-access --config path-to-profile.json
```

The default profile uses automatic guest detection, guest SSH 22, loopback XRDP
3389, host `127.0.0.1:2222`, local RDP tunnel 13389, and 128 MiB VirtualBox VRAM.
Guest `sshPort` describes the expected existing SSH port; the service refuses a
conflicting SSH configuration instead of silently changing its port.
Windows host/port overrides and the explicit guest platform flag are validated.
There are deliberately no packaged usernames, VM identities, keys, or passwords.

Profiles are compiled into scripts, not parsed as JSON or fetched on endpoints.
There is no persisted desired-profile reader, scheduler, resident agent, or
secret store for this service. Rebuild/redeploy to change packaged defaults;
an old deployed artifact does not read a newly edited JSON file.
Inspect `config`/`Configuration` before applying a different profile.
Devbox's existing default build and `--config` behavior remain supported;
use `--service` when choosing a profile for this service.

## Shared Rust frontend

The [Rust framework](../../framework/README.md#rust-framework) consumes this
service's same schemas/defaults and provides offline configuration/validation
and read-only plans:

```text
cargo run --locked -- configuration --service ghostbsd-remote-access
cargo run --locked -- plan --service ghostbsd-remote-access --platform windows --operation apply --user desktop
```

The Rust plan never opens SSH/RDP, modifies a VM, installs packages or invokes
sudo. Existing native backends still own those operations and their safety
checks. A custom profile must also be passed to this service's native artifact
build; a Rust plan does not install it or create a runtime profile reader.

## Incoming bundle guidance

The newer bundle's instruction sheet is captured in
[service-scoped Copilot guidance](../../.github/instructions/ghostbsd-remote-access.instructions.md),
not a repository-wide override for the other services. The toolkit service
name and Rust/native execution boundary remain unchanged.
That sheet describes requested behavior; it is not imported runtime code or
test evidence for this checkout.

| Supplied update | Current toolkit status |
| --- | --- |
| Platform profiles, SSH safeguards, safe Windows host parameter and LF normalization | Implemented; retain existing interfaces and stricter safeguards |
| MATE compositor/animation tuning with persistent autostart | Requested; not yet implemented here |
| XRDP `max_bpp=24` and corresponding health checks | Requested; not yet implemented here |
| XRDP valid-backup/sample recovery after mutation or startup failure | Staged section-scoped edits exist; expanded recovery remains to be implemented and tested |
| Expanded graphics, effective SSH and MATE/tuning health checks | Requested additions beyond current service/integration/listener checks |
| Optional IPFW baseline and disable | Not implemented; `firewall` remains reporting-only pending ownership, rollback and lockout safeguards |
| Legacy bundle script names/flags | Reference names, not installed compatibility aliases |

## Safety contract

- No argument means read-only guest status, never unattended apply.
- Every mutation has an explicit operation and `--dry-run` or `-WhatIf`.
- No automatic elevation or NOPASSWD policy is installed or required.
- SSH host-key verification stays enabled. Bootstrap trust by verifying the
  fingerprint out of band, not by disabling host-key checking.
- SSH configuration is staged and validated before atomic publication, with
  a retained first backup. Restart/listener failure attempts rollback.
  Existing `Match`, allowlists, authentication choices, and non-service text
  are retained; incompatible effective tunnel/port policies cause failure.
- Keys-only SSH requires valid installed keys and an explicit assertion that
  a separate login succeeded; new keys-only policy is scoped to that account.
  Adding a key never removes existing keys.
  SSH keys do not replace the account password used by XRDP/PAM.
- XRDP binds only to IPv4 loopback. No public XRDP or VirtualBox VRDE listener
  is intentionally opened.
- Firewall policy is reported, not replaced, disabled, or flushed. Ensure the
  existing firewall permits the chosen SSH connection.
- Guest package additions and rc.d enablement are persistent. There is no
  automatic package removal or destructive "uninstall everything" shortcut.
- Local display-manager services and Xorg device drivers are left alone.
  Changing XRDP/sesman settings can interrupt existing RDP sessions.
- Windows will not power off a VM, discard a saved state, regenerate existing
  private keys, change network topology, or bypass PowerShell execution policy.

## Archive review and migration

All 14 files in `ghostbsd-rdp-complete-setup.zip` were reviewed. The archive is
input/reference material, not an artifact copied verbatim or executed during
development. Endpoint-specific usernames/VM names were removed from defaults.
Old names/flags are not compatibility entry points in this new service.

| Archive file | New surface or intentional change |
| --- | --- |
| `ghostbsd-endpoint-remediation-wizard.sh` | Guest `wizard`, explicit CLI operations, read-only default; firewall replacement/disable deliberately omitted |
| `run-ghostbsd-rdp-setup.sh` | One generated guest entry point replaces the wrapper/helper dependency |
| `ghostbsd-rdp-full-setup.sh` | Guest `rdp`/`apply`; adds `xorgxrdp`, loopback binding and user launcher; no obsolete HAL or forced graphics/display restart |
| `ghostbsd-rdp-health-check.sh` | Guest `status`, including boot enablement, running services, integration, user launcher and safe listeners |
| `ghostbsd-ssh-secure-setup.sh` | Guest `ssh`/`apply`; staged validation, effective policy checks, backup and rollback; no `eval` or automatic keys-only choice |
| `ghostbsd-ssh-key-walkthrough.sh` | Guest `key --public-key FILE`; validated public key, real account lookup and user-owned writes |
| `remove-temp-nopasswd-sudo.sh` | Explicit `sudo-cleanup --sudoers-file FILE`; no hard-coded personal rule, loaded policy validated, disabled backup retained |
| `Set-GhostBSDVirtualBoxBestPractices.ps1` | `VirtualBoxStatus`/`VirtualBoxApply`; all forwarding entries inspected, loopback NAT reconciliation; normal power-off required |
| `Install-GhostBSDSshKey.ps1` | `InstallKey`; avoids reserved `$Host`, validates key data, never overwrites private keys, optional interactive key generation |
| `Invoke-GhostBSDSetupFromWindows.ps1` | `Apply`; generated embedded backend, private temporary staging, quoted remote commands, checked native exit codes and cleanup |
| `Start-GhostBSDRdpSession.ps1` | `Rdp`; loopback binding, strict host keys, verified listener ownership/readiness, owned tunnel cleanup |
| `Start-GhostBSDSetupWizard.ps1` | `Wizard`; explicit actions, real exit, no automatic VM shutdown or execution-policy bypass |
| `GHOSTBSD-RDP-SETUP-README.txt` | This service guide and the two platform guides |
| `COPILOT_INSTRUCTIONS_GHOSTBSD_ENDPOINT.md` | Reviewed as input; not installed as repository-wide agent instructions |

The old firewall baseline flushed global rules and omitted essential outbound,
DNS and DHCP allowances. Replacing somebody else's firewall cannot be made safe
by calling it a "secure baseline." Keep that policy with its existing owner.
The explicit temporary-sudo cleanup remains separate from ordinary apply.

## Validation and native integration gate

`npm test` builds private fixtures and runs guest contracts and Windows mocks
(the latter only on Windows). It checks read-only/default/preview behavior,
failure propagation, scoped INI/SSH edits, key preservation, NAT conflicts,
saved/running VM refusal, deterministic embedding and configuration rejection.
`npm run check` also checks both generated backends.
Tests do not install packages, change a real VM, contact a real host, register
services, or alter the workstation firewall.

Before rollout, use a disposable GhostBSD guest and Windows operator:

1. Inspect configuration, guest health and VirtualBox drift.
2. Preview all requested mutations. Confirm a normal VM shutdown is required.
3. Bootstrap SSH at the guest console and verify its host fingerprint.
4. Install a public key, test a separate login, then opt into keys-only if desired.
5. Apply twice; confirm the second run preserves keys/backups and converges.
6. Check both IPv4/IPv6 listeners, startup enablement and reboot behavior.
7. Confirm MATE login through the tunnel, including a non-default port profile.
8. Exercise a busy local port, rejected host key, failed sudo/SSH restart,
   unavailable packages and interrupted upload; confirm errors and cleanup.
9. Validate VirtualBox and Hyper-V integration independently; neither implies
   testing of the other. Keep console access available throughout.

[Toolkit overview](../../README.md) | [Framework standards](../../framework/README.md)
