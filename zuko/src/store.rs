//! Saved hosts for the client — the terminal analogue of the iOS app's
//! `ConnectionStore`. Persists a tiny, grep-able list at
//! `~/.config/zuko/hosts`, one host per line:
//!
//! ```text
//! name<TAB or space>ticket
//! ```
//!
//! Tickets contain no whitespace, and names are validated to contain none, so a
//! plain whitespace split round-trips reliably. Lines starting with `#` are
//! comments.

use anyhow::{bail, Result};
use std::fs;
use std::io::Write;

use crate::config_dir;

/// Resolve a `zuko connect` target to a raw ticket string.
///
/// - If `target` is the name of a saved host, returns that host's ticket.
/// - Otherwise treats `target` itself as a raw ticket.
/// - With no target and piped stdin, reads the ticket from stdin (so
///   `zuko < ticket.txt` and `pbpaste | zuko` work).
/// - With no target on a real tty, bails with usage so an interactive bare
///   `zuko` doesn't block waiting for stdin.
pub fn resolve_ticket(target: Option<String>) -> Result<String> {
    if let Some(name) = target {
        let trimmed = name.trim();
        if let Some(ticket) = lookup(trimmed) {
            return Ok(ticket);
        }
        return Ok(trimmed.to_string());
    }

    use std::io::IsTerminal;
    if std::io::stdin().is_terminal() {
        bail!(
            "usage: zuko <saved-name|ticket>\n  \
             save a host with: zuko add <name> <ticket>\n  \
             list saved hosts: zuko ls"
        );
    }
    let mut buf = String::new();
    std::io::Read::read_to_string(&mut std::io::stdin(), &mut buf)?;
    let t = buf.trim().to_string();
    if t.is_empty() {
        bail!("no ticket on stdin");
    }
    Ok(t)
}

/// Save a host. Rejects names containing whitespace or `#`.
pub fn add(name: &str, ticket: &str) -> Result<()> {
    let name = name.trim();
    let ticket = ticket.trim();
    validate_name(name)?;
    if ticket.is_empty() {
        bail!("ticket is empty");
    }
    if ticket.chars().any(char::is_whitespace) {
        bail!("ticket contains whitespace");
    }

    let mut entries = load();
    if let Some(existing) = entries.iter_mut().find(|(n, _)| n == name) {
        // Overwrite an existing entry under the same name in place.
        existing.1 = ticket.to_string();
    } else {
        entries.push((name.to_string(), ticket.to_string()));
    }
    store(&entries)
}

/// Print saved hosts to stdout (`zuko ls`).
pub fn list() {
    for (name, ticket) in load() {
        println!("{name}\t{ticket}");
    }
}

/// Remove a saved host by name. Succeeds whether or not it existed.
pub fn remove(name: &str) -> Result<()> {
    let before = load();
    let after: Vec<_> = before.into_iter().filter(|(n, _)| n != name).collect();
    store(&after)
}

fn lookup(name: &str) -> Option<String> {
    load().into_iter().find(|(n, _)| n == name).map(|(_, t)| t)
}

fn validate_name(name: &str) -> Result<()> {
    if name.is_empty() {
        bail!("name is empty");
    }
    if name.starts_with('#') || name.chars().any(char::is_whitespace) {
        bail!("name must not contain whitespace or start with '#'");
    }
    Ok(())
}

/// Parse the hosts file into `(name, ticket)` pairs, ignoring blanks/comments.
fn load() -> Vec<(String, String)> {
    let Ok(text) = fs::read_to_string(hosts_path()) else {
        return Vec::new();
    };
    text.lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .filter_map(|l| {
            let mut it = l.split_whitespace();
            let name = it.next()?.to_string();
            let ticket = it.next()?.to_string();
            Some((name, ticket))
        })
        .collect()
}

/// Write entries back atomically (temp + rename), creating the config dir.
fn store(entries: &[(String, String)]) -> Result<()> {
    let path = hosts_path();
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let mut body = String::new();
    body.push_str("# zuko saved hosts — do not edit by hand if a `zuko add` is running\n");
    body.push_str("# format: name<TAB>ticket\n");
    for (name, ticket) in entries {
        body.push_str(name);
        body.push('\t');
        body.push_str(ticket);
        body.push('\n');
    }
    let tmp = path.with_extension("tmp");
    let mut f = fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .open(&tmp)?;
    f.write_all(body.as_bytes())?;
    f.sync_all()?;
    drop(f);
    fs::rename(tmp, &path)?;
    Ok(())
}

fn hosts_path() -> std::path::PathBuf {
    let mut p = config_dir();
    p.push("zuko");
    p.push("hosts");
    p
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::sync::{Mutex, OnceLock};

    // All store tests set XDG_CONFIG_HOME to an isolated tempdir. Cargo runs
    // tests in parallel, so guard the env var with a process-wide lock to keep
    // them from stomping on each other.
    static TEST_LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    fn lock() -> std::sync::MutexGuard<'static, ()> {
        TEST_LOCK.get_or_init(|| Mutex::new(())).lock().unwrap()
    }

    /// Round-trip add/lookup/remove against an isolated XDG dir.
    fn isolated() -> tempfile::TempDir {
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("XDG_CONFIG_HOME", dir.path());
        dir
    }

    #[test]
    fn add_lookup_remove_roundtrip() {
        let _g = lock();
        let _dir = isolated();
        assert!(lookup("home").is_none());

        add("home", "endpointaAAAA").unwrap();
        add("server", "endpointaBBBB").unwrap();
        assert_eq!(lookup("home").as_deref(), Some("endpointaAAAA"));

        // Overwriting an existing name updates in place.
        add("home", "endpointaCCCC").unwrap();
        assert_eq!(lookup("home").as_deref(), Some("endpointaCCCC"));

        remove("server").unwrap();
        assert!(lookup("server").is_none());
        assert_eq!(lookup("home").as_deref(), Some("endpointaCCCC"));
    }

    #[test]
    fn rejects_bad_names_and_tickets() {
        let _g = lock();
        let _dir = isolated();
        assert!(add("with space", "endpointa").is_err());
        assert!(add("#comment", "endpointa").is_err());
        assert!(add("", "endpointa").is_err());
        assert!(add("ok", "").is_err());
        assert!(add("ok", "has space").is_err());
    }

    #[test]
    fn resolves_saved_name_then_raw_ticket() {
        let _g = lock();
        let _dir = isolated();
        add("home", "endpointaAAAA").unwrap();
        assert_eq!(
            resolve_ticket(Some("home".to_string())).unwrap(),
            "endpointaAAAA"
        );
        // Unknown name falls through as a raw ticket.
        assert_eq!(
            resolve_ticket(Some("endpointaZZZZ".to_string())).unwrap(),
            "endpointaZZZZ"
        );
    }

    // Smoke-test writing a comment+entry by hand and parsing it back, so the
    // `#` / blank-line skipping is covered without depending on `add`.
    #[test]
    fn skips_comments_and_blanks() {
        let _g = lock();
        let _dir = isolated();
        let path = hosts_path();
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        let mut f = std::fs::File::create(&path).unwrap();
        writeln!(f, "# header").unwrap();
        writeln!(f).unwrap();
        writeln!(f, "home\tendpointaAAAA").unwrap();
        writeln!(f, "  server endpointaBBBB  ").unwrap();
        drop(f);
        assert_eq!(lookup("home").as_deref(), Some("endpointaAAAA"));
        assert_eq!(lookup("server").as_deref(), Some("endpointaBBBB"));
    }
}
