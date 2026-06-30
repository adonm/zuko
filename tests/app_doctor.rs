#![cfg(target_os = "linux")]

use std::process::Command;

#[test]
fn app_doctor_smoke_when_cage_is_available() {
    if std::env::var_os("ZUKO_CAGE").is_none() && !command_on_path("cage") {
        eprintln!("skipping zuko app doctor smoke: cage not on PATH and ZUKO_CAGE unset");
        return;
    }

    let output = Command::new(env!("CARGO_BIN_EXE_zuko"))
        .args(["app", "--doctor"])
        .output()
        .expect("run zuko app --doctor");
    assert!(
        output.status.success(),
        "zuko app --doctor failed\nstdout:\n{}\nstderr:\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(String::from_utf8_lossy(&output.stdout).contains("zuko app doctor"));
}

fn command_on_path(name: &str) -> bool {
    let Some(path) = std::env::var_os("PATH") else {
        return false;
    };
    std::env::split_paths(&path).any(|dir| dir.join(name).is_file())
}
