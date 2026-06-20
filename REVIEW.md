# Code Quality Review

> Generated with [oy-cli](https://github.com/wagov-dtt/oy-cli): `OY_MODEL=glm-5.2 oy review workspace --focus 'Whole-workspace code-quality review'` · 2026-06-20

> Workspace review of the **zuko** repository — a remote-terminal-over-Iroh
> tool with a Rust host daemon + CLI client (`zuko/src/*.rs`), an iOS app
> (`ios/Zuko/Zuko/**/*.swift`), share/claim ticket-handoff, install scripts,
> and CI tooling.

**Scope:** 41 files, ~51k tokens, 1 deterministic chunk (reviewed in full).

This review supersedes the 2026-06-18 report. Of the 10 prior findings,
**9 are resolved** (F2–F10): the shared `secret::write_secret_0600` writer,
Argon2id key derivation, `fs4` flock on both the hosts file and key file,
Keychain-backed iOS storage, the `disconnectRequested` flag, explicit
`child.wait()`, and the `handoff`/`code`/`ticket_file`/`secret` module split
are all in place and well-tested. The codebase is meaningfully stronger than
two days ago. What remains is carried forward below, plus one new data-loss
bug found in the migration path.

---

## Verdict

**Needs work.**

The architecture is clean and the prior round of hardening landed well. Two
items still need attention before this tool should be trusted to expose a
shell on a host machine:

1. **[F1, carried forward, High]** The host grants a shell to **any** peer
   that negotiates the ALPN — the ticket (a bearer token) is the *only* gate,
   with no client authentication, no NodeId allow-list, no rate-limiting, and
   no revocation short of host-key rotation. This is a documented design
   choice (`docs/PROTOCOL.md` states "There is no authentication beyond
   possessing the ticket"), but a remote-shell tool providing arbitrary code
   execution benefits from defense-in-depth.
2. **[F2, new, Medium]** The iOS `ConnectionStore` migration from legacy
   `UserDefaults` to Keychain swallows Keychain save errors (`try?`) and then
   unconditionally deletes the legacy blob — silent, permanent data loss if
   the one-time migration write fails.

---

## Findings summary

| # | Severity | Type | Title | Location |
|---|----------|------|-------|----------|
| F1 | **High** | Security | Host grants a shell to any peer that negotiates ALPN — no client auth | `zuko/src/host.rs:154-158` (`serve`) |
| F2 | Medium | Data loss | iOS migration deletes legacy UserDefaults blob even when Keychain save fails (`try?`) | `ios/Zuko/Zuko/Models/ConnectionStore.swift:107-108` (`load`) |

**Resolved since the 2026-06-18 report** (dropped, no longer current):
hosts-file `0600` perms, iOS Keychain storage, Argon2id KDF, unified
`write_secret_0600`, `fs4` flock on hosts + key, `share.rs` decomposition,
`disconnectRequested` flag, logged decode failures, `child.wait()`.

---

## Detailed findings

### F1 — Host grants a shell to any peer that negotiates ALPN `zuko/1` (High)

**Location:** `zuko/src/host.rs:154-183` (`serve` — `accept()` + `accept_bi()`,
spawn shell).

**Evidence:**

```rust
async fn serve(incoming: iroh::endpoint::Incoming, ...) -> Result<()> {
    let conn = incoming.accept().context("accept connection")?
        .await.context("complete connection")?;
    let (mut send, mut recv) = conn.accept_bi().await.context("accept bidi stream")?;
    // ... immediately spawns a PTY + shell, no auth challenge ...
```

The endpoint is configured with only an ALPN filter (`Endpoint::builder(presets::N0).secret_key(secret).alpns(...)`). There is **no** client-authentication step, no `NodeId`
allow-list, no rate-limiting. The QUIC/TLS handshake proves the *host's*
identity to the client, but the host trusts every connecting peer identically.

**Why it matters:** `zuko host` provides **arbitrary code execution** on the
host. The ticket is printed to stderr, written to `current_ticket`, and handed
off via `zuko share`. Any of those paths can leak. There is **no revocation**
short of rotating the host key (which invalidates all saved connections). The
code's threat-model comments (ticket = secret, treat like an SSH key) are
coherent but offer no defense-in-depth.

**Design impact:** This is a documented choice (`docs/PROTOCOL.md`:
"There is no authentication beyond possessing the ticket"), not an oversight.
The code correctly implements its stated model. The recommendation below is
about hardening the boundary, not fixing a bug.

**Recommendation (pick at least one):**
- **Add an authentication frame** before the shell is spawned: the client sends
  a shared secret (a per-host password, or a client `SecretKey` whose `NodeId`
  is on an allow-list); the host verifies it on the bidi stream before
  `openpty`. A one-frame addition to `wire.rs` (`TYPE_AUTH`).
- **Restrict which `NodeId`s may connect** — store an allow-list alongside the
  host key.
- At minimum, **document the threat model prominently** in the README so
  operators understand that a leaked ticket = full shell access with no
  recovery until key rotation.

---

### F2 — iOS migration deletes legacy blob even when Keychain save fails (Medium)

**Location:** `ios/Zuko/Zuko/Models/ConnectionStore.swift:104-112` (`load`,
the migration branch).

**Evidence:**

```swift
// Migration: a pre-Keychain build wrote to UserDefaults. If the
// Keychain is empty but a legacy blob exists, move it over and clear
// the legacy entry.
guard let data = defaults.data(forKey: Self.legacyStorageKey) else {
    return []
}
do {
    let decoded = try JSONDecoder().decode([Connection].self, from: data)
    try? ConnectionKeychain.save(decoded)                    // ← swallows error
    defaults.removeObject(forKey: Self.legacyStorageKey)      // ← runs anyway
    return decoded
} catch { ... }
```

`try?` converts any Keychain error to `nil`, so `defaults.removeObject` runs
regardless of whether the save succeeded. If the Keychain write fails (device
locked, item locked, quota, etc.), the legacy `UserDefaults` blob is
permanently deleted and nothing was written to the Keychain. On the next launch
both stores are empty → all connections are gone.

**Why it matters:** This is a one-time migration path, so the window is small —
but the failure is **silent and permanent**. The decoded list is returned for
the current session, masking the problem. The primary Keychain path above it
correctly distinguishes "first launch" from "decode failure" and preserves the
corrupted blob; the migration path should do the same.

**Design impact:** The `try?` appears intentional ("best-effort migration"),
but the follow-up `removeObject` turns a best-effort into a destructive
operation. The fix is a one-line gate: only delete the legacy entry after
confirming the save succeeded.

**Recommendation:**

```swift
do {
    let decoded = try JSONDecoder().decode([Connection].self, from: data)
    try ConnectionKeychain.save(decoded)  // propagate; do not swallow
    defaults.removeObject(forKey: Self.legacyStorageKey)
    return decoded
} catch {
    logger.error("Migration failed; keeping legacy entry: \(String(describing: error))")
    return decoded  // keep legacy entry on disk for the next attempt
}
```

This keeps the legacy blob in place until the Keychain write succeeds, so a
transient Keychain failure is retried on the next launch instead of being a
permanent silent data-loss event.

---

```oy-findings
[
  {
    "id": "F1",
    "type": "security",
    "severity": "high",
    "title": "Host grants a shell to any peer that negotiates ALPN zuko/1 — no client authentication, allow-list, or rate-limiting (carried forward; documented design choice, but no defense-in-depth for arbitrary code execution)",
    "locations": [
      "zuko/src/host.rs:154-158 (serve, accept + accept_bi)",
      "zuko/src/host.rs:175-183 (spawn shell)"
    ]
  },
  {
    "id": "F2",
    "type": "data-loss",
    "severity": "medium",
    "title": "iOS ConnectionStore migration uses try? on Keychain save then unconditionally deletes the legacy UserDefaults blob — silent permanent data loss if the one-time migration write fails",
    "locations": [
      "ios/Zuko/Zuko/Models/ConnectionStore.swift:104-112 (load, migration branch)"
    ]
  }
]
```

---

## What's done well

- **Prior hardening landed cleanly.** The shared `secret::write_secret_0600`,
  Argon2id KDF in `code.rs`, `fs4` flock in both `store.rs` and `host.rs`, the
  Keychain-backed `ConnectionKeychain`, the `disconnectRequested` flag, and the
  `handoff`/`code`/`ticket_file`/`secret` module split are all in place with
  good tests — 9 of 10 prior findings resolved in two days.
- **Wire protocol** (`wire.rs` / `Wire.swift`) remains simple, length-prefixed,
  and mirrored exactly between Rust and Swift, with thorough unit tests.
- **Concurrency discipline** in `host.rs`, `client.rs`, and `IrohSession.swift`
  is clean: single writer owns the send stream, PTY writes serialised via a
  channel, teardown uses `tokio::select!` / cancellation flags correctly.
- **Secret-file handling is now uniform** — one `write_secret_0600` (atomic
  temp + `sync_all` + rename + `0600`) covers the key, ticket, and hosts file,
  each with a `0600` perms test.
- **Cross-process locking** (`HostsLock`, `KeyLock`) with a separate `.lock`
  inode so the atomic rename can't orphan it — a subtle detail handled right.
- **E2E test harness** (`e2e_test.py`) exercises both flows against the live
  Iroh network with isolated state under a temp `XDG_CONFIG_HOME`.
- **Thorough module-level docs** throughout; the code explains *why* (the race
  the lock prevents, the threat model the KDF addresses, the framing invariant
  the serial writer guarantees).
