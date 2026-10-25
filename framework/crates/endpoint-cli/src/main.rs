use std::{fs, io, path::PathBuf, process::ExitCode};

use bos_endpoint_core::{Configuration, Operation, Platform, Service};
use clap::{Args, Parser, Subcommand};
use serde::Serialize;
use thiserror::Error;

#[derive(Debug, Parser)]
#[command(version, about, arg_required_else_help = true)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// List services and their implemented native backends.
    Services,
    /// Resolve packaged defaults plus an optional partial profile as JSON.
    Configuration(Profile),
    /// Validate a profile without observing or changing an endpoint.
    Validate(Profile),
    /// Describe native inspection/preview operations; never execute them.
    Plan {
        #[command(flatten)]
        profile: Profile,
        #[arg(long)]
        platform: Platform,
        #[arg(long, default_value = "status")]
        operation: Operation,
        /// Existing non-root account, required only for GhostBSD Remote Access.
        #[arg(long)]
        user: Option<String>,
    },
}

#[derive(Debug, Args)]
struct Profile {
    #[arg(long)]
    service: Service,
    /// Explicit JSON profile; installed/native state is never read implicitly.
    #[arg(long)]
    config: Option<PathBuf>,
}

impl Profile {
    fn resolve(&self) -> Result<Configuration, CliError> {
        let profile = self
            .config
            .as_ref()
            .map(|path| {
                fs::read_to_string(path).map_err(|source| CliError::ReadProfile {
                    path: path.clone(),
                    source,
                })
            })
            .transpose()?;
        Ok(bos_endpoint_core::resolve_configuration(
            self.service,
            profile.as_deref(),
        )?)
    }
}

#[derive(Debug, Error)]
enum CliError {
    #[error(transparent)]
    Contract(#[from] bos_endpoint_core::Error),
    #[error("cannot read configuration {path}: {source}")]
    ReadProfile { path: PathBuf, source: io::Error },
    #[error("cannot write JSON output: {0}")]
    Output(#[from] serde_json::Error),
    #[error("cannot finish JSON output: {0}")]
    OutputIo(#[from] io::Error),
}

fn print_json(value: &impl Serialize) -> Result<(), CliError> {
    use io::Write;
    let mut stdout = io::stdout().lock();
    serde_json::to_writer_pretty(&mut stdout, value)?;
    stdout.write_all(b"\n")?;
    Ok(())
}

fn run(cli: Cli) -> Result<(), CliError> {
    match cli.command {
        Command::Services => print_json(&bos_endpoint_core::services()?),
        Command::Configuration(profile) => print_json(&profile.resolve()?),
        Command::Validate(profile) => {
            #[derive(Serialize)]
            #[serde(rename_all = "camelCase")]
            struct Validation {
                service: Service,
                schema_version: u8,
                status: &'static str,
            }
            let configuration = profile.resolve()?;
            print_json(&Validation {
                service: configuration.service(),
                schema_version: configuration.schema_version(),
                status: "VALID",
            })
        }
        Command::Plan {
            profile,
            platform,
            operation,
            user,
        } => print_json(&bos_endpoint_core::plan(
            profile.resolve()?,
            platform,
            operation,
            user.as_deref(),
            profile.config.as_deref(),
        )?),
    }
}

fn main() -> ExitCode {
    match run(Cli::parse()) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("ERROR: {error}");
            ExitCode::from(2)
        }
    }
}
