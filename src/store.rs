//! Saved hosts for the client — the terminal analogue of the iOS app's
//! `ConnectionStore` — plus the host-side list of authorised clients.
//! Persists tiny, grep-able lists at `~/.config/zuko/hosts` and
//! `~/.config/zuko/authorized_clients`, one entry per line:
//!
//! ```text
//! name<TAB or space>ticket-or-token
//! ```
//!
//! Tickets and client tokens contain no whitespace, and names are validated to
//! contain none, so a plain whitespace split round-trips reliably. Lines
//! starting with `#` are comments.
//!
//! These files hold shell-access secrets (tickets for saved hosts, reattach
//! tokens for authorised clients), so they're written through the shared atomic
//! `0600` writer — see [`crate::secret`] — and every read-modify-write takes an
//! exclusive `flock` on a sibling `.lock` file so two concurrent `zuko`
//! processes can't silently overwrite each other's update.
//!
//! ## Why tickets never cross the CLI surface
//!
//! The CLI never accepts a raw ticket as an argument or via stdin — that path
//! is the one way long-lived bearer secrets leak (shell history, scrollback,
//! copy/paste into chat). New hosts land in this file **only** via
//! `zuko claim <code>` (the OTP-style pairing in [`crate::handoff`]); from then
//! on, `zuko connect <name>` / bare `zuko <name>` look the ticket up here.

use anyhow::{Result, bail};
use std::fs;

use crate::config_dir;
use crate::secret::write_secret_0600;
use crate::wire::{SESSION_TOKEN_LEN, SessionToken, empty_session_token};

#[derive(Debug, Default, Eq, PartialEq)]
pub struct Removal {
    pub saved_host: bool,
    pub authorized_client: bool,
}

/// Look up a saved host by name, returning its ticket. Bails with a clear
/// usage hint if the name isn't known — we never fall back to treating the
/// input as a raw ticket (that path leaks long-lived secrets into shell
/// history, which is exactly what the pairing flow exists to avoid).
pub fn lookup_ticket_or_bail(name: &str) -> Result<String> {
    if let Some(ticket) = lookup(name.trim()) {
        return Ok(ticket);
    }
    let known: Vec<String> = load().into_iter().map(|(n, _)| n).collect();
    let hint = if known.is_empty() {
        "no saved hosts yet — pair one with `zuko claim <code>`".to_string()
    } else {
        format!("known hosts: {}", known.join(", "))
    };
    bail!("no saved host named \"{name}\"\n  {hint}");
}

/// Return saved host names in recency order (most-recently-touched first).
/// Used by the bare-`zuko` picker and the first-run menu to surface hosts the
/// user actually reaches for, without dragging the long-lived tickets along —
/// they're never printed.
pub fn saved_names() -> Vec<String> {
    load().into_iter().map(|(n, _)| n).collect()
}

/// Save a host. Rejects names containing whitespace or `#`. Called only by
/// `zuko claim` (after a successful OTP handoff) — there's no `zuko add`
/// subcommand any more, precisely so tickets can't be pasted in by hand.
///
/// New hosts are inserted at the **front** (most-recent position), matching
/// the iOS app's move-to-front-on-add. A re-claim of an existing name updates
/// the ticket *and* promotes the entry to the front.
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
    let _guard = StoreLock::acquire(hosts_path())?;
    let mut entries = load_entries(hosts_path());
    // Drop any existing entry under this name so the re-insert lands at the
    // front (move-to-front on re-claim, not in-place update).
    entries.retain(|(n, _)| n != name);
    entries.insert(0, (name.to_string(), ticket.to_string()));
    store_hosts(&entries)
}

