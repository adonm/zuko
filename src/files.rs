//! Foreground file sharing through the existing authenticated Zuko tunnel.

use std::net::{Ipv4Addr, TcpListener};
use std::path::Path;
use std::process::{Child, Command, ExitStatus, Stdio};
use std::time::Duration;

use anyhow::{Context, Result, bail};

use crate::{TunnelArgs, tunnel};

const DUFS_TOOL: &str = "github:sigoden/dufs@0.46.0";
const STARTUP_TIMEOUT: Duration = Duration::from_secs(10);
const CHILD_POLL_INTERVAL: Duration = Duration::from_millis(100);

enum DufsCommand {
    Direct,
    Mise,
}

impl DufsCommand {
    fn prepare() -> Result<Self> {
        if command_succeeds("dufs", &["--version"]) {
            return Ok(Self::Direct);
        }
        if !command_succeeds("mise", &["--version"]) {
            bail!(
                "dufs is not on PATH and mise is unavailable; install or activate mise, then retry"
            );
        }

        eprintln!("zuko files: dufs is missing; installing {DUFS_TOOL} with mise");
        let args = mise_install_args();
        let status = Command::new("mise")
            .args(&args)
            .status()
            .context("run mise to install dufs")?;
        if !status.success() {
            bail!("mise {} failed ({status})", args.join(" "));
        }
        Ok(Self::Mise)
    }

    fn spawn(self, port: u16, directory: &Path) -> Result<Child> {
        let dufs_args = dufs_args(port);
        let mut command = match self {
            Self::Direct => Command::new("dufs"),
            Self::Mise => {
                let mut command = Command::new("mise");
                command.args(mise_exec_args());
                command.arg("dufs");
                command
            }
        };
        command.args(&dufs_args).arg(directory);
        for (key, _) in std::env::vars_os() {
            if key.to_string_lossy().starts_with("DUFS_") {
                command.env_remove(key);
            }
        }
        command
            .stdin(Stdio::inherit())
            .stdout(Stdio::inherit())
            .stderr(Stdio::inherit())
            .spawn()
            .context("start dufs")
    }
}

struct ChildGuard(Option<Child>);

impl ChildGuard {
    fn new(child: Child) -> Self {
        Self(Some(child))
    }

    fn child_mut(&mut self) -> &mut Child {
        self.0.as_mut().expect("child guard is populated")
    }

    fn stop(&mut self) {
        let Some(mut child) = self.0.take() else {
            return;
        };
        if child.try_wait().ok().flatten().is_none() {
            let _ = child.kill();
        }
        let _ = child.wait();
    }
}

impl Drop for ChildGuard {
    fn drop(&mut self) {
        self.stop();
    }
}

/// Serve the current directory with dufs and expose it through `zuko tunnel`.
pub async fn run() -> Result<()> {
    tunnel::require_control_environment("zuko files")?;
    let dufs = DufsCommand::prepare()?;
    let port = reserve_loopback_port()?;
    let cwd = std::env::current_dir().context("read current directory")?;

    eprintln!("zuko files: serving {}", cwd.display());
    eprintln!(
        "zuko files: dufs -A allows anonymous upload, delete, search, archive, and symlink access while this command runs"
    );
    let child = dufs.spawn(port, &cwd)?;
    let mut child = ChildGuard::new(child);
    wait_until_listening(child.child_mut(), port).await?;

    let mut tunnel = Box::pin(tunnel::run(TunnelArgs { port }));
    let result = loop {
        tokio::select! {
            biased;
            result = &mut tunnel => break result,
            _ = tokio::time::sleep(CHILD_POLL_INTERVAL) => {
                if let Some(status) = child
                    .child_mut()
                    .try_wait()
                    .context("check dufs process")?
                {
                    break dufs_exit_result(status);
                }
            }
        }
    };

    drop(tunnel);
    child.stop();
    result
}

fn command_succeeds(program: &str, args: &[&str]) -> bool {
    Command::new(program)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|status| status.success())
}

fn dufs_args(port: u16) -> Vec<String> {
    vec![
        "-A".into(),
        "-b".into(),
        Ipv4Addr::LOCALHOST.to_string(),
        "-p".into(),
        port.to_string(),
    ]
}

fn mise_install_args() -> Vec<String> {
    vec!["install".into(), DUFS_TOOL.into()]
}

fn mise_exec_args() -> Vec<String> {
    vec!["exec".into(), DUFS_TOOL.into(), "--".into()]
}

fn reserve_loopback_port() -> Result<u16> {
    let listener =
        TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).context("reserve a loopback port for dufs")?;
    Ok(listener.local_addr()?.port())
}

async fn wait_until_listening(child: &mut Child, port: u16) -> Result<()> {
    let deadline = tokio::time::Instant::now() + STARTUP_TIMEOUT;
    loop {
        if let Some(status) = child.try_wait().context("check dufs startup")? {
            return dufs_exit_result(status).context("dufs exited before opening its port");
        }
        if tokio::net::TcpStream::connect((Ipv4Addr::LOCALHOST, port))
            .await
            .is_ok()
        {
            tokio::time::sleep(CHILD_POLL_INTERVAL).await;
            if let Some(status) = child.try_wait().context("confirm dufs startup")? {
                return dufs_exit_result(status)
                    .context("another process claimed the selected dufs port");
            }
            return Ok(());
        }
        if tokio::time::Instant::now() >= deadline {
            bail!("dufs did not listen on 127.0.0.1:{port} within 10 seconds");
        }
        tokio::time::sleep(CHILD_POLL_INTERVAL).await;
    }
}

fn dufs_exit_result(status: ExitStatus) -> Result<()> {
    if status.success() {
        eprintln!("zuko files: dufs stopped");
        Ok(())
    } else {
        bail!("dufs exited unexpectedly ({status})")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dufs_is_loopback_only_and_allows_anonymous_operations() {
        assert_eq!(dufs_args(43210), ["-A", "-b", "127.0.0.1", "-p", "43210"]);
    }

    #[test]
    fn mise_install_and_exec_use_the_same_pinned_tool() {
        assert_eq!(
            mise_install_args(),
            ["install", "github:sigoden/dufs@0.46.0"]
        );
        assert_eq!(
            mise_exec_args(),
            ["exec", "github:sigoden/dufs@0.46.0", "--"]
        );
    }

    #[test]
    fn reserved_port_is_nonzero() {
        assert_ne!(reserve_loopback_port().unwrap(), 0);
    }
}
