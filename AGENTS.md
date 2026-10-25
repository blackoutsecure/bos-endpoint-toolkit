# Repository guidance

## Scope and ownership

This is a public Apache-2.0 endpoint automation toolkit, not an application,
compliance scanner, or Microsoft Dev Box client. Devbox is implemented on
Windows and macOS only. See [the architecture](framework/README.md) and
[service contract](services/devbox/README.md).

Use `services/<service>/<platform>/`. Keep service/platform READMEs beside code;
there is no separate docs index. Reusable contracts and schema definitions live
in `framework/`; build-only tooling lives in `tools/`.

Edit authoring sources and shared defaults/schema, not generated `output/`.
The build embeds native configuration validators/defaults and the single
authored Windows worker. Do not reintroduce a manually maintained worker copy or
hard-coded default tables in several scripts.

The shared [Rust framework](framework/README.md#rust-framework) lives under
`framework/crates/`. Its core resolves canonical configuration and produces
read-only plans; it does not execute native adapters or elevate. Preserve this
boundary and keep defaults/schemas in their existing service-owned JSON sources.

## Build and validation

Use the exact commands in [Contributing](CONTRIBUTING.md#local-checks):

```text
npm ci --ignore-scripts
npm test
npm run check
```

Node.js 22.16+, Ajv, and Markdownlint are build/test tools only. Endpoints need no
shared runtime. Source templates deliberately require generation before
deployment. Tests extract native helper functions or use generated scripts.

For Rust or embedded contract changes, also run the
[Rust checks](CONTRIBUTING.md#rust-checks): formatting, Clippy with warnings
denied, workspace tests and a locked release build. Preserve the pinned toolchain
and Cargo.lock. Rust builds require a complete native linker SDK; never add
private workstation linker paths or nightly bypasses to repository configuration.

The CI matrix runs portable build/contract checks on Ubuntu, Windows, and macOS,
Windows PowerShell 5.1 mocks on Windows, and native configuration/unsigned
packaging on macOS. It does not install Devbox or prove native disk operations.
Run documented disposable native integration tests before fleet rollout.

For PowerShell changes, check AST parse errors, run configuration/storage mocks
in separate processes, and run PSScriptAnalyzer when available. For Bash changes,
run syntax checks and ShellCheck. Lint workflow changes with yamllint/actionlint.
Never report a skipped/unavailable native check as passed.

## Deployed contracts

- Defaults: 100 GiB Windows, 100 decimal GB macOS, 02:00 local backup, retention
  14, and twelve workspace folders. Units are intentionally different.
- Desired configuration schema 1 is separate from runtime state schema 3.
  Unknown keys/types/versions fail. Defaults and schema share one source;
  generated native descriptors must cover every configured leaf.
- Windows detection and remediation share configuration. Preserve the
  `COMPLIANT`, `REMEDIATION_REQUIRED`, and `DETECTION_ERROR` vocabulary.
- Windows worker runtime state and tasks stay under ProgramData; live data
  remains user-scoped. Generated tasks pass the worker state root explicitly.
- macOS preserves user support paths, sparsebundle format, and per-user
  mount/backup agents. Scheduled jobs use persisted desired configuration.
- New macOS backup metadata is schema 5 with relative-path hashes. Schema 4
  hashes remain legacy absolute-path hashes; never relabel them or silently
  skip a failed comparison.
- macOS PKG installation stages machine-owned files and a user-session
  initializer, not root-run workspace creation. Signing credentials stay outside
  source; unsigned artifacts are validation-only.

## Safety boundaries

- Windows apply/worker is elevated or SYSTEM; macOS actively refuses root.
  Preserve that asymmetry. Do not add sudo or broaden task/agent principals.
- Never run apply, purge, retention, disk creation, or registration against a
  production endpoint or a developer's configured workstation.
- Status/configuration/detection remain read-only. Windows mutations require
  `ShouldProcess`; new shell mutation modes require `--dry-run`. Existing macOS
  preview is resize-only, not a full install/repair/uninstall preview.
- Preserve disk identity validation, no-shrink/no-reformat rules, mutexes/locks,
  interruption cleanup, strict error handling, and atomic staging.
- Never hide failure with a successful fallback or broad error suppression.
- Preserve installed/data paths during source reorganization; document external
  URL migrations. Add OS/runtime/GUI components only when implemented and tested.
- Do not commit output, private configuration, inventories, real identifiers,
  logs, images, backups, keys, certificates, or credentials.
- Changes to defaults, privileges, schemas, installed paths, or first-time
  backends need explicit approval and migration evidence.

## Organization conventions

`dev` is the development/default branch. `main` is promoted stable runtime;
promotion/tags are hub-managed. Do not push directly to main or move tags.
Pin remote step actions to full SHAs with version comments. Do not bypass
required reviews/checks.

Files carrying managed-file-sync markers must be changed at their owning hub or
catalogue source, not in generated blocks here. Preserve the Apache-2.0 LICENSE
and NOTICE. Repo-specific guidance belongs here, not in inherited org policy.
