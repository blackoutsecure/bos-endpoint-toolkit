---
description: "Use when maintaining GhostBSD Remote Access: XRDP/MATE tuning, SSH, IPFW, Windows orchestration, or its Rust configuration and planning contracts."
applyTo: "services/ghostbsd-remote-access/**,tools/build-remote-access.mjs,tools/tests/remote-access.test.mjs"
---

# GhostBSD Remote Access

Apply these rules only to this service. Follow the repository's
[guidance](../../AGENTS.md), [Rust framework](../../framework/README.md#rust-framework)
and [service contract](../../services/ghostbsd-remote-access/README.md).
Do not apply GhostBSD settings to Devbox or make them repository-wide defaults.

## Identity and ownership

- Keep the canonical service ID `ghostbsd-remote-access`.
- Guest source: [manage-remote-access.sh](../../services/ghostbsd-remote-access/ghostbsd/manage-remote-access.sh).
  Windows operator: [manage-remote-access.ps1](../../services/ghostbsd-remote-access/windows/manage-remote-access.ps1).
- `ghostbsd-endpoint-remediation-wizard.sh` and `run-ghostbsd-rdp-setup.sh` are
  legacy bundle names, not existing toolkit compatibility entry points. Preserve
  current interfaces; add legacy aliases only deliberately, with tests and docs.
- Edit authoring sources, not generated deployment artifacts. Generate aliases
  and embedded payloads from one source; never maintain separate worker copies.
- Keep defaults/schema in service JSON. Configuration additions must also update
  Rust types, schema/merge parity tests, native generation and platform tests.
- Rust owns configuration validation and non-mutating plans, not native
  execution, privilege changes, SSH, firewall operations or GUI configuration.

## Execution and platform profiles

- Preserve interactive wizard and explicit non-interactive operations. No
  operation defaults to apply; a non-terminal wizard must not auto-remediate.
- Require detect -> explicit apply -> verify. Keep idempotence, operation locks,
  staged writes, interruption cleanup and `[INFO]`, `[WARN]`, `[ERROR]` logs.
- Every mutation needs a working `--dry-run` or PowerShell `-WhatIf` path.
  Detection/status/configuration remain read-only; do not test apply on a live
  developer or production endpoint.
- Resolve `auto` or explicit `virtualbox`, `hyperv`, `physical`. Unknown
  automatic profiles fail rather than silently becoming physical.
- VirtualBox: use guest additions and verify integration/graphics appropriate
  to the actual controller. Preserve the host's VMSVGA-oriented workflow;
  do not blindly force `vboxvideo` or overwrite working local Xorg configuration.
- Hyper-V: enable the relevant native daemons; use its graphics driver only
  when present and suitable. Physical must skip VM additions and VM-only checks.

## SSH and Windows orchestration

- Stage and back up SSH configuration; validate with `sshd -t` and inspect
  effective policy before publication/restart. Invalid staging must leave the
  live configuration intact. On post-publication failure, restore the working
  configuration, verify recovery and return nonzero.
- Keep root SSH login disabled. Preserve unrelated allowlists and `Match`
  policy; any proposed privilege change needs explicit approval and evidence.
- Do not weaken existing keys-only safeguards: require valid installed keys,
  explicit keys-only selection and confirmation of a separate tested login.
  Scope new authentication restrictions to the selected account.
- Append validated public keys without deleting existing entries. Never upload
  private keys, overwrite existing key pairs, or grant passwordless sudo.
- Retain the current `ComputerName` parameter; a compatible `RemoteHost` alias
  may be added if needed. Never use the reserved PowerShell `$Host` variable.
- Preserve LF normalization before embedding/uploading a guest script, strict
  host-key checking, checked native exit codes and owned temporary-file cleanup.
- Preserve VM audit/apply, public-key onboarding, embedded guest upload/apply,
  and loopback SSH tunnel/MSTSC workflows. Never discard saved VM state or
  power off a VM automatically; verify tunnel ownership/readiness and cleanup.

## Requested XRDP and MATE extensions

These are incoming bundle requirements, not proof of implementation in this
checkout. Implement, test and document each before advertising support.

- Reconcile XRDP/sesman enablement and startup and a MATE-compatible user
  launcher. Preserve existing user session files and unrelated INI sections.
- Never publish an empty, truncated or invalid `xrdp.ini`. Validate staged
  content, preserve a known-valid backup and recover on mutation/startup failure.
  A packaged sample is only a validated recovery candidate, never a silent
  success-shaped fallback. Failed remediation must still return nonzero.
- Add a user-owned persistent MATE performance profile: compositor off,
  animations off and an autostart entry. Apply settings in the correct user's
  GUI/DBus context, not root's dconf/session.
- Add `max_bpp=24` responsiveness tuning and verify its effective presence.
  Keep its authored default/validation in the shared configuration contract.
- Verify the effective configured ports; defaults are SSH 22 and XRDP 3389.
  Do not hard-code defaults into checks or silently widen loopback XRDP binding.
- Extend health checks for effective SSH hardening where inspectable, graphics
  integration, MATE profile/autostart presence and XRDP tuning. Inability to
  inspect a required check is not a passing result.

## Requested IPFW extensions

Current `firewall` is reporting-only. Instructions alone do not enable new
baseline/disable modes or authorize replacing an endpoint's existing policy.

- Any baseline and disable operations must be distinct, explicitly selected,
  previewable and never included in ordinary full apply.
- A baseline must cover loopback, configured SSH, optional deliberate XRDP,
  stateful established/outbound traffic and basic ICMP. Account for DNS, DHCP
  and applicable IPv6 connectivity; a short inbound-only allowlist is not a
  complete secure baseline.
- Snapshot and validate policy, establish ownership, and provide tested rollback
  and lockout protection before changing runtime rules or boot settings.
  Do not overwrite, disable or flush another owner's rules.
- Disable requires explicit confirmation in interactive flows and an explicit
  acknowledgement in unattended flows. Boot disable (`firewall_enable=NO`) and
  any runtime flush are allowed only after the ownership/recovery guards pass.
- Keep optional direct-RDP policy separate from listener exposure. A firewall
  allowance must not silently change the service's loopback-only XRDP default.

## Validation and maintenance

- Update the service README and platform examples alongside interface/behavior
  changes. Preserve compatibility where feasible without duplicating logic.
- Add focused regression tests for every new managed surface, previews,
  invalid inputs, partial failures, rollback and repeat-run convergence.
- Follow the existing Node/native checks; run Rust checks when configuration
  or planning changes. Use disposable native guests for integration evidence.
  Tests reported for an external bundle are not repository test results.
