# Direction and roadmap

## North star

zuko provides **private remote shells for machines you own, without opening
inbound ports or operating a VPN**.

The primary user is a developer, self-hoster, or small operator connecting to a
personal Linux or macOS machine. The complete core workflow should stay short:

1. install a per-user host service;
2. pair a device with a one-time code;
3. reconnect by a memorable name;
4. survive brief network changes;
5. inspect or revoke access locally.

Iroh owns network reachability and encrypted transport. zuko owns the PTY,
pairing, authorization, reconnect behavior, and clear operator feedback.

## Product tiers

| Tier | Meaning | Current surfaces |
|------|---------|------------------|
| **Core** | Primary maintained and release-gated workflow | Linux/macOS host and Rust CLI |
| **Beta** | Intended for regular use, but availability or compatibility is not yet stable | iOS/iPadOS client |
| **Labs** | Opt-in experiments used to learn; APIs and behavior may change | Browser client and Linux `zuko app` |

A surface moves up a tier only when it has a clear install path, recovery
behavior, security boundary, automated coverage, and maintained documentation.
Code existing in the repository is not by itself a support commitment.

## Current priority: make the core boring

Work toward the next release should improve the host + CLI workflow before
adding another client or transport:

- make service state and connection failures easy to diagnose;
- test pairing, authorization, revocation, reconnect, and shell-exit behavior;
- make install, upgrade, reset, and recovery steps predictable on Linux/macOS;
- document version/protocol compatibility and return actionable errors;
- keep queues, retries, handshakes, and detached leases bounded;
- keep secret storage and the pairing trust boundary reviewable.

Success means a user can recover from a stale pairing, lost client, relay
change, service restart, or interrupted upgrade without understanding Iroh or
reading source code.

### Completed foundations

- **0.8.5:** added one read-only `zuko doctor` path for service, host key,
  ticket, local trust state, and bounded Iroh relay checks;
- **0.8.5:** added live-network coverage proving revoked clients receive a
  permanent authorization error instead of entering a reconnect loop;
- **0.8.5:** documented the protocol compatibility boundary and aligned the
  security model across native and browser clients.

## Toward 1.0

The core is ready for a 1.0 stability promise when all of these are true:

- the host and CLI have a documented compatibility policy;
- Linux and macOS install, upgrade, reset, and uninstall paths are exercised in
  release checks;
- end-to-end tests cover authorization failure and transient reconnects as well
  as initial pairing and PTY I/O;
- protocol fixtures are shared with non-Rust clients;
- security documentation matches the implementation and has had focused review;
- releases state supported platforms, known limitations, and migration steps.

No calendar date is attached to 1.0. These outcomes are the gate.

## Beta and Labs promotion

### iOS/iPadOS beta

Promote to Core after there is a documented public install path, a sustainable
deployment target, release compatibility checks, and parity for reconnect and
authorization errors. Until then it remains a useful source-built/TestFlight
beta rather than a generally available client.

### Browser Labs client

Keep in Labs until it has reconnect/backoff, browser-level tests, and storage on
a dedicated hardened origin. Browser Iroh remains relay-only. If those costs do
not justify the use case, keep it as a pairing/protocol demonstration rather
than expanding the core promise.

### `zuko app` Labs feature

Keep the Kitty/cage path opt-in. Promote only if terminal compatibility,
failure recovery, runtime dependencies, and interactive performance are
reliable enough to support. Native video or a separate remote-desktop protocol
is not on the active roadmap.

## Explicitly deferred

These may be reconsidered when a demonstrated user need outweighs their ongoing
cost, but they are not current goals:

- Android and additional native clients;
- durable PTY storage or output replay (use `tmux`, `zellij`, or `screen`);
- full desktop streaming or a native video protocol;
- centralized accounts, RBAC, audit pipelines, or enterprise fleet management;
- zero-downtime daemon upgrades;
- broad plugin or protocol-negotiation frameworks without a concrete client.

## Decision filter

Prefer work that makes the core workflow safer, faster to understand, easier to
recover, or easier to verify. A proposal that adds a platform, protocol, or
long-running service should identify the core user problem, maintenance cost,
security boundary, tests, and promotion tier before implementation.

When priorities conflict, use this order:

1. prevent unauthorized shell access or secret loss;
2. preserve shell correctness and recoverability;
3. improve pairing, diagnostics, and trust management;
4. improve resource use and maintainability;
5. expand Beta or Labs capabilities.