/// Promote a saved host to the front of the list (most-recent position).
/// Called after a successful `zuko connect` / bare `zuko <name>` / picker
/// selection so the bare-`zuko` menu surfaces the hosts you actually use.
/// No-op if the name isn't saved (e.g. a one-off connect via a path that
/// didn't save); best-effort — callers swallow errors here so a failed touch
/// never undoes a successful session.
pub fn touch(name: &str) -> Result<()> {
    let name = name.trim();
    let _guard = StoreLock::acquire(hosts_path())?;
    let mut entries = load_entries(hosts_path());
    if let Some(idx) = entries.iter().position(|(n, _)| n == name)
        && idx != 0
    {
        let entry = entries.remove(idx);
        entries.insert(0, entry);
        store_hosts(&entries)?;
    }
    // If the name isn't found, no-op rather than inserting — `touch` only
    // reorders existing entries; it never adds.
    Ok(())
}

/// Print saved hosts' **names only** to stdout (`zuko ls`). Tickets are
/// long-lived bearer secrets, so we deliberately don't echo them — picking a
/// name to reconnect is the only thing `ls` is for.
pub fn list() {
    let hosts = saved_names();
    let clients = authorized_client_names();

    if hosts.is_empty() && clients.is_empty() {
        return;
    }

    if !hosts.is_empty() {
        println!("saved hosts:");
        for name in &hosts {
            println!("  {name}");
        }
    }

    if !clients.is_empty() {
        if !hosts.is_empty() {
            println!();
        }
        println!("authorised clients:");
        for name in &clients {
            println!("  {name}");
        }
    }
}

/// Remove a saved host by name. Succeeds whether or not it existed.
pub fn remove(name: &str) -> Result<()> {
    let _ = remove_host(name)?;
    Ok(())
}

/// Remove a saved host and/or authorised client by name. Succeeds whether or
/// not either existed, and reports what was actually removed so the CLI can be
/// explicit without racing a second lookup.
pub fn remove_any(name: &str) -> Result<Removal> {
    Ok(Removal {
        saved_host: remove_host(name)?,
        authorized_client: remove_authorized_client(name)?,
    })
}

fn remove_host(name: &str) -> Result<bool> {
    // Hold the cross-process lock across read-modify-write.
    let _guard = StoreLock::acquire(hosts_path())?;
    let before = load_entries(hosts_path());
    let before_len = before.len();
    let after: Vec<_> = before.into_iter().filter(|(n, _)| n != name).collect();
    let removed = after.len() != before_len;
    store_hosts(&after)?;
    Ok(removed)
}

/// Look up a saved host by name, returning its ticket if found. Returns
/// `None` (rather than erroring) so the bare-`zuko <input>` shortcut can
/// distinguish "unknown name, maybe it's a pairing code" from a real lookup
/// failure — see [`lookup_ticket_or_bail`] for the strict variant used by
/// `zuko connect <name>`.
pub fn lookup(name: &str) -> Option<String> {
    load_entries(hosts_path())
        .into_iter()
        .find(|(n, _)| n == name)
        .map(|(_, t)| t)
}

/// Register a client token as authorised to open shells on this host. Called by
/// `zuko share` after a successful pairing handoff.
pub fn authorize_client(name: &str, token: &SessionToken) -> Result<()> {
    let name = name.trim();
    validate_name(name)?;
    if empty_session_token(token) {
        bail!("client token is empty");
    }
    let token = token_hex(token);

    let _guard = StoreLock::acquire(authorized_clients_path())?;
    let mut entries = load_entries(authorized_clients_path());
    entries.retain(|(n, _)| n != name);
    entries.insert(0, (name.to_string(), token));
    store_authorized_clients(&entries)
}

pub fn authorized_client_names() -> Vec<String> {
    load_entries(authorized_clients_path())
        .into_iter()
        .map(|(n, _)| n)
        .collect()
}

fn remove_authorized_client(name: &str) -> Result<bool> {
    let _guard = StoreLock::acquire(authorized_clients_path())?;
    let before = load_entries(authorized_clients_path());
    let before_len = before.len();
    let after: Vec<_> = before.into_iter().filter(|(n, _)| n != name).collect();
    let removed = after.len() != before_len;
    store_authorized_clients(&after)?;
    Ok(removed)
}

