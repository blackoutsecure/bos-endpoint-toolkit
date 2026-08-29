# Contributing

## Script requirements

- Keep scripts platform-specific unless their implementation is genuinely
  portable.
- State supported operating-system versions and required privileges.
- Make state-changing work opt-in through an explicit flag where practical.
- Never log secrets, access tokens, personal data, or internal URLs.
- Ensure repeated runs converge on the intended state.

## Validation

Before submitting a change:

- Parse PowerShell scripts with `Invoke-ScriptAnalyzer` when available.
- Parse POSIX shell scripts with `bash -n` and run ShellCheck when available.
- Exercise both dry-run and apply modes where the script supports them.
- Update the script documentation when behavior or prerequisites change.
