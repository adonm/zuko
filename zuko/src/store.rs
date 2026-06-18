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
//!
//! The file holds dialing-secret tickets (each one grants shell access on the
//! named host), so it's written through the shared atomic `0600` writer — see
//! [`crate::secret`] — and every `add`/`rm` takes an exclusive `flock` on a
//! sibling `.lock` file so two concurrent `zuko` processes can't silently
//! overwrite each other's update.

use anyhow::{bail, Result};
use std::fs;

use crate::config_dir;
use crate::secret::write_secret_0600;

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

    // Hold the cross-process lock across read-modify-write so a concurrent
    // `zuko add` / `zuko rm` can't drop our update (or vice versa).
    let _guard = HostsLock::acquire()?;
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
    // Hold the cross-process lock across read-modify-write.
    let _guard = HostsLock::acquire()?;
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

/// Write entries back through the shared atomic `0600` writer. The temp +
/// rename inside [`write_secret_0600`] guarantees a crash can never leave a
/// truncated hosts file; the `0600` perms keep every saved ticket private.
fn store(entries: &[(String, String)]) -> Result<()> {
    let path = hosts_path();
    let mut body = String::new();
    body.push_str("# zuko saved hosts — do not edit by hand if a `zuko add` is running\n");
    body.push_str("# format: name<TAB>ticket\n");
    for (name, ticket) in entries {
        body.push_str(name);
        body.push('\t');
        body.push_str(ticket);
        body.push('\n');
    }
    write_secret_0600(&path, body.as_bytes())
}

fn hosts_path() -> std::path::PathBuf {
    let mut p = config_dir();
    p.push("zuko");
    p.push("hosts");
    p
}

/// Cross-process advisory lock guarding the read-modify-write transaction in
/// `add`/`remove`. Lives at `~/.config/zuko/hosts.lock` (a separate path so
/// the atomic `hosts` rename never orphans the lock inode), held until the
/// guard is dropped.
struct HostsLock(std::fs::File);

impl HostsLock {
    fn acquire() -> Result<Self> {
        let lock_path = hosts_path().with_extension("lock");
        if let Some(parent) = lock_path.parent() {
            fs::create_dir_all(parent)?;
        }
        // Open (or create) the lock file without truncating — its contents are
        // irrelevant; only the flock on the inode matters.
        let f = fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(&lock_path)?;
        // Block until we hold the exclusive lock. fs4 releases on drop; we
        // stash the file in the guard so its lifetime ties to the transaction.
        fs4::fs_std::FileExt::lock_exclusive(&f)?;
        Ok(Self(f))
    }
}

impl Drop for HostsLock {
    fn drop(&mut self) {
        // Best-effort unlock; the OS releases the lock when the fd closes
        // anyway, but explicit is clearer and frees it immediately.
        let _ = fs4::fs_std::FileExt::unlock(&self.0);
    }
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

    // The hosts file is a dialing-secret (one ticket per line = one shell each),
    // so it must be 0600 — readable only by the owner.
    #[cfg(unix)]
    #[test]
    fn hosts_file_is_0600() {
        use std::os::unix::fs::PermissionsExt;
        let _g = lock();
        let _dir = isolated();
        add("home", "endpointaAAAA").unwrap();
        let perms = std::fs::metadata(hosts_path())
            .unwrap()
            .permissions()
            .mode();
        assert_eq!(
            perms & 0o777,
            0o600,
            "hosts file must be 0600, got {:o}",
            perms
        );
    }

    // The cross-process lock must be released when add() returns, so a
    // subsequent operation in the same process doesn't deadlock against a
    // held-open lock. (Tests the HostsLock acquire/drop path end-to-end.)
    #[test]
    fn lock_is_released_after_add_and_remove() {
        let _g = lock();
        let _dir = isolated();
        add("a", "endpointaAAAA").unwrap();
        add("b", "endpointaBBBB").unwrap(); // would deadlock if the first held the lock
        remove("a").unwrap();
        add("c", "endpointaCCCC").unwrap();
        // The lock file itself sticks around (we never unlink it) — that's
        // fine, it carries no data.
        assert!(hosts_path().with_extension("lock").exists());
    }
}
