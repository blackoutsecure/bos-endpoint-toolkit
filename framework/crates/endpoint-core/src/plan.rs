use std::{path::Path, str::FromStr};

use serde::Serialize;

use crate::configuration::ConfigurationValues;
use crate::{Configuration, Error, Platform, Service};

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Operation {
    Status,
    Apply,
}

impl FromStr for Operation {
    type Err = String;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        match value {
            "status" => Ok(Self::Status),
            "apply" => Ok(Self::Apply),
            _ => Err("operation must be status or apply".to_owned()),
        }
    }
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Invocation {
    pub artifact: &'static str,
    pub interpreter: &'static str,
    pub arguments: Vec<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Plan {
    pub schema_version: u8,
    pub service: Service,
    pub platform: Platform,
    pub requested_operation: Operation,
    pub mutates_endpoint: bool,
    pub execution_supported: bool,
    pub configuration: Configuration,
    pub configuration_delivery: ConfigurationDelivery,
    pub requires_artifact_rebuild: bool,
    pub apply_privilege: &'static str,
    pub native_inspection: Invocation,
    pub native_preview: Option<Invocation>,
    pub warnings: Vec<&'static str>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum ConfigurationDelivery {
    NativeRuntimeProfile,
    BuildTimeProfile,
}

fn arguments(values: &[&str]) -> Vec<String> {
    values.iter().map(|value| (*value).to_owned()).collect()
}

fn invocation(
    artifact: &'static str,
    interpreter: &'static str,
    arguments: Vec<String>,
) -> Invocation {
    Invocation {
        artifact,
        interpreter,
        arguments,
    }
}

fn account(value: Option<&str>) -> Result<&str, Error> {
    let value = value.ok_or(Error::InvalidAccount)?;
    let mut bytes = value.bytes();
    if value.len() > 32
        || value == "root"
        || !bytes
            .next()
            .is_some_and(|first| first.is_ascii_lowercase() || first == b'_')
        || !bytes
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || b"_-".contains(&byte))
    {
        return Err(Error::InvalidAccount);
    }
    Ok(value)
}

