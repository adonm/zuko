# Code Quality Review

> Generated with [oy-cli](https://github.com/wagov-dtt/oy-cli): `OY_MODEL=glm-5.2 oy review workspace --focus 'Whole-workspace code-quality review'` · 2026-06-18

Workspace review of the **zuko** repository — a remote-terminal-over-Iroh tool
with a Rust host daemon + CLI client (`zuko/src/*.rs`), an iOS app
(`ios/Zuko/Zuko/**/*.swift`), share/claim ticket-handoff, install scripts, and
CI tooling.

**Scope:** 38 files, ~37k tokens, 1 deterministic chunk (reviewed in full).
Skipped non-actionable content: `LICENSE`, JSON asset stubs, pure-markdown docs.

---

## Verdict

**Needs work.**

The architecture is clean, well-documented, and the Rust/Swift implementations
are generally high quality with good concurrency discipline and thorough tests.
However, several security properties need hardening before this tool should be
trusted to expose a shell on a host machine:

1. The host grants a shell to **any** peer that negotiates the ALPN — the ticket
   (a bearer token) is the *only* gate, and there is no client authentication,
   revocation, or rate-limiting.
2. Dialing-secret tickets are persisted **world-readable** (`0644`) in the
   `hosts` file and in **plaintext UserDefaults** on iOS — neither location is
   appropriate for bearer tokens that grant arbitrary code execution.

These are fixable without restructuring the protocol; the medium/low findings
are code-quality and robustness improvements.

---

## Findings summary

| # | Severity | Type | Title | Location |
|---|----------|------|-------|----------|
| F1 | **High** | Security | Host grants a shell to any peer that negotiates ALPN — no client auth | `host.rs:154-183` |
| F2 | **High** | Security | `hosts` file stores dialing-secret tickets without `0600` perms | `store.rs:119-131` |
| F3 | **High** | Security | iOS tickets in UserDefaults instead of Keychain | `ConnectionStore.swift:14-16,85-89` |
| F4 | Medium | Security | `derive_key` uses single unsalted SHA-256 — share codes brute-forceable offline | `share.rs:329-337` |
| F5 | Medium | Correctness | Duplicated/inconsistent secret-file writers; host key written non-atomically | `host.rs:241-256`, `share.rs:439-462` |
| F6 | Medium | Correctness | `store.rs` has no cross-process file lock — concurrent `add`/`rm` lose updates | `store.rs:84-115` |
| F7 | Medium | Maintainability | `share.rs` (500+ lines) mixes 5+ concerns | `share.rs` (whole file) |
| F8 | Low | Maintainability | iOS `IrohSession` uses fragile string-equality on disconnect status | `IrohSession.swift:48-56,103-105` |
| F9 | Low | Data loss | iOS `ConnectionStore.load()` silently drops all connections on decode failure | `ConnectionStore.swift:78-83` |
| F10 | Low | Correctness | Host kills child PTY without `wait()` — relies on Drop for reaping | `host.rs:192-194` |

---

## Detailed findings

### F1 — Host grants a shell to any peer that negotiates ALPN `zuko/1` (High)

**Location:** `zuko/src/host.rs:154-183` (`serve` — `accept()` + `accept_bi()`,
spawn shell).

**Evidence:**

```rust
async fn serve(incoming: iroh::endpoint::Incoming, ...) -> Result<()> {
    let conn = incoming
        .accept()
        .context("accept connection")?
        .await
        .context("complete connection")?;
    let (mut send, mut recv) = conn.accept_bi().await.context("accept bidi stream")?;
    // ... immediately spawns a PTY + shell, no auth challenge ...
```

The endpoint is configured with only an ALPN filter:
```rust
Endpoint::builder(presets::N0)
    .secret_key(secret)
    .alpns(vec![ALPN.to_vec()])
    .bind().await
```

There is **no** client-authentication step, no password/key challenge, no
allow-list of authorized `NodeId`s, and no rate-limiting. The QUIC/TLS
handshake proves the *host's* identity to the client, but the host trusts every
connecting peer identically.

**Why it matters:** `zuko host` provides **arbitrary code execution** on the
host machine. The only protection is that a would-be attacker must know the
host's `NodeId` + addresses (the "ticket"). Iroh node IDs are Ed25519 public
keys — not guessable, but **not designed to be secret** either. The ticket is
printed to stdout, written to `current_ticket`, logged to journald/launchd
logs, and handed off via the `share` mechanism (codes typed, pasted, sent over
chat). Any of these is a leakage path, and there is **no revocation** short of
rotating the host key (which invalidates all saved connections).

**Design impact:** The code comments acknowledge the ticket is a "dialing
secret (anyone holding it can connect)", which is a coherent but thin threat
model for a remote-shell tool. There is no defense-in-depth.

**Recommendation (pick at least one):**
- **Add an authentication frame** before the shell is spawned: the client sends
  a shared secret (a per-host password, or a client `SecretKey` whose `NodeId`
  is on an allow-list); the host verifies it on the bidi stream before
  `openpty`. This is a one-frame addition to `wire.rs` (`TYPE_AUTH`).
- **Restrict which `NodeId`s may connect** — store an allow-list alongside the
  host key, or require the client to prove ownership of a key the host trusts.
- At minimum, **document the threat model prominently** in the README so
  operators understand that a leaked ticket = full shell access with no
  recovery until key rotation.

---

### F2 — `hosts` file stores dialing-secret tickets without `0600` perms (High)

**Location:** `zuko/src/store.rs:119-131` (`store`).

**Evidence:**

```rust
fn store(entries: &[(String, String)]) -> Result<()> {
    ...
    let mut f = fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .open(&tmp)?;   // ← no .mode(0o600) on Unix
    f.write_all(body.as_bytes())?;
    ...
    fs::rename(tmp, &path)?;
```

Compare with `share.rs:439-462` (`write_secret_0600`), which **correctly** sets
`0o600` for `key` and `current_ticket`:

```rust
let mut f = std::fs::OpenOptions::new()
    ...
    .mode(0o600)
    .open(&tmp)?;
```

**Why it matters:** The `hosts` file contains the same kind of bearer-token
tickets as `current_ticket` — each one grants shell access to a host. Under a
typical umask of `022`, `store()` creates the file as **`0644`**, readable by
any user on the system. On multi-user boxes or shared CI runners, any local
user can `cat ~/.config/zuko/hosts` and steal every saved ticket.

**Recommendation:** Add `.mode(0o600)` (gated by `#[cfg(unix)]`) to the
`OpenOptions` in `store()`, exactly as `write_secret_0600` does. Better: reuse
`write_secret_0600` (see F5) so all secret-bearing files share one tested
implementation.

---

### F3 — iOS tickets stored in UserDefaults instead of Keychain (High)

**Location:** `ios/Zuko/Zuko/Models/ConnectionStore.swift:14-16,85-89`.

**Evidence:**

```swift
private static let storageKey = "dev.adonm.zuko.connections.v1"
private let defaults: UserDefaults
...
private func save() {
    if let data = try? JSONEncoder().encode(connections) {
        defaults.set(data, forKey: Self.storageKey)
    }
}
```

**Why it matters:** `Connection.ticket` is a bearer token that grants shell
access. `UserDefaults` serializes to a plist in the app sandbox, protected by
`NSFileProtectionCompleteUntilFirstUserAuthentication` by default — the file is
decrypted after the first unlock and stays readable in memory and on disk. A
forensic attacker with physical access to an unlocked device (or a compromised
backup) can extract the tickets. Apple's **Keychain** is the correct store for
secrets: it uses hardware-backed key protection (`Secure Enclave` on supported
devices), per-item access control, and is not included in unencrypted backups.

**Recommendation:** Move the ticket payload (or the entire encoded
`Connection`) into the Keychain using `kSecClassGenericPassword` keyed by the
connection UUID, or use a lightweight wrapper like
[KeychainAccess](https://github.com/kishikawakatsumi/KeychainAccess). Keep
non-sensitive metadata (label, `addedAt`, short node id) in `UserDefaults` if
desired, but the **ticket string** must go in Keychain.

---

### F4 — `derive_key` uses single unsalted SHA-256 (Medium)

**Location:** `zuko/src/share.rs:329-337`.

**Evidence:**

```rust
fn derive_key(code: &str) -> SecretKey {
    let material = normalize_code(code);
    let mut hasher = Sha256::new();
    hasher.update(material.as_bytes());
    let digest = hasher.finalize();
    let mut seed = [0u8; 32];
    seed.copy_from_slice(&digest);
    SecretKey::from_bytes(&seed)
}
```

**Why it matters:** The share code has ~52 bits of entropy (4 × CVCV words).
A single SHA-256 (no salt, no stretching) means an attacker who learns the
ephemeral `NodeId` (which is `derive_key(code).public()`) can brute-force the
code **offline**: for each candidate code, compute one SHA-256 + one Ed25519
public-key derivation and compare. At ~52 bits this is feasible on commodity
GPUs in days. The current threat-model comment ("far beyond reach for online
guessing during the minutes-long window") is correct for **online** attacks
but does not account for **offline** brute-force if the ephemeral `NodeId` is
observed (network capture, DNS-resolver visibility, or log exposure).

**Recommendation:** Replace the raw hash with a memory-hard KDF:
[argon2](https://docs.rs/argon2) (already in the Rust ecosystem) with
appropriate memory/time parameters, or at minimum PBKDF2-HMAC-SHA256 with a
high iteration count. This raises the per-guess cost by orders of magnitude,
making offline brute-force impractical even if the ephemeral `NodeId` leaks.
The trade-off is a few hundred milliseconds of derivation time on both sides —
acceptable for a one-time handoff.

---

### F5 — Duplicated/inconsistent secret-file writers; host key is non-atomic (Medium)

**Location:** `zuko/src/host.rs:241-256` (`write_secret`) vs
`zuko/src/share.rs:439-462` (`write_secret_0600`).

**Evidence:**

`host.rs::write_secret` — writes **directly** to the target path, non-atomic:
```rust
fn write_secret(path: &PathBuf, bytes: &[u8]) -> Result<()> {
    #[cfg(unix)] {
        let mut f = std::fs::OpenOptions::new()
            .write(true).create(true).truncate(true).mode(0o600)
            .open(path)?;     // ← no temp + rename
        f.write_all(bytes)?;
    }
    ...
}
```

`share.rs::write_secret_0600` — uses **atomic** temp + rename, and `sync_all`:
```rust
fn write_secret_0600(path: &std::path::Path, bytes: &[u8]) -> Result<()> {
    ...
    let tmp = path.with_extension("tmp");
    let mut f = ... .mode(0o600).open(&tmp)?;
    f.write_all(bytes)?;
    f.sync_all()?;
    std::fs::rename(&tmp, path)?;   // ← atomic
    ...
}
```

**Why it matters:** Two problems compound:
1. **Duplication:** Two near-identical implementations that can drift (and
   already have — one syncs, one doesn't).
2. **The critical path gets the weaker version:** The host's persistent
   **secret key** (`~/.config/zuko/key`) is written by the non-atomic
   `write_secret`. A crash or power loss mid-write could leave a truncated key
   file, which `load_or_create_key` would then reject ("not 32 bytes"),
   causing the host to **generate a new key** on next start — invalidating all
   saved connections silently. The less-critical ticket file gets the safer
   atomic write.

**Recommendation:** Extract a single `write_secret_0600` into a shared module
(e.g., `crate::fsutil` or `crate::secret`) and use it for **both** the key and
the ticket. Ensure the atomic version (temp + `sync_all` + rename) is used
everywhere.

---

### F6 — `store.rs` has no cross-process file lock (Medium)

**Location:** `zuko/src/store.rs:84-115` (`add`, `remove`, `store`).

**Evidence:** `add` and `remove` both do `load()` → mutate → `store()` with no
file lock. The atomic rename prevents **corruption** but not **lost updates**:
two concurrent `zuko add` processes each load the same list, append their
entry, and the second rename overwrites the first.

**Why it matters:** On multi-user or automated systems, concurrent edits
silently drop entries. The in-file comment ("do not edit by hand if a
`zuko add` is running") acknowledges the race but doesn't prevent it.

**Recommendation:** Take an `flock(2)` (or `fd-lock`/`fs2` crate) advisory lock
on the hosts file for the duration of the load-mutate-store transaction. On
Unix: `fcntl(F_SETLK)`; the `fs4` crate provides a cross-platform wrapper.

---

### F7 — `share.rs` (500+ lines) mixes 5+ concerns (Medium)

**Location:** `zuko/src/share.rs` (whole file, 500+ lines).

The module currently bundles:
- **Share** (host-side handoff server, `share()`)
- **Claim** (client-side handoff, `claim()`)
- **Wire framing** for the handoff (`serve_handoff`, `read_to_end`)
- **Code generation + key derivation** (`generate_code`, `derive_key`,
  `normalize_code`, `pick`)
- **Label sanitization** (`sanitize_label`, `default_label`)
- **Ticket-file I/O** (`current_ticket_path`, `write_current_ticket`,
  `read_current_ticket`, `write_secret_0600`)

**Recommendation:** Decompose into focused modules:
- `handoff.rs` — `share()` + `claim()` + handoff wire helpers.
- `code.rs` — `generate_code`, `derive_key`, `normalize_code`, `pick`,
  `sanitize_label`, `default_label` (pure functions, easy to unit-test in
  isolation).
- `ticket_file.rs` — `current_ticket_path`, `write_current_ticket`,
  `read_current_ticket`, and the shared `write_secret_0600` (also used by
  `host.rs`, see F5).

This improves navigability, test surface, and makes it trivial to reuse
`write_secret_0600` across `host` and `share` (fixing F5).

---

### F8 — iOS `IrohSession` fragile string-equality on disconnect status (Low)

**Location:** `ios/Zuko/Zuko/Net/IrohSession.swift:48-56,103-105`.

`disconnect()` sets `status = .disconnected("disconnected")`, then the
cancellation handler checks:
```swift
if status != .disconnected("disconnected") {
    status = .disconnected("cancelled")
}
```

This compares the full enum (including the associated `String`) to detect an
intentional disconnect. If the string literal changes in one place but not the
other, the check silently breaks and intentional disconnects are misreported as
"cancelled".

**Recommendation:** Track intent with a dedicated `Bool` flag (e.g.,
`private var disconnectRequested = false`) set in `disconnect()` and checked in
the `CancellationError` handler, rather than string-matching on status.

---

### F9 — iOS `ConnectionStore.load()` silently drops all connections on decode failure (Low)

**Location:** `ios/Zuko/Zuko/Models/ConnectionStore.swift:78-83`.

```swift
guard let data = defaults.data(forKey: Self.storageKey),
      let decoded = try? JSONDecoder().decode([Connection].self, from: data)
else { return [] }
```

A `Codable` schema change (or corrupted data) causes `load()` to return `[]`,
which is then persisted by the next `save()` — **permanently deleting** all
saved connections with no user-visible error.

**Recommendation:** Log or surface the decode error, and consider a versioned
migration strategy (the `v1` in the storage key suggests foresight — add a
`v2` decode path before falling back to empty). At minimum, do not call
`save()` on the empty result of a failed decode.

---

### F10 — Host kills child PTY without `wait()` (Low)

**Location:** `zuko/src/host.rs:192-194`.

```rust
let _ = child.kill();
Ok(())
```

`kill()` sends `SIGKILL` but does not reap the child. The `child` is then
dropped at scope exit; `portable_pty`'s `Child` `Drop` *should* reap, but the
behavior is implicit and not guaranteed across all backends. On long-running
hosts with many sessions, a backend that doesn't reap in `Drop` would leak
zombies.

**Recommendation:** Call `child.wait()` (or `child.wait_timeout(...)`) after
`kill()` to explicitly reap. This makes the lifecycle unambiguous.

---

```oy-findings
[
  {
    "id": "F1",
    "type": "security",
    "severity": "high",
    "title": "Host grants a shell to any peer that negotiates ALPN zuko/1 — no client authentication",
    "locations": [
      "zuko/src/host.rs:154-158 (serve, accept + accept_bi)",
      "zuko/src/host.rs:175-183 (spawn shell)"
    ]
  },
  {
    "id": "F2",
    "type": "security",
    "severity": "high",
    "title": "Saved-hosts file (~/.config/zuko/hosts) stores dialing-secret tickets without 0600 permissions",
    "locations": ["zuko/src/store.rs:119-131 (store)"]
  },
  {
    "id": "F3",
    "type": "security",
    "severity": "high",
    "title": "iOS ConnectionStore persists bearer-token tickets in UserDefaults instead of Keychain",
    "locations": [
      "ios/Zuko/Zuko/Models/ConnectionStore.swift:14-16 (storageKey, defaults)",
      "ios/Zuko/Zuko/Models/ConnectionStore.swift:85-89 (save)"
    ]
  },
  {
    "id": "F4",
    "type": "security",
    "severity": "medium",
    "title": "derive_key uses a single unsalted SHA-256 instead of a password KDF, making share codes brute-forceable offline",
    "locations": [
      "zuko/src/share.rs:329-337 (derive_key)",
      "zuko/src/share.rs:11-21 (threat-model comment)"
    ]
  },
  {
    "id": "F5",
    "type": "correctness",
    "severity": "medium",
    "title": "Duplicated/inconsistent secret-file writers: the more-critical host key is written non-atomically while the ticket uses atomic rename",
    "locations": [
      "zuko/src/host.rs:241-256 (write_secret)",
      "zuko/src/share.rs:439-462 (write_secret_0600)"
    ]
  },
  {
    "id": "F6",
    "type": "correctness",
    "severity": "medium",
    "title": "store.rs has no cross-process file lock — concurrent zuko add/rm lose updates (last writer wins)",
    "locations": ["zuko/src/store.rs:84-115 (add, remove, store)"]
  },
  {
    "id": "F7",
    "type": "maintainability",
    "severity": "medium",
    "title": "share.rs (500+ lines) mixes 5+ concerns — share/claim, code generation, key derivation, label sanitization, and ticket-file I/O",
    "locations": ["zuko/src/share.rs (whole file)"]
  },
  {
    "id": "F8",
    "type": "maintainability",
    "severity": "low",
    "title": "iOS IrohSession uses fragile string-equality on .disconnected(\"disconnected\") to distinguish intentional disconnect from cancellation",
    "locations": [
      "ios/Zuko/Zuko/Net/IrohSession.swift:48-56 (disconnect)",
      "ios/Zuko/Zuko/Net/IrohSession.swift:103-105 (CancellationError check)"
    ]
  },
  {
    "id": "F9",
    "type": "data-loss",
    "severity": "low",
    "title": "iOS ConnectionStore.load() silently drops all saved connections on any Codable decode failure",
    "locations": ["ios/Zuko/Zuko/Models/ConnectionStore.swift:78-83 (load)"]
  },
  {
    "id": "F10",
    "type": "correctness",
    "severity": "low",
    "title": "Host kills the child PTY process without wait() — relies on Drop for reaping",
    "locations": ["zuko/src/host.rs:192-194 (child.kill)"]
  }
]
```

---

## What's done well

- **Wire protocol** (`wire.rs` / `Wire.swift`) is simple, length-prefixed, and
  mirrored exactly between Rust and Swift — with good unit tests on both sides.
- **Concurrency discipline** in `host.rs` and `client.rs` is clean: a single
  writer owns the send stream, PTY writes are serialized via a channel, and
  teardown uses `tokio::select!` correctly.
- **The `share`/`claim` design** (throwaway code-derived key, distinct ALPN,
  croc-style handoff) is well-reasoned and the threat model is documented.
- **Atomic file writes** (temp + `sync_all` + rename) and `0600` perms are
  applied to the key and ticket files — the pattern just needs to be applied
  consistently (F2, F5).
- **E2E test harness** (`e2e_test.py`) exercises both flows against the live
  Iroh network with isolated state — good integration coverage.
- **Thorough module-level docs** throughout; the code explains *why*, not just
  *what*.
