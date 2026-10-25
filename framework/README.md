# Endpoint automation framework

The framework standardizes service configuration, build artifacts, safety, and
deployment contracts. It is not a resident endpoint agent or a new storage
engine. Native backends remain responsible for native behavior.

## Ownership

| Area | Owns |
| --- | --- |
| `framework/` | Reusable configuration definitions and cross-service contracts |
| `framework/crates/endpoint-core/` | Rust configuration types, embedded catalogue validation and pure native-adapter plans |
| `framework/crates/endpoint-cli/` | Read-only CLI, explicit profile file I/O and JSON output |
| `services/<name>/config/` | A service's defaults and schema |
| `services/<name>/<platform>/` | Native implementation, tests, privileges, and platform documentation |
| `tools/` | Build-only schema resolution, generation, packaging, and checks |

Promote a helper into shared runtime code only after demonstrated reuse, with
tests and an explicit calling contract. Service-specific storage code does not
belong in the framework. Do not create empty `shared`, OS, or GUI folders.

## Configuration contract

1. Defaults are version-controlled data, separate from desired configuration and
   observed runtime state.
2. Every profile declares a supported schema version. Unknown settings and
   invalid values fail before mutation.
3. Schema references resolve against the local build catalogue, never through
   an endpoint network fetch.
4. Native validators are generated from the service schema. They support the
   schema subset used here: fixed object properties, bounded integers, booleans,
   patterned strings, and unique patterned string arrays. Extend the generator,
   both native validators, and parity tests before using a new schema construct.
5. Resource locations are installation-relative or explicit, never dependent on
   the caller's working directory.
6. Interactive and scheduled execution consume the same resolved configuration.
   Scheduling changes require reconciliation, not merely writing a file.
7. Arrays replace. Platform units, capabilities, and privileges remain explicit.
8. Configuration is not executable shell/PowerShell and contains no secrets.
9. Policy enforcement is separate. Do not claim that an editable profile is a
   managed/locked policy or that a profile is consumed unless the backend reads it.