/// Clear host trust and create the authorised-clients file as an empty list.
/// Empty means fail closed: no client is trusted until it pairs again through
/// `zuko share`.
pub fn reset_authorized_clients() -> Result<()> {
    let _guard = StoreLock::acquire(authorized_clients_path())?;
    store_authorized_clients(&[])
}

/// Enforce host-side client authorisation. Missing/empty file means fail closed
/// unless the token is listed. `zuko reset` writes an empty file to
/// intentionally trust nothing.
pub fn ensure_client_authorized(token: &SessionToken) -> Result<()> {
    let path = authorized_clients_path();
    if empty_session_token(token) {
        bail!(unauthorized_message());
    }
    let needle = token_hex(token);
    if load_entries(path).into_iter().any(|(_, t)| t == needle) {
        Ok(())
    } else {
        bail!(unauthorized_message())
    }
}

fn unauthorized_message() -> &'static str {
    "this client is not authorised on this host; pair it with `zuko share` on the host"
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
    load_entries(hosts_path())
}

fn load_entries(path: std::path::PathBuf) -> Vec<(String, String)> {
    let Ok(text) = fs::read_to_string(path) else {
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
fn store_hosts(entries: &[(String, String)]) -> Result<()> {
    let path = hosts_path();
    let mut body = String::new();
    body.push_str("# zuko saved hosts — do not edit by hand if a `zuko claim`/`rm` is running\n");
    body.push_str("# format: name<TAB>ticket\n");
    for (name, ticket) in entries {
        body.push_str(name);
        body.push('\t');
        body.push_str(ticket);
        body.push('\n');
    }
    write_secret_0600(&path, body.as_bytes())
}

fn store_authorized_clients(entries: &[(String, String)]) -> Result<()> {
    let path = authorized_clients_path();
    let mut body = String::new();
    body.push_str(
        "# zuko authorised clients — do not edit by hand if a `zuko share`/`rm` is running\n",
    );
    body.push_str("# format: name<TAB>client-token-hex\n");
    for (name, token) in entries {
        body.push_str(name);
        body.push('\t');
        body.push_str(token);
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

fn authorized_clients_path() -> std::path::PathBuf {
    let mut p = config_dir();
    p.push("zuko");
    p.push("authorized_clients");
    p
}

fn token_hex(token: &SessionToken) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(SESSION_TOKEN_LEN * 2);
    for &b in token {
        out.push(HEX[(b >> 4) as usize] as char);
        out.push(HEX[(b & 0x0f) as usize] as char);
    }
    out
}

/// Cross-process advisory lock guarding read-modify-write transactions. Lives
/// at `<store>.lock` (a separate path so atomic renames never orphan the lock
/// inode), held until the guard is dropped.
struct StoreLock(std::fs::File);

impl StoreLock {
    fn acquire(path: std::path::PathBuf) -> Result<Self> {
        let lock_path = path.with_extension("lock");
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

impl Drop for StoreLock {
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
        // SAFETY: tests are serialised by the `TEST_LOCK` mutex taken in each
        // `#[test]` body, so no other test can race the env mutation.
        // `std::env::set_var` became `unsafe` in Rust 2024 (mutating global
        // state can race with concurrent reads in multi-threaded programs).
        unsafe { std::env::set_var("XDG_CONFIG_HOME", dir.path()) };
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

        // Overwriting an existing name updates the ticket AND promotes it to
        // the front (move-to-front on re-claim).
        add("home", "endpointaCCCC").unwrap();
        assert_eq!(lookup("home").as_deref(), Some("endpointaCCCC"));

        remove("server").unwrap();
        assert!(lookup("server").is_none());
        assert_eq!(lookup("home").as_deref(), Some("endpointaCCCC"));
    }

    #[test]
    fn authorized_clients_roundtrip_and_enforcement() {
        let _g = lock();
        let _dir = isolated();
        let token = [7u8; SESSION_TOKEN_LEN];
        let other = [8u8; SESSION_TOKEN_LEN];

        assert!(ensure_client_authorized(&other).is_err());

        authorize_client("phone", &token).unwrap();
        assert_eq!(authorized_client_names(), vec!["phone"]);
        ensure_client_authorized(&token).unwrap();
        assert!(ensure_client_authorized(&other).is_err());

        let removed = remove_any("phone").unwrap();
        assert!(!removed.saved_host);
        assert!(removed.authorized_client);
        assert!(ensure_client_authorized(&token).is_err());
    }

    #[test]
    fn reset_authorized_clients_fails_closed() {
        let _g = lock();
        let _dir = isolated();
        let token = [9u8; SESSION_TOKEN_LEN];

        reset_authorized_clients().unwrap();
        assert!(authorized_client_names().is_empty());
        assert!(ensure_client_authorized(&token).is_err());
    }

    #[test]
    fn remove_any_reports_both_namespaces() {
        let _g = lock();
        let _dir = isolated();

        add("shared", "endpointaAAAA").unwrap();
        authorize_client("shared", &[5u8; SESSION_TOKEN_LEN]).unwrap();

        let removed = remove_any("shared").unwrap();
        assert!(removed.saved_host);
        assert!(removed.authorized_client);
        assert!(lookup("shared").is_none());
        assert!(authorized_client_names().is_empty());
    }

    #[test]
    fn add_inserts_at_front() {
        let _g = lock();
        let _dir = isolated();
        add("first", "endpointaAAAA").unwrap();
        add("second", "endpointaBBBB").unwrap();
        add("third", "endpointaCCCC").unwrap();
        // Most-recently-added first.
        let names = saved_names();
        assert_eq!(names, vec!["third", "second", "first"]);
    }

    #[test]
    fn add_reclaim_promotes_to_front() {
        let _g = lock();
        let _dir = isolated();
        add("alpha", "endpointaAAAA").unwrap();
        add("beta", "endpointaBBBB").unwrap();
        add("gamma", "endpointaCCCC").unwrap();
        // alpha is at the back; re-claim it — it should jump to the front.
        add("alpha", "endpointaDDDD").unwrap();
        assert_eq!(saved_names(), vec!["alpha", "gamma", "beta"]);
        // Ticket updated too.
        assert_eq!(lookup("alpha").as_deref(), Some("endpointaDDDD"));
    }

    #[test]
    fn touch_promotes_to_front() {
        let _g = lock();
        let _dir = isolated();
        add("a", "endpointaAAAA").unwrap();
        add("b", "endpointaBBBB").unwrap();
        add("c", "endpointaCCCC").unwrap();
        // order: c, b, a
        touch("a").unwrap();
        assert_eq!(saved_names(), vec!["a", "c", "b"]);
        // Touching the front-most is a no-op (no rewrite).
        touch("a").unwrap();
        assert_eq!(saved_names(), vec!["a", "c", "b"]);
        // Touching an unknown name is a silent no-op (never inserts).
        touch("nope").unwrap();
        assert_eq!(saved_names(), vec!["a", "c", "b"]);
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
    fn lookup_or_bail_rejects_unknown_names() {
        let _g = lock();
        let _dir = isolated();
        add("home", "endpointaAAAA").unwrap();
        assert_eq!(lookup_ticket_or_bail("home").unwrap(), "endpointaAAAA");
        // Unknown name must bail rather than fall through to treating the
        // input as a raw ticket — long-lived secrets don't belong on the CLI.
        let err = lookup_ticket_or_bail("nope").unwrap_err();
        assert!(format!("{err:#}").contains("no saved host named \"nope\""));
        // A raw ticket string is also not a valid lookup key.
        let err = lookup_ticket_or_bail("endpointaZZZZ").unwrap_err();
        assert!(format!("{err:#}").contains("no saved host named"));
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
            "hosts file must be 0600, got {perms:o}"
        );
    }

    // The cross-process lock must be released when add() returns, so a
    // subsequent operation in the same process doesn't deadlock against a
    // held-open lock. (Tests the StoreLock acquire/drop path end-to-end.)
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
