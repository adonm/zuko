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

use anyhow::{bail, Context, Result};
use std::path::PathBuf;

use crate::secret::write_secret_0600;

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

/// Read and trim the live ticket. Used by `zuko share`.
pub(crate) fn read_current_ticket() -> Result<String> {
    let path = current_ticket_path();
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
