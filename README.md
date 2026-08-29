# Blackout Secure Endpoint Toolkit

Cross-platform scripts and operational guidance for managing Windows, Linux,
and macOS endpoints. The toolkit is suitable for Intune-adjacent administration
and general endpoint maintenance; it does not require a specific management
platform.

## Layout

```text
scripts/
  windows/  PowerShell scripts for Windows endpoints
  linux/    POSIX shell scripts for Linux endpoints
  macos/    POSIX shell scripts for macOS endpoints
  shared/   Cross-platform helpers and documentation
docs/       Platform and operational guidance
```

Keep each script focused on one operational task. Scripts should state their
supported platforms, required privileges, inputs, and whether they are safe to
run repeatedly.

## Adding a script

1. Put the script in the matching platform directory.
2. Use a descriptive, kebab-case name such as `collect-device-inventory.ps1`.
3. Include `-WhatIf` support for PowerShell scripts that change a device.
4. Include `--dry-run` support for shell scripts that change a device.
5. Document prerequisites, expected output, and rollback considerations in the
   script header or a nearby Markdown file.

## Conventions

- Do not embed credentials, tenant IDs, device IDs, or internal endpoints.
- Validate inputs before making changes.
- Prefer idempotent operations and clear, actionable error messages.
- Avoid installing dependencies without an explicit option or documented
  prerequisite.
- Test destructive operations in a non-production endpoint first.
