# Contributing

## Organization

- Use `scripts/<capability>/<os>/`, with a capability README and an OS README.
- Keep related detection, remediation, and worker scripts together as one
  deployable package. Give an independent task its own folder only when useful.
- Put required templates or supporting files beside their owning task; resolve
  them from the script location rather than assuming the caller's working
  directory.
- Document external prerequisites instead of checking in installed dependencies.
  Introduce a shared helper only when there is real reuse and a documented
  interface.
- Add OS folders only for implemented platforms, not as placeholders.
- Keep capability documentation beside the code. Use [docs/README.md](docs/README.md)
  as the index and `docs/` for cross-capability runbooks, avoiding duplicate
  configuration tables.

## Script requirements

- Keep scripts platform-specific unless their implementation is genuinely
  portable.
- State supported operating-system versions and required privileges.
- Make state-changing work opt-in through an explicit flag where practical.
- Never log secrets, access tokens, personal data, or internal URLs.
- Ensure repeated runs converge on the intended state.
- New state-changing shell scripts must support `--dry-run`; PowerShell scripts
  must use `SupportsShouldProcess` and `-WhatIf`. macOS Devbox supports only
  `--dry-run resize`, not an install/repair preview. Use `status` for read-only
  inspection and a disposable target for apply-path validation.

## Validation

Before submitting a change:

- Parse PowerShell scripts with `Invoke-ScriptAnalyzer` when available.
- Parse Bash scripts with `bash -n` and run ShellCheck when available.
- Exercise preview modes where supported, and apply modes only on a disposable
  endpoint or scratch user account.
- Update the script documentation when behavior or prerequisites change.
- Run the [macOS capacity tests](scripts/devbox/macos/README.md#capacity-regression-tests)
  and [Windows capacity tests](scripts/devbox/windows/README.md#capacity-regression-tests)
  when changing Devbox sizing. The Windows mocks are not a substitute for a
  disposable Windows 11 VHDX/ReFS integration test.
- For path-only moves, verify that script contents and executable permissions
  remain unchanged; update links, examples, and deployment-path references.
  Do not run an installation just to validate a directory move.
