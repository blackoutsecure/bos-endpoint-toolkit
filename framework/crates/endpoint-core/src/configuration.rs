use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::{Error, Service};

const COMMON_SCHEMA: &str = include_str!("../../../schemas/configuration.schema.json");

#[derive(Debug, Serialize)]
#[serde(transparent)]
pub struct Configuration(ConfigurationValues);

#[derive(Debug, Serialize)]
#[serde(untagged)]
pub(crate) enum ConfigurationValues {
    Devbox(DevboxConfiguration),
    GhostbsdRemoteAccess(RemoteAccessConfiguration),
}

impl Configuration {
    pub(crate) const fn values(&self) -> &ConfigurationValues {
        &self.0
    }

    pub const fn service(&self) -> Service {
        match &self.0 {
            ConfigurationValues::Devbox(_) => Service::Devbox,
            ConfigurationValues::GhostbsdRemoteAccess(_) => Service::GhostbsdRemoteAccess,
        }
    }

    pub const fn schema_version(&self) -> u8 {
        match &self.0 {
            ConfigurationValues::Devbox(configuration) => configuration.schema_version,
            ConfigurationValues::GhostbsdRemoteAccess(configuration) => {
                configuration.schema_version
            }
        }
    }
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct DevboxConfiguration {
    schema_version: u8,
    name: String,
    backup_hour: u8,
    backup_minute: u8,
    retention: u32,
    workspace_directories: Vec<String>,
    windows: WindowsDevboxConfiguration,
    macos: MacosDevboxConfiguration,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WindowsDevboxConfiguration {
    #[serde(rename = "sizeGiB")]
    size_gib: u32,
    volume_label: String,
    preferred_drive_letters: Vec<char>,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct MacosDevboxConfiguration {
    #[serde(rename = "sizeGB")]
    size_gb: u32,
    volume_label: String,
    launchd_prefix: String,
    repair_mount: bool,
    hide_volume: bool,
    backup_if_overdue_hours: u32,
    auto_restore: bool,
    restore_search_all_machines: bool,
    verify_backup_hash: bool,
    allow_backup_without_metadata: bool,
    validate_backup_mount: bool,
    verify_post_backup_hash: bool,
    conditional_install_backup: bool,
    backup_after_restore: bool,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct RemoteAccessConfiguration {
    schema_version: u8,
    pub(crate) platform: GuestPlatform,
    ssh_port: u16,
    rdp_port: u16,
    pub(crate) host_name: String,
    pub(crate) host_ssh_port: u16,
    local_rdp_port: u16,
    #[serde(rename = "videoMemoryMiB")]
    video_memory_mib: u16,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub(crate) enum GuestPlatform {
    Auto,
    Virtualbox,
    Hyperv,
    Physical,
}

impl GuestPlatform {
    pub(crate) const fn as_str(&self) -> &'static str {
        match self {
            Self::Auto => "auto",
            Self::Virtualbox => "virtualbox",
            Self::Hyperv => "hyperv",
            Self::Physical => "physical",
        }
    }
}

fn documents(service: Service) -> (&'static str, &'static str) {
    match service {
        Service::Devbox => (
            include_str!("../../../../services/devbox/config/schema.json"),
            include_str!("../../../../services/devbox/config/defaults.json"),
        ),
        Service::GhostbsdRemoteAccess => (
            include_str!("../../../../services/ghostbsd-remote-access/config/schema.json"),
            include_str!("../../../../services/ghostbsd-remote-access/config/defaults.json"),
        ),
    }
}

fn localize_references(value: &mut Value, common: &Value) -> Result<(), Error> {
    match value {
        Value::Object(object) => {
            if let Some(reference) = object.remove("$ref") {
                let reference = reference.as_str().ok_or_else(|| {
                    Error::EmbeddedContract("a schema reference is not a string".to_owned())
                })?;
                let (id, pointer) = reference
                    .split_once('#')
                    .ok_or_else(|| Error::UnsupportedReference(reference.to_owned()))?;
                let common_id = common.get("$id").and_then(Value::as_str).ok_or_else(|| {
                    Error::EmbeddedContract(
                        "the embedded catalogue has no schema identifier".to_owned(),
                    )
                })?;
                if id != common_id || !pointer.starts_with("/$defs/") {
                    return Err(Error::UnsupportedReference(reference.to_owned()));
                }
                let target = common
                    .pointer(pointer)
                    .and_then(Value::as_object)
                    .filter(|target| !target.contains_key("$ref"))
                    .ok_or_else(|| Error::UnsupportedReference(reference.to_owned()))?;
                let mut replacement = target.clone();
                replacement.extend(std::mem::take(object));
                *object = replacement;
            }
            for child in object.values_mut() {
                localize_references(child, common)?;
            }
        }
        Value::Array(array) => {
            for child in array {
                localize_references(child, common)?;
            }
        }
        _ => {}
    }
    Ok(())
}

fn merge(base: &mut Value, profile: &Value) {
    match (base, profile) {
        (Value::Object(base), Value::Object(profile)) => {
            for (key, value) in profile {
                merge(base.entry(key.clone()).or_insert(Value::Null), value);
            }
        }
        (base, profile) => *base = profile.clone(),
    }
}

fn normalize_integers(value: &mut Value, schema: &Value) -> Result<(), Error> {
    if schema["type"] == "integer" && value.is_f64() {
        let number = value.as_f64().ok_or_else(|| {
            Error::EmbeddedContract("a validated integer cannot be represented".to_owned())
        })?;
        *value = if number == 0.0 {
            Value::from(0)
        } else {
            serde_json::from_str(&format!("{number:.0}"))?
        };
    } else if let (Some(object), Some(properties)) = (
        value.as_object_mut(),
        schema.get("properties").and_then(Value::as_object),
    ) {
        for (key, child) in object {
            if let Some(property) = properties.get(key) {
                normalize_integers(child, property)?;
            }
        }
    }
    Ok(())
}

pub fn resolve_configuration(
    service: Service,
    profile: Option<&str>,
) -> Result<Configuration, Error> {
    let (schema, defaults) = documents(service);
    let mut schema: Value = serde_json::from_str(schema)?;
    localize_references(&mut schema, &serde_json::from_str(COMMON_SCHEMA)?)?;
    let validator = jsonschema::validator_for(&schema)
        .map_err(|error| Error::EmbeddedContract(error.to_string()))?;
    let validate = |value: &Value| -> Result<(), Error> {
        let errors: Vec<_> = validator
            .iter_errors(value)
            .map(|error| error.to_string())
            .collect();
        if errors.is_empty() {
            Ok(())
        } else {
            Err(Error::Configuration {
                service,
                details: errors.join("; "),
            })
        }
    };
    let mut resolved: Value = serde_json::from_str(defaults)?;
    validate(&resolved)?;
    if let Some(profile) = profile {
        let profile = serde_json::from_str(profile)?;
        validate(&profile)?;
        merge(&mut resolved, &profile);
    }
    validate(&resolved)?;
    normalize_integers(&mut resolved, &schema)?;
    match service {
        Service::Devbox => Ok(Configuration(ConfigurationValues::Devbox(
            serde_json::from_value(resolved)?,
        ))),
        Service::GhostbsdRemoteAccess => {
            if resolved.as_object().is_some_and(|object| {
                object
                    .values()
                    .filter_map(Value::as_str)
                    .any(|value| value.contains(['\r', '\n']))
            }) {
                return Err(Error::Configuration {
                    service,
                    details: "strings cannot contain line breaks".to_owned(),
                });
            }
            let configuration: RemoteAccessConfiguration = serde_json::from_value(resolved)?;
            if configuration.ssh_port == configuration.rdp_port {
                return Err(Error::Configuration {
                    service,
                    details: "SSH and RDP require different guest ports".to_owned(),
                });
            }
            Ok(Configuration(ConfigurationValues::GhostbsdRemoteAccess(
                configuration,
            )))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn both_typed_defaults_equal_the_authored_json() -> Result<(), Error> {
        for service in Service::ALL {
            let configuration = resolve_configuration(service, None)?;
            let expected: Value = serde_json::from_str(documents(service).1)?;
            assert_eq!(serde_json::to_value(configuration)?, expected);
        }
        Ok(())
    }

    #[test]
    fn partial_profiles_preserve_units_and_replace_arrays() -> Result<(), Error> {
        let profile = json!({
            "schemaVersion": 1, "retention": 21, "workspaceDirectories": ["repos"],
            "macos": {"hideVolume": true}
        });
        let resolved = serde_json::to_value(resolve_configuration(
            Service::Devbox,
            Some(&profile.to_string()),
        )?)?;
        assert_eq!(resolved["windows"]["sizeGiB"], 100);
        assert_eq!(resolved["macos"]["sizeGB"], 100);
        assert_eq!(resolved["macos"]["hideVolume"], true);
        assert_eq!(resolved["retention"], 21);
        assert_eq!(resolved["workspaceDirectories"], json!(["repos"]));
        Ok(())
    }

    #[test]
    fn invalid_profiles_never_fall_back_to_defaults() {
        for service in Service::ALL {
            for profile in [
                "null",
                "false",
                "[]",
                "{}",
                r#"{"schemaVersion":2}"#,
                r#"{"schemaVersion":"1"}"#,
                r#"{"schemaVersion":1,"unknown":true}"#,
                "{",
            ] {
                assert!(
                    resolve_configuration(service, Some(profile)).is_err(),
                    "{service}: {profile}"
                );
            }
        }
    }

    #[test]
    fn json_schema_integer_numbers_do_not_depend_on_json_spelling() -> Result<(), Error> {
        let configuration = resolve_configuration(
            Service::Devbox,
            Some(
                r#"{"schemaVersion":1.0,"retention":1e1,"backupHour":-0.0,"backupMinute":-0,"windows":{"sizeGiB":100.0}}"#,
            ),
        )?;
        let value = serde_json::to_value(configuration)?;
        assert_eq!(value["schemaVersion"], 1);
        assert_eq!(value["retention"], 10);
        assert_eq!(value["backupHour"], 0);
        assert_eq!(value["backupMinute"], 0);
        assert_eq!(value["windows"]["sizeGiB"], 100);
        Ok(())
    }

    #[test]
    fn canonical_devbox_constraints_are_enforced() {
        let invalid = [
            json!({"schemaVersion":1,"name":"../escape"}),
            json!({"schemaVersion":1,"backupHour":24}),
            json!({"schemaVersion":1,"retention":0}),
            json!({"schemaVersion":1,"windows":{"sizeGiB":49}}),
            json!({"schemaVersion":1,"windows":{"preferredDriveLetters":["v"]}}),
            json!({"schemaVersion":1,"macos":{"sizeGB":65537}}),
            json!({"schemaVersion":1,"macos":{"hideVolume":"true"}}),
            json!({"schemaVersion":1,"workspaceDirectories":["repos","repos"]}),
            json!({"schemaVersion":1,"workspaceDirectories":["../repos"]}),
            json!({"schemaVersion":1,"workspaceDirectories":[]}),
        ];
        for profile in invalid {
            assert!(resolve_configuration(Service::Devbox, Some(&profile.to_string())).is_err());
        }
    }

    #[test]
    fn remote_access_rejects_invalid_profiles_and_port_collisions() {
        let invalid = [
            json!({"schemaVersion":1,"platform":"linux"}),
            json!({"schemaVersion":1,"hostName":"-oProxyCommand=bad"}),
            json!({"schemaVersion":1,"hostName":"localhost\n"}),
            json!({"schemaVersion":1,"sshPort":3389}),
            json!({"schemaVersion":1,"rdpPort":0}),
            json!({"schemaVersion":1,"localRdpPort":65536}),
            json!({"schemaVersion":1,"videoMemoryMiB":257}),
        ];
        for profile in invalid {
            assert!(
                resolve_configuration(Service::GhostbsdRemoteAccess, Some(&profile.to_string()))
                    .is_err()
            );
        }
    }

    #[test]
    fn remote_access_accepts_boundaries_and_keeps_other_defaults() -> Result<(), Error> {
        let profile = json!({
            "schemaVersion": 1, "platform": "hyperv",
            "hostSshPort": 1, "localRdpPort": 65535, "rdpPort": 3390
        });
        let value = serde_json::to_value(resolve_configuration(
            Service::GhostbsdRemoteAccess,
            Some(&profile.to_string()),
        )?)?;
        assert_eq!(value["platform"], "hyperv");
        assert_eq!(value["hostSshPort"], 1);
        assert_eq!(value["localRdpPort"], 65535);
        assert_eq!(value["rdpPort"], 3390);
        assert_eq!(value["sshPort"], 22);
        Ok(())
    }

    #[test]
    fn references_cannot_escape_the_embedded_catalogue() -> Result<(), Error> {
        let common = serde_json::from_str(COMMON_SCHEMA)?;
        for reference in [
            "https://example.invalid/schema",
            "file:///private/schema.json",
            "urn:blackoutsecure:endpoint-toolkit:configuration:1#/$defs/missing",
        ] {
            assert!(localize_references(&mut json!({"$ref":reference}), &common).is_err());
        }
        Ok(())
    }
}