pub fn plan(
    configuration: Configuration,
    platform: Platform,
    operation: Operation,
    user: Option<&str>,
    profile_path: Option<&Path>,
) -> Result<Plan, Error> {
    let service = configuration.service();
    if !service.platforms().contains(&platform) {
        return Err(Error::UnsupportedBackend { service, platform });
    }
    if service == Service::Devbox && user.is_some() {
        return Err(Error::UnexpectedAccount);
    }
    let profile = profile_path
        .map(|path| path.to_str().ok_or(Error::NonUnicodePath))
        .transpose()?;
    let mut warnings = vec![
        "This is a desired-configuration plan, not a live endpoint observation or an execution authorization.",
        "Rust does not execute these adapters, elevate privileges, or read installed desired state.",
    ];
    let (native_inspection, native_preview, apply_privilege, configuration_delivery) = match (
        configuration.values(),
        platform,
    ) {
        (ConfigurationValues::Devbox(_), Platform::Windows) => {
            let mut inspect = Vec::new();
            let mut preview = arguments(&["-WhatIf"]);
            if let Some(path) = profile {
                inspect.extend(arguments(&["-DesiredConfigPath", path]));
                preview.extend(arguments(&["-DesiredConfigPath", path]));
            }
            (
                invocation("windows/detect-devbox.ps1", "powershell.exe", inspect),
                Some(invocation(
                    "windows/remediate-devbox.ps1",
                    "powershell.exe",
                    preview,
                )),
                "Administrator or SYSTEM",
                ConfigurationDelivery::NativeRuntimeProfile,
            )
        }
        (ConfigurationValues::Devbox(_), Platform::Macos) => {
            let mut inspect = Vec::new();
            if let Some(path) = profile {
                inspect.extend(arguments(&["--config", path]));
            }
            inspect.push("status".to_owned());
            if operation == Operation::Apply {
                warnings.push("macOS has no complete install preview; --dry-run is resize-only. No install preview is fabricated.");
            }
            (
                invocation("macos/manage-devbox.sh", "/bin/bash", inspect),
                None,
                "Signed-in user; refuses root",
                ConfigurationDelivery::NativeRuntimeProfile,
            )
        }
        (ConfigurationValues::GhostbsdRemoteAccess(values), Platform::Ghostbsd) => {
            let user = account(user)?;
            let mut inspect = arguments(&["--user", user, "--platform", values.platform.as_str()]);
            let mut preview = inspect.clone();
            inspect.push("status".to_owned());
            preview.extend(arguments(&["--dry-run", "apply"]));
            (
                invocation(
                    "ghostbsd/manage-remote-access.sh",
                    "/usr/local/bin/bash",
                    inspect,
                ),
                Some(invocation(
                    "ghostbsd/manage-remote-access.sh",
                    "/usr/local/bin/bash",
                    preview,
                )),
                "Approved root/sudo session on the guest; no NOPASSWD grant",
                ConfigurationDelivery::BuildTimeProfile,
            )
        }
        (ConfigurationValues::GhostbsdRemoteAccess(values), Platform::Windows) => {
            let user = account(user)?;
            let base = arguments(&[
                "-UserName",
                user,
                "-ComputerName",
                &values.host_name,
                "-SshPort",
                &values.host_ssh_port.to_string(),
                "-Platform",
                values.platform.as_str(),
            ]);
            let mut inspect = arguments(&["-Mode", "Status"]);
            inspect.extend(base.clone());
            let mut preview = arguments(&["-Mode", "Apply", "-WhatIf"]);
            preview.extend(base);
            (
                invocation(
                    "windows/manage-remote-access.ps1",
                    "powershell.exe",
                    inspect,
                ),
                Some(invocation(
                    "windows/manage-remote-access.ps1",
                    "powershell.exe",
                    preview,
                )),
                "Normal Windows operator; approved guest sudo for apply",
                ConfigurationDelivery::BuildTimeProfile,
            )
        }
        _ => return Err(Error::UnsupportedBackend { service, platform }),
    };
    let requires_artifact_rebuild = service == Service::GhostbsdRemoteAccess && profile.is_some();
    if requires_artifact_rebuild {
        warnings.push("Rebuild this service's native artifacts with the same profile before using these adapter arguments; native Remote Access does not consume runtime JSON.");
    }
    Ok(Plan {
        schema_version: 1,
        service,
        platform,
        requested_operation: operation,
        mutates_endpoint: false,
        execution_supported: false,
        configuration,
        configuration_delivery,
        requires_artifact_rebuild,
        apply_privilege,
        native_inspection,
        native_preview: (operation == Operation::Apply)
            .then_some(native_preview)
            .flatten(),
        warnings,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{resolve_configuration, services};

    #[test]
    fn catalogue_only_advertises_real_native_backends() -> Result<(), Error> {
        let catalogue = services()?;
        assert_eq!(catalogue.len(), 2);
        for descriptor in catalogue {
            assert!(!descriptor.rust_execution_supported);
            for platform in [
                Platform::Windows,
                Platform::Macos,
                Platform::Ghostbsd,
                Platform::Linux,
            ] {
                let result = plan(
                    resolve_configuration(descriptor.name, None)?,
                    platform,
                    Operation::Status,
                    (descriptor.name == Service::GhostbsdRemoteAccess).then_some("fixture"),
                    None,
                );
                assert_eq!(result.is_ok(), descriptor.platforms.contains(&platform));
            }
        }
        Ok(())
    }

    #[test]
    fn apply_plans_never_mutate_or_claim_execution() -> Result<(), Error> {
        for service in Service::ALL {
            for platform in service.platforms() {
                let plan = plan(
                    resolve_configuration(service, None)?,
                    *platform,
                    Operation::Apply,
                    (service == Service::GhostbsdRemoteAccess).then_some("fixture"),
                    None,
                )?;
                assert!(!plan.mutates_endpoint);
                assert!(!plan.execution_supported);
                if let Some(preview) = plan.native_preview {
                    assert!(
                        preview
                            .arguments
                            .iter()
                            .any(|value| value == "-WhatIf" || value == "--dry-run")
                    );
                } else {
                    assert_eq!(*platform, Platform::Macos);
                    assert!(
                        plan.warnings
                            .iter()
                            .any(|value| value.contains("resize-only"))
                    );
                }
            }
        }
        Ok(())
    }

    #[test]
    fn remote_accounts_are_explicit_and_validated() -> Result<(), Error> {
        for user in [
            None,
            Some("root"),
            Some(""),
            Some("-oBad"),
            Some("user;command"),
            Some("user\n"),
        ] {
            assert!(matches!(
                plan(
                    resolve_configuration(Service::GhostbsdRemoteAccess, None)?,
                    Platform::Windows,
                    Operation::Apply,
                    user,
                    None
                ),
                Err(Error::InvalidAccount)
            ));
        }
        assert!(matches!(
            plan(
                resolve_configuration(Service::Devbox, None)?,
                Platform::Windows,
                Operation::Status,
                Some("fixture"),
                None
            ),
            Err(Error::UnexpectedAccount)
        ));
        Ok(())
    }

    #[test]
    fn remote_profiles_require_native_artifact_rebuild_not_fake_runtime_flags() -> Result<(), Error>
    {
        let plan = plan(
            resolve_configuration(
                Service::GhostbsdRemoteAccess,
                Some(r#"{"schemaVersion":1,"rdpPort":3390}"#),
            )?,
            Platform::Ghostbsd,
            Operation::Apply,
            Some("fixture"),
            Some(Path::new("profile.json")),
        )?;
        assert!(plan.requires_artifact_rebuild);
        assert!(
            !plan
                .native_inspection
                .arguments
                .iter()
                .any(|value| value == "--config")
        );
        assert!(matches!(
            plan.configuration_delivery,
            ConfigurationDelivery::BuildTimeProfile
        ));
        Ok(())
    }

    #[test]
    fn devbox_inspection_preserves_explicit_profile_paths_as_one_argument() -> Result<(), Error> {
        let path = Path::new("profiles with spaces/desired.json");
        for platform in Service::Devbox.platforms() {
            let plan = plan(
                resolve_configuration(Service::Devbox, None)?,
                *platform,
                Operation::Apply,
                None,
                Some(path),
            )?;
            assert!(
                plan.native_inspection
                    .arguments
                    .iter()
                    .any(|value| value == "profiles with spaces/desired.json")
            );
            assert!(!plan.requires_artifact_rebuild);
        }
        Ok(())
    }
}
