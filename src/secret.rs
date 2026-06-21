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

use anyhow::Result;
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
}
