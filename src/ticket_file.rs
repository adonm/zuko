//! `~/.config/zuko/current_ticket` — the live, dialable ticket that
//! `zuko host` maintains and `zuko share` reads.
//!
//! The file exists so the handoff (`zuko share`) never needs an IPC channel
//! to the running host daemon: the host writes its current ticket here on
//! startup and refreshes it every 30 s (addresses drift when Iroh re-homes to
//! a relay), and `zuko share` reads it on demand.
//!
//! The contents are a dialing secret (anyone holding it can connect), so the
//! file is written through [`crate::secret::write_secret_0600`]: atomic
//! temp + rename with `0600` perms, identical to the host key.

use anyhow::{Context, Result, bail};
use std::path::PathBuf;
use std::time::{Duration, Instant, SystemTime};

use crate::secret::write_secret_0600;

/// `zuko host` refreshes current_ticket every 30s. Treat much older files as
/// stale so `zuko share` doesn't hand out a ticket from a dead/old host.
const CURRENT_TICKET_MAX_AGE: Duration = Duration::from_secs(5 * 60);

/// `~/.config/zuko/current_ticket` (follows `XDG_CONFIG_HOME`).
pub fn current_ticket_path() -> PathBuf {
    let mut p = crate::config_dir();
    p.push("zuko");
    p.push("current_ticket");
    p
}

/// Write the live ticket atomically with 0600 perms. Called by `zuko host`
/// on startup and periodically; the host treats a failure here as
/// non-fatal (it keeps serving shells even if the file can't be written).
pub fn write_current_ticket(ticket: &str) -> Result<()> {
    write_secret_0600(&current_ticket_path(), ticket.trim().as_bytes())
}

/// Remove the published ticket if present. Used by `zuko reset` so a stale
/// pre-reset ticket cannot be shared accidentally before the host restarts with
/// its new identity.
pub fn remove_current_ticket() -> Result<bool> {
    let path = current_ticket_path();
    match std::fs::remove_file(&path) {
        Ok(()) => Ok(true),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(e) => Err(e).with_context(|| format!("remove {}", path.display())),
    }
}

/// Read and trim the live ticket. Used by `zuko share`.
pub fn read_current_ticket() -> Result<String> {
    let path = current_ticket_path();
    let meta = std::fs::metadata(&path).with_context(|| {
        format!(
            "stat {} (is `zuko host` running? it writes the current ticket there)",
            path.display()
        )
    })?;
    let age = meta
        .modified()
        .ok()
        .and_then(|mtime| SystemTime::now().duration_since(mtime).ok());
    if !current_ticket_age_is_fresh(age) {
        bail!(
            "{} is stale (is `zuko host` running? it refreshes this file every 30s)",
            path.display()
        );
    }
    let ticket = std::fs::read_to_string(&path).with_context(|| {
        format!(
            "read {} (is `zuko host` running? it writes the current ticket there)",
            path.display()
        )
    })?;
    let ticket = ticket.trim().to_string();
    if ticket.is_empty() {
        bail!("{} is empty (is `zuko host` running?)", path.display());
    }
    Ok(ticket)
}

fn current_ticket_age_is_fresh(age: Option<Duration>) -> bool {
    age.is_some_and(|age| age <= CURRENT_TICKET_MAX_AGE)
}

/// Poll `current_ticket` until it exists with non-empty contents or `timeout`
/// elapses. Used by `zuko share`'s install-on-offer flow: `service::install`
/// returns as soon as the unit is started, but the freshly-started host takes
/// a few seconds to bind, come online, and write the ticket. Polling here
/// bridges that gap so share can proceed the moment the ticket lands.
pub fn wait_for_current_ticket(timeout: Duration) -> Result<String> {
    let deadline = Instant::now() + timeout;
    loop {
        if let Ok(ticket) = read_current_ticket() {
            return Ok(ticket);
        }
        if Instant::now() >= deadline {
            bail!(
                "host service started, but {} didn't appear within {:?} \
                 (check `journalctl --user -u zuko-host` / the launchd log)",
                current_ticket_path().display(),
                timeout
            );
        }
        std::thread::sleep(Duration::from_millis(500));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn current_ticket_freshness_accepts_recent_mtime_only() {
        assert!(current_ticket_age_is_fresh(Some(Duration::from_secs(30))));
        assert!(current_ticket_age_is_fresh(Some(CURRENT_TICKET_MAX_AGE)));
        assert!(!current_ticket_age_is_fresh(Some(
            CURRENT_TICKET_MAX_AGE + Duration::from_secs(1)
        )));
        assert!(!current_ticket_age_is_fresh(None));
    }
}
