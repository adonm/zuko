//! Atomic, restrictive-permission writes for files that carry secrets.
//!
//! Every zuko-controlled file that grants shell access — the host's persistent
//! `key`, the live `current_ticket`, and the saved `hosts` list — is written
//! here through one tested implementation:
//!
//! 1. Create the parent dir if missing.
//! 2. Write to `<path>.tmp` with `0600` perms on Unix.
//! 3. `sync_all` so a crash after the rename never leaves a torn file.
//! 4. `rename` over the target for an atomic cutover.
//!
//! The non-Unix fallback drops the perm hint (Windows etc. enforce ACLs per
//! user, not via a mode bit) but keeps the temp + rename dance so the write
//! stays atomic on every platform.

use anyhow::{Context, Result};
use std::path::Path;

/// Atomically replace `path` with `bytes`, creating the parent dir and applying
/// `0600` perms on Unix. Errors short-circuit before the rename, so a failed
/// write never corrupts the existing file.
pub fn write_secret_0600(path: &Path, bytes: &[u8]) -> Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).ok();
    }
    let tmp = path.with_extension("tmp");
    #[cfg(unix)]
    {
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&tmp)?;
        f.write_all(bytes)?;
        f.sync_all()?;
    }
    #[cfg(not(unix))]
    {
        std::fs::write(&tmp, bytes)?;
    }
    std::fs::rename(&tmp, path)?;
    Ok(())
}

// ────────────────────── persistent identity keys ──────────────────────────

/// Race-safe create-or-read for a persistent [`iroh::SecretKey`].
///
/// Both the host (`~/.config/zuko/key`) and the client
/// (`~/.config/zuko/client_key`) need a stable identity: the host so its node
/// id — and thus every saved connection — survives restarts, the client so it
/// always derives the same reattach token for a given host (and so its own
/// node id is stable). Two processes starting at once on a fresh install would
/// otherwise each generate a different key and the second write would clobber
/// the first, silently flipping the identity under existing state.
///
/// We hold an exclusive flock on a sibling `.lock` file across the
/// check-create-write transaction. The lock is on a separate inode so the
/// atomic 0600 temp+rename can't orphan it (and so it's safe to leave on disk).
pub fn load_or_create_key(path: &Path) -> Result<iroh::SecretKey> {
    let _guard = KeyLock::acquire(path)?;

    if path.exists() {
        return read_key(path);
    }

    // Sole creator (any concurrent caller is blocked on the flock above).
    // Generate, write atomically through the shared 0600 writer so a crash
    // mid-write can never leave a truncated file the next start would reject
    // as "not 32 bytes" (silently invalidating every saved connection).
    let secret = iroh::SecretKey::generate();
    write_secret_0600(path, &secret.to_bytes())?;
    Ok(secret)
}

fn read_key(path: &Path) -> Result<iroh::SecretKey> {
    let bytes = std::fs::read(path).with_context(|| format!("read key {}", path.display()))?;
    if bytes.len() != 32 {
        anyhow::bail!("key file {} is not 32 bytes", path.display());
    }
    let mut arr = [0u8; 32];
    arr.copy_from_slice(&bytes);
    Ok(iroh::SecretKey::from_bytes(&arr))
}

/// Cross-process advisory lock guarding the read-or-create transaction in
/// [`load_or_create_key`]. Lives at `<key>.lock` (a separate path so the
/// atomic `key` temp+rename never orphans the lock inode), held until the guard
/// is dropped.
struct KeyLock(std::fs::File);

impl KeyLock {
    fn acquire(key_path: &Path) -> Result<Self> {
        let lock_path = key_path.with_extension("lock");
        if let Some(parent) = lock_path.parent() {
            std::fs::create_dir_all(parent)
                .with_context(|| format!("mkdir {}", parent.display()))?;
        }
        let f = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(&lock_path)
            .with_context(|| format!("open {}", lock_path.display()))?;
        fs4::fs_std::FileExt::lock_exclusive(&f)?;
        Ok(Self(f))
    }
}

impl Drop for KeyLock {
    fn drop(&mut self) {
        let _ = fs4::fs_std::FileExt::unlock(&self.0);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(unix)]
    #[test]
    fn writes_with_0600_perms() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("secret");
        write_secret_0600(&target, b"hello").unwrap();

        let perms = std::fs::metadata(&target).unwrap().permissions().mode();
        assert_eq!(
            perms & 0o777,
            0o600,
            "secret file must be 0600, got {perms:o}"
        );
        assert_eq!(std::fs::read(&target).unwrap(), b"hello");
    }

    #[test]
    fn existing_file_is_replaced_atomically() {
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("secret");
        write_secret_0600(&target, b"old").unwrap();
        write_secret_0600(&target, b"new").unwrap();
        assert_eq!(std::fs::read(&target).unwrap(), b"new");
        // The temp file must not linger after a successful rename.
        assert!(!dir.path().join("secret.tmp").exists());
    }

    // Two concurrent `load_or_create_key` calls on a fresh path must converge
    // on the *same* key — the flock is the gatekeeper, so the loser reads the
    // winner's bytes back. Without the race-safety this test would fail
    // intermittently with mismatched `to_bytes()` (and on a real host, a
    // silent node-id flip under any saved connection).
    #[test]
    fn concurrent_creates_converge_on_one_key() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("key");

        const N: usize = 8;
        let path = std::sync::Arc::new(path);
        let keys: Vec<[u8; 32]> = (0..N)
            .map(|_| {
                let p = std::sync::Arc::clone(&path);
                std::thread::spawn(move || load_or_create_key(&p).unwrap().to_bytes())
            })
            .collect::<Vec<_>>()
            .into_iter()
            .map(|h| h.join().unwrap())
            .collect();

        let first = keys[0];
        for (i, k) in keys.iter().enumerate() {
            assert_eq!(k, &first, "thread {i} observed a different key");
        }

        let on_disk = std::fs::read(&*path).unwrap();
        assert_eq!(
            &on_disk[..],
            &first[..],
            "on-disk key diverges from in-memory"
        );

        // Calling again on the existing file must read back the same key
        // (sanity check the read path).
        let again = load_or_create_key(&path).unwrap().to_bytes();
        assert_eq!(again, first);
    }

    #[cfg(unix)]
    #[test]
    fn created_key_file_is_0600() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("key");
        let _ = load_or_create_key(&path).unwrap();
        let perms = std::fs::metadata(&path).unwrap().permissions().mode();
        assert_eq!(perms & 0o777, 0o600, "key file must be 0600, got {perms:o}");
    }
}