The concrete contract and migration live in the
[Devbox guide](../services/devbox/README.md#configuration).
The [GhostBSD Remote Access contract](../services/ghostbsd-remote-access/README.md#build-and-configuration)
uses validated build-time profiles compiled into standalone backends; it does
not advertise a runtime JSON profile reader or persisted scheduler policy.

## Operation contract

Existing deployment interfaces remain supported rather than imposing a cosmetic
cross-platform command wrapper. Devbox's existing interfaces are:

| Intent | Windows | macOS |
| --- | --- | --- |
| Inspect desired configuration | `-ShowConfiguration` | `config` |
| Inspect health | Detection / worker `Status` | `status` |
| Reconcile desired state | Remediation | `install`, `repair` |
| Preview capacity changes | `-WhatIf` | `--dry-run resize` |
| Scheduled work | Worker `Mount`, `Backup` | `mount`, `backup` |

For every new backend or operation:

- Ship a read-only reporting path before apply.
- Preserve exit-code/output contracts used by management tools. Nonzero means
  failure or explicitly documented noncompliance; never disguise failure as a
  successful fallback.
- Require an explicit apply operation and preview support for new mutations.
- Validate identity, capability, paths, and desired state before disk mutation.
- Preserve existing data on retries; grow rather than reformat existing images.
- Serialize conflicting operations; release guards on errors and interruption.
- Stage output and rename on success. Cleanup failures must remain visible.
- Treat uninstall as removal of automation while retaining data. Purge is a
  distinct destructive operation, never a testing shortcut.
- Keep logs actionable and free of credentials, inventories, and unnecessary
  endpoint identifiers.

Windows detection keeps `COMPLIANT`, `REMEDIATION_REQUIRED`, and
`DETECTION_ERROR`; platform differences are not erased to produce identical
looking output.

GhostBSD Remote Access adds guest `status`/`--dry-run` and Windows operator
`Status`/`-WhatIf`, documented with their native privilege and exit boundaries.
Its firewall surface is reporting-only, and its Windows VirtualBox apply never
stops a VM or discards saved state.

## Native boundaries

Share configuration, folder policy, manifest rules, and validation fixtures.
Keep filesystem/image operations, backup consistency, identity, permissions, and
scheduler registration inside tested native adapters.

Windows uses elevated administration/SYSTEM, Task Scheduler, VHDX/ReFS, and VSS.
macOS uses the signed-in user, LaunchAgents, APFS sparsebundles, and detached
copies. A future Ubuntu adapter must choose its own image/filesystem and mount
authorization model; a systemd user timer does not grant mount privileges.

Specify supported OS versions and probe required capabilities. “Runs on Ubuntu”
for a contract test is not certification of an unimplemented Linux backend.

## Deployment contract

- Build self-contained, deterministic artifacts. Node.js and npm dependencies
  stay on the build machine, not the endpoint.
- Windows remediation embeds the one authored worker; consumers do not manually
  keep copies aligned. Signing, if required by deployment policy, occurs after
  generation; it must not be bypassed.
- macOS distributes a flat PKG. Its payload installs a CLI and configuration plus
  a user-session initialization agent, with no root postinstall data creation.
- User initialization waits until an eligible GUI login. An already logged-in
  user is not assumed to have loaded a newly installed global LaunchAgent.
- Sign release PKGs with Developer ID Installer, notarize using a keychain
  profile, staple, and verify. An unsigned test package is not a release.
- A compiled CLI/app also needs appropriate Developer ID Application
  signing, hardened runtime, and native validation.
- Keep credentials outside source and packages. Use existing approved signing
  identities and keychain profiles; do not auto-create or export certificates.
- MDM product support for arbitrary packages differs from managed-app lifecycle
  support. Use explicit package receipt/custom detection and tested uninstall.
- Packaging/root privileges do not bypass macOS privacy controls. Request only
  necessary permissions through supported management policy.

An `.app` is optional user interface. If added, it should share the tested engine
with an explicit CLI entry point. No-terminal detection cannot distinguish
Finder from a scheduler reliably; do not launch GUI from unattended jobs.

## Evolution

Keep native scripts for the native operations they implement and test.
The Rust workspace shares typed configuration and read-only planning across
implemented services. Node.js is appropriate for repository
tooling; distributing a Node application can bundle its runtime but does not
remove per-target packaging and signing requirements.

Neither language makes ReFS, APFS, VSS, launchd, or mount authorization portable.
Move one tested operation at a time; do not rewrite stable disk logic merely to
share a language. A Linux adapter or GUI needs its own scope and native test
evidence before being advertised.

## Rust framework

The [Cargo workspace](../Cargo.toml) implements the first shared Rust increment:
service discovery, canonical configuration resolution/validation, and read-only
planning for Devbox and GhostBSD Remote Access. Native mutations remain in their
tested platform adapters; the Rust CLI is not a resident agent or a wrapper
that silently shells out.

### Layers and configuration

- [Core](crates/endpoint-core/src/lib.rs) has no filesystem, subprocess, network,
  elevation or endpoint-mutation code. The CLI alone reads an explicitly named
  profile and writes structured output.
- Configuration has an opaque validated public type. Callers cannot directly
  deserialize/construct unchecked values and pass them into planning.
- Rust embeds the existing service JSON defaults, schemas and version metadata
  with `include_str!`; it does not keep a second defaults table or fetch schemas.
  Shared references resolve only against the embedded framework catalogue.
  External/unknown references fail; HTTP/file retrieval features are disabled.
- JSON Schema validation precedes merging and typed deserialization. Unknown
  keys/types/versions fail; arrays replace. Integral JSON numbers such as `1.0`
  retain JSON Schema integer semantics rather than failing solely on spelling.
  Remote-access line-break/port-collision safeguards match native artifact builds.
- Rust's desired values are not installed state. Persisted Devbox state and
  user-selected native runtime overrides are not silently loaded by the CLI.
  GhostBSD Remote Access profiles still require native artifact generation.
- Workspace lint rules forbid unsafe code and unchecked `unwrap`/`expect`.
  No async runtime, GUI framework, plugin loader, daemon or credential store is
  added. Dependencies are locked, and endpoints need no separately installed
  Rust runtime.

### CLI and plan contract

```text
cargo run --locked -- services
cargo run --locked -- validate --service devbox --config profile.json
cargo run --locked -- configuration --service ghostbsd-remote-access --config profile.json
cargo run --locked -- plan --service ghostbsd-remote-access --platform ghostbsd --operation apply --user desktop
```

Successful commands emit JSON on stdout; errors go to stderr with exit 2.
No arguments show usage and exit 2; `--help`/`--version` exit 0.
Missing explicit files, unsupported backends, invalid profiles and missing or
unsafe remote-access accounts never select a successful fallback.

Plan schema 1 reports `mutatesEndpoint: false`, `executionSupported: false`,
the desired configuration, native artifact-relative entry point, interpreter,
argument arrays, apply privilege and limitations. Argument arrays are data,
not a joined shell command. A consumer must locate its matching generated
service package; the planner never guesses an installation directory or runs it.
Status planning does not execute detection or claim a compliant endpoint.
Remote-account checks here validate syntax/non-root intent; the native guest
still owns actual account/home lookup and permission checks.

Apply plans include native preview flags only where implemented: Windows
`-WhatIf` or GhostBSD `--dry-run`. macOS's resize-only preview is not presented
as a complete install preview. A remote-access profile path or non-default
in-memory configuration sets
`requiresArtifactRebuild: true` instead of inventing a runtime JSON flag.
Linux backend combinations fail even though the read-only CLI itself can run
on Linux. Native Windows status words/exit codes remain owned by their adapters.

### Build and release boundaries

The [pinned SDK](../rust-toolchain.toml), formatter, Clippy and locked dependencies
are build-machine tools. Use the [contributor checks](../CONTRIBUTING.md#rust-checks);
CI runs Rust/native contracts and release compilation on Windows, macOS and
Ubuntu. That is not GhostBSD/hypervisor or disk-operation certification.
Native mutation entry points, privileges, installed paths and data formats
are unchanged by this increment.

Build release binaries with `cargo build --workspace --release --locked`.
Distribute the platform-native binary with the toolkit LICENSE and NOTICE
and the required third-party license notices for its locked dependencies;
the runtime embeds public contracts, not a checkout or private profile.
This is not an installer, signed macOS app, notarized package or automatic
deployment. Apply the existing platform signing/deployment gates before fleet
distribution; do not bypass them because an unsigned CLI runs locally.
