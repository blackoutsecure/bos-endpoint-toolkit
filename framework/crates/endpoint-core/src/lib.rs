//! Shared service contracts. This crate performs no filesystem, process, network,
//! privilege, or endpoint mutation operations.

mod configuration;
mod plan;

use std::{collections::BTreeMap, fmt, str::FromStr};

use serde::{Deserialize, Serialize};
use thiserror::Error;

pub use configuration::{Configuration, resolve_configuration};
pub use plan::{ConfigurationDelivery, Invocation, Operation, Plan, plan};

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum Service {
    Devbox,
    GhostbsdRemoteAccess,
}

impl Service {
    pub const ALL: [Self; 2] = [Self::Devbox, Self::GhostbsdRemoteAccess];

    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Devbox => "devbox",
            Self::GhostbsdRemoteAccess => "ghostbsd-remote-access",
        }
    }

    pub const fn platforms(self) -> &'static [Platform] {
        match self {
            Self::Devbox => &[Platform::Windows, Platform::Macos],
            Self::GhostbsdRemoteAccess => &[Platform::Ghostbsd, Platform::Windows],
        }
    }
}

impl fmt::Display for Service {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.as_str())
    }
}

impl FromStr for Service {
    type Err = Error;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        match value {
            "devbox" => Ok(Self::Devbox),
            "ghostbsd-remote-access" => Ok(Self::GhostbsdRemoteAccess),
            _ => Err(Error::UnknownService(value.to_owned())),
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Platform {
    Windows,
    Macos,
    Ghostbsd,
    Linux,
}

impl Platform {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Windows => "windows",
            Self::Macos => "macos",
            Self::Ghostbsd => "ghostbsd",
            Self::Linux => "linux",
        }
    }
}

impl fmt::Display for Platform {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.as_str())
    }
}

impl FromStr for Platform {
    type Err = Error;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        match value {
            "windows" => Ok(Self::Windows),
            "macos" => Ok(Self::Macos),
            "ghostbsd" => Ok(Self::Ghostbsd),
            "linux" => Ok(Self::Linux),
            _ => Err(Error::UnknownPlatform(value.to_owned())),
        }
    }
}

#[derive(Debug, Error)]
pub enum Error {
    #[error("unknown service: {0}")]
    UnknownService(String),
    #[error("unknown platform: {0}")]
    UnknownPlatform(String),
    #[error("{service} has no implemented {platform} backend")]
    UnsupportedBackend {
        service: Service,
        platform: Platform,
    },
    #[error("invalid JSON: {0}")]
    Json(#[from] serde_json::Error),
    #[error("invalid embedded schema or metadata: {0}")]
    EmbeddedContract(String),
    #[error("invalid {service} configuration: {details}")]
    Configuration { service: Service, details: String },
    #[error("schema reference is outside the embedded catalogue: {0}")]
    UnsupportedReference(String),
    #[error(
        "GhostBSD Remote Access requires an explicit existing non-root account (lowercase login, at most 32 characters)"
    )]
    InvalidAccount,
    #[error("--user is only supported for GhostBSD Remote Access")]
    UnexpectedAccount,
    #[error("configuration paths in a JSON plan must be valid Unicode")]
    NonUnicodePath,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ServiceDescriptor {
    pub name: Service,
    pub platforms: &'static [Platform],
    pub native_versions: BTreeMap<Platform, String>,
    pub rust_execution_supported: bool,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Manifest {
    name: Service,
    versions: BTreeMap<Platform, String>,
}

pub fn services() -> Result<Vec<ServiceDescriptor>, Error> {
    Service::ALL
        .into_iter()
        .map(|service| {
            let source = match service {
                Service::Devbox => include_str!("../../../../services/devbox/service.json"),
                Service::GhostbsdRemoteAccess => {
                    include_str!("../../../../services/ghostbsd-remote-access/service.json")
                }
            };
            let manifest: Manifest = serde_json::from_str(source)?;
            if manifest.name != service
                || manifest.versions.len() != service.platforms().len()
                || service
                    .platforms()
                    .iter()
                    .any(|platform| !manifest.versions.contains_key(platform))
            {
                return Err(Error::EmbeddedContract(format!(
                    "{service} manifest and implemented backends differ"
                )));
            }
            Ok(ServiceDescriptor {
                name: service,
                platforms: service.platforms(),
                native_versions: manifest.versions,
                rust_execution_supported: false,
            })
        })
        .collect()
}
