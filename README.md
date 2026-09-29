# Blackout Secure Endpoint Toolkit

[![Made by BlackoutSecure](https://img.shields.io/badge/made%20by-BlackoutSecure-1f1f1f)](https://github.com/blackoutsecure)

Cross-platform scripts and operational guidance for managing Windows, Linux,
and macOS endpoints. The toolkit is suitable for Intune-adjacent administration
and general endpoint maintenance; it does not require a specific management
platform.

## Layout

```text
scripts/
  devbox/
    README.md       Capability overview and deployment entry points
    windows/        Related PowerShell scripts and Windows guidance
    macos/          Bash management script and macOS guidance
docs/               Documentation index and cross-capability runbooks
```

Organize by **capability/service, then operating system**:
`scripts/<capability>/<os>/`. Keep scripts that are deployed together in the same
package, with documentation and any required supporting files alongside them.
An independent task can have its own subfolder when it needs separate
documentation, templates, or dependencies; a one-file folder for every related
script is not required.

Keep each script focused on one operational task. Scripts should state their
supported platforms, required privileges, inputs, and whether they are safe to
run repeatedly.

## Capabilities

| Capability | Purpose | Implemented platforms |
| --- | --- | --- |
| [Devbox](scripts/devbox/README.md) | Disk-image-backed development workspaces, mounting, and backups | [Windows](scripts/devbox/windows/README.md), [macOS](scripts/devbox/macos/README.md) |

Linux support is a repository goal, but no Linux scripts are implemented yet.
See the [documentation index](docs/README.md) for platform details and operational
guidance.

Devbox defaults to a **100 GB** virtual disk on both implemented platforms.
Increasing its configured size grows the existing image and filesystem during
install/repair; it does not recreate the workspace. Automatic shrinking is
refused. See the platform guides for size units, previews, and backup precautions.

## Adding a script

1. Choose a capability and put the script in `scripts/<capability>/<os>/`.
2. Use a descriptive, kebab-case name such as `collect-device-inventory.ps1`.
3. Include `-WhatIf` support for PowerShell scripts that change a device.
4. Include `--dry-run` support for shell scripts that change a device.
5. Keep the capability overview in its README and platform prerequisites,
   commands, expected output, and rollback in the OS README and script headers.
6. Place necessary task-specific resources beside their owner and document how
   they are resolved. Document external dependencies rather than committing
   installed packages or downloaded tools.
7. Add shared code only for demonstrated reuse, with an explicit calling
   contract. Do not create placeholder OS, shared, or dependency folders.
8. Link the capability from this page and the documentation index. See
   [Contributing](CONTRIBUTING.md) for validation requirements.

macOS Devbox supports `--dry-run resize` for capacity previews, not a full
install/repair preview; see its [safe inspection guidance](scripts/devbox/macos/README.md#prerequisites-and-safe-inspection).

## Existing deployment references

Devbox sources have moved from the former OS-first directories into
`scripts/devbox/<os>/`. Update any external deployment source paths or raw-file
URLs accordingly. Installed runtime/data locations are unchanged; see the
[migration note](scripts/devbox/README.md#repository-path-migration).

## Conventions

- Do not embed credentials, tenant IDs, device IDs, or internal endpoints.
- Validate inputs before making changes.
- Prefer idempotent operations and clear, actionable error messages.
- Avoid installing dependencies without an explicit option or documented
  prerequisite.
- Test destructive operations in a non-production endpoint first.
