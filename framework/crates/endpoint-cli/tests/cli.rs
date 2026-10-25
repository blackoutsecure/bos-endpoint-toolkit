use std::{
    error::Error,
    fs,
    process::{Command, Output},
};

use serde_json::Value;

type TestResult = Result<(), Box<dyn Error>>;

fn run(arguments: &[&str]) -> Result<Output, std::io::Error> {
    Command::new(env!("CARGO_BIN_EXE_bos-endpoint-toolkit"))
        .args(arguments)
        .output()
}

fn json(output: &Output) -> Result<Value, serde_json::Error> {
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout)
}

#[test]
fn embedded_defaults_work_outside_the_checkout_without_native_runtimes() -> TestResult {
    let directory = tempfile::tempdir()?;
    for (service, defaults) in [
        (
            "devbox",
            include_str!("../../../../services/devbox/config/defaults.json"),
        ),
        (
            "ghostbsd-remote-access",
            include_str!("../../../../services/ghostbsd-remote-access/config/defaults.json"),
        ),
    ] {
        let output = Command::new(env!("CARGO_BIN_EXE_bos-endpoint-toolkit"))
            .current_dir(directory.path())
            .args(["configuration", "--service", service])
            .output()?;
        assert_eq!(json(&output)?, serde_json::from_str::<Value>(defaults)?);
    }
    assert_eq!(fs::read_dir(directory.path())?.count(), 0);
    directory.close()?;
    Ok(())
}

#[test]
fn service_catalogue_reports_only_implemented_backends() -> TestResult {
    let catalogue = json(&run(&["services"])?)?;
    assert_eq!(catalogue.as_array().map(Vec::len), Some(2));
    assert_eq!(catalogue[0]["name"], "devbox");
    assert_eq!(
        catalogue[0]["platforms"],
        serde_json::json!(["windows", "macos"])
    );
    assert_eq!(catalogue[1]["name"], "ghostbsd-remote-access");
    assert_eq!(catalogue[1]["rustExecutionSupported"], false);
    Ok(())
}

#[test]
fn profiles_are_resolved_without_modifying_the_file_or_directory() -> TestResult {
    let directory = tempfile::tempdir()?;
    let path = directory.path().join("desired profile.json");
    let profile = r#"{"schemaVersion":1,"platform":"hyperv","rdpPort":3390}"#;
    fs::write(&path, profile)?;
    let path = path.to_str().ok_or("test profile path must be Unicode")?;
    let output = run(&[
        "configuration",
        "--service",
        "ghostbsd-remote-access",
        "--config",
        path,
    ])?;
    let configuration = json(&output)?;
    assert_eq!(configuration["rdpPort"], 3390);
    assert_eq!(configuration["sshPort"], 22);
    assert_eq!(configuration["platform"], "hyperv");
    assert_eq!(fs::read_to_string(path)?, profile);
    assert_eq!(fs::read_dir(directory.path())?.count(), 1);
    let validation = json(&run(&[
        "validate",
        "--service",
        "ghostbsd-remote-access",
        "--config",
        path,
    ])?)?;
    assert_eq!(validation["status"], "VALID");
    directory.close()?;
    Ok(())
}

#[test]
fn missing_or_invalid_explicit_profiles_fail_instead_of_falling_back() -> TestResult {
    let directory = tempfile::tempdir()?;
    let path = directory.path().join("profile.json");
    let path = path.to_str().ok_or("test profile path must be Unicode")?;
    let missing = run(&["configuration", "--service", "devbox", "--config", path])?;
    assert_eq!(missing.status.code(), Some(2));
    assert!(missing.stdout.is_empty());
    assert!(String::from_utf8_lossy(&missing.stderr).contains("cannot read configuration"));
    for profile in ["null", "{}", r#"{"schemaVersion":1,"retension":21}"#] {
        fs::write(path, profile)?;
        let output = run(&["validate", "--service", "devbox", "--config", path])?;
        assert_eq!(output.status.code(), Some(2));
        assert!(output.stdout.is_empty());
        assert!(String::from_utf8_lossy(&output.stderr).contains("invalid devbox configuration"));
    }
    directory.close()?;
    Ok(())
}

#[test]
fn remote_apply_plan_is_preview_only_and_requires_real_explicit_inputs() -> TestResult {
    let output = run(&[
        "plan",
        "--service",
        "ghostbsd-remote-access",
        "--platform",
        "windows",
        "--operation",
        "apply",
        "--user",
        "fixture",
    ])?;
    let plan = json(&output)?;
    assert_eq!(plan["mutatesEndpoint"], false);
    assert_eq!(plan["executionSupported"], false);
    assert_eq!(plan["configurationDelivery"], "build-time-profile");
    assert!(
        plan["nativePreview"]["arguments"]
            .as_array()
            .is_some_and(|arguments| arguments.iter().any(|argument| argument == "-WhatIf"))
    );
    for arguments in [
        vec![
            "plan",
            "--service",
            "ghostbsd-remote-access",
            "--platform",
            "windows",
        ],
        vec![
            "plan",
            "--service",
            "ghostbsd-remote-access",
            "--platform",
            "ghostbsd",
            "--user",
            "root",
        ],
        vec!["plan", "--service", "devbox", "--platform", "linux"],
        vec!["plan", "--service", "unknown", "--platform", "windows"],
        vec!["apply", "--service", "ghostbsd-remote-access"],
    ] {
        let output = run(&arguments)?;
        assert_eq!(output.status.code(), Some(2));
        assert!(output.stdout.is_empty());
    }
    Ok(())
}

#[test]
fn macos_plan_does_not_fabricate_a_full_native_dry_run() -> TestResult {
    let plan = json(&run(&[
        "plan",
        "--service",
        "devbox",
        "--platform",
        "macos",
        "--operation",
        "apply",
    ])?)?;
    assert!(plan["nativePreview"].is_null());
    assert!(
        plan["warnings"]
            .as_array()
            .is_some_and(|warnings| warnings.iter().any(|warning| warning
                .as_str()
                .is_some_and(|text| text.contains("resize-only"))))
    );
    Ok(())
}

#[test]
fn no_arguments_and_unknown_flags_never_trigger_an_operation() -> TestResult {
    for arguments in [vec![], vec!["--unknown"]] {
        let output = run(&arguments)?;
        assert_eq!(output.status.code(), Some(2));
        assert!(output.stdout.is_empty());
        assert!(String::from_utf8_lossy(&output.stderr).contains("Usage:"));
    }
    let help = run(&["--help"])?;
    assert!(help.status.success());
    assert!(String::from_utf8_lossy(&help.stdout).contains("never execute"));
    Ok(())
}
