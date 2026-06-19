#!/usr/bin/env python3
"""End-to-end smoke tests for `zuko`, run against a real Iroh network.

Two flows are exercised:

1. **host <-> connect (by saved name)** — spawn `zuko host`, read its current
   ticket out of the on-disk `current_ticket` file (the daemon keeps the
   long-lived ticket off stdout, so the only source is that file), seed the
   test's isolated hosts file with that ticket under a name, and drive
   `zuko connect <name>` under a PTY (the client's raw-mode path needs a
   controlling terminal). The connect path is the same one a real user hits
   after `zuko claim <code>`.

2. **share <-> claim** — with the host still running (so it writes
   `current_ticket`), spawn `zuko share`, capture the memorable code it
   prints, run `zuko claim <code> --no-connect --as e2e-claimed`, and confirm
   the claimed ticket matches the host's real one.

All zuko state (key, current_ticket, saved hosts) is isolated under a temp
`XDG_CONFIG_HOME` so the test never touches the operator's real config.

Requires: a network path to Iroh's public relays, and `python3` (stdlib only).

Usage:  python3 zuko/scripts/e2e_test.py [path/to/zuko]
"""

import os
import pty
import select
import shutil
import subprocess
import sys
import tempfile
import time

ZUKO = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else "zuko/target/release/zuko"
TOKEN = "hello-zuko-ITEST"
# Generous timeouts: Iroh relay handshakes can be slow on CI runners.
HOST_ONLINE_TIMEOUT = 60
CLIENT_WINDOW = 45
SHARE_CODE_TIMEOUT = 45
CLAIM_TIMEOUT = 90


def green(s):
    return f"\033[32m{s}\033[0m" if sys.stderr.isatty() else s


def red(s):
    return f"\033[31m{s}\033[0m" if sys.stderr.isatty() else s


def banner(msg):
    print(f"\n=== {msg} ===", file=sys.stderr, flush=True)


def wait_for_file(path, timeout):
    """Wait until `path` exists and has non-empty contents."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with open(path) as f:
                content = f.read().strip()
            if content:
                return content
        except OSError:
            pass
        time.sleep(0.25)
    return None


# ─────────────────────────── host <-> connect ──────────────────────────────

def run_client_under_pty(name, env):
    """Fork `zuko connect <name>` on a PTY, type `echo <TOKEN>`, expect echoed."""
    pid, fd = pty.fork()
    if pid == 0:
        # Child: become the client. The PTY is its controlling terminal, so
        # crossterm's enable_raw_mode on stdin works. The child inherits the
        # parent's os.environ, but the parent only built an `env` dict for
        # subprocess.Popen — so apply it here before exec so the client sees
        # the isolated XDG_CONFIG_HOME with our seeded saved-hosts file.
        os.environ.clear()
        os.environ.update(env)
        os.environ["RUST_LOG"] = ""
        os.execvp(ZUKO, [ZUKO, "connect", name])

    out = b""
    start = time.time()
    typed = False
    while time.time() - start < CLIENT_WINDOW:
        r, _, _ = select.select([fd], [], [], 0.5)
        if fd in r:
            try:
                data = os.read(fd, 4096)
            except OSError:
                break  # child closed the pty
            if not data:
                break
            out += data
        # Give the remote shell a moment to come up, then type the command once.
        if not typed and time.time() - start > 3.0:
            try:
                os.write(fd, b"echo " + TOKEN.encode() + b"\r")
            except OSError:
                break
            typed = True
        # Once the token is echoed back, leave the shell cleanly.
        if typed and TOKEN.encode() in out:
            try:
                os.write(fd, b"exit\r")
            except OSError:
                pass
            time.sleep(1.0)
            break
        if os.waitpid(pid, os.WNOHANG)[0] != 0:
            break
    try:
        os.close(fd)
    except OSError:
        pass
    return out


def seed_saved_host(env, name, ticket):
    """Write the test's saved-hosts file directly so we can exercise
    `zuko connect <name>` without going through the public OTP handoff for
    the connect test (the share/claim test below covers the handoff)."""
    zuko_dir = os.path.join(env["XDG_CONFIG_HOME"], "zuko")
    os.makedirs(zuko_dir, exist_ok=True)
    with open(os.path.join(zuko_dir, "hosts"), "w") as f:
        f.write(f"# zuko saved hosts (seeded by e2e_test.py)\n")
        f.write(f"{name}\t{ticket}\n")


def test_host_connect(env, name, ticket):
    banner("test: host <-> connect (by saved name)")
    seed_saved_host(env, name, ticket)
    out = run_client_under_pty(name, env)
    tail = out.decode(errors="replace")[-300:]
    print("---- client output (tail) ----", file=sys.stderr)
    print(tail, file=sys.stderr)
    print("-------------------------------", file=sys.stderr)
    if TOKEN.encode() not in out:
        print(red("FAIL: token not seen in client output"), file=sys.stderr)
        return False
    print(green("OK: client saw the shell's echo output"), file=sys.stderr)
    return True


# ─────────────────────────── share <-> claim ───────────────────────────────

def test_share_claim(env, expected_ticket):
    banner("test: share <-> claim")
    # `zuko share` reads current_ticket (written by the host), serves claims.
    share = subprocess.Popen(
        [ZUKO, "share", "--count", "1", "--timeout", "120", "--label", "e2e-host"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        env=env,
    )
    try:
        code = share.stdout.readline()
        # The first stdout line is the code; share's banner goes to stderr.
        # Be defensive: skip any leading blank, take the first non-empty line.
        while code is not None and code.strip() == b"":
            code = share.stdout.readline()
        if not code:
            print(red("FAIL: no code printed by `zuko share`"), file=sys.stderr)
            return False
        code = code.decode(errors="replace").strip()
        print(f"share code: {code}", file=sys.stderr)

        # `zuko claim <code>`: fetches the ticket, saves it under --as, and
        # (with --no-connect) skips the PTY session. The bare `zuko <code>`
        # shorthand dispatches to the same `handoff::claim` Rust function —
        # verified by unit tests for `code::looks_like_code`, so we don't
        # need a second network round-trip here.
        claim = subprocess.run(
            [ZUKO, "claim", code, "--no-connect", "--as", "e2e-claimed",
             "--timeout", str(CLAIM_TIMEOUT)],
            capture_output=True,
            env=env,
            timeout=CLAIM_TIMEOUT + 30,
        )
        if claim.returncode != 0:
            print(red(f"FAIL: `zuko claim` exited {claim.returncode}"), file=sys.stderr)
            print(claim.stderr.decode(errors="replace"), file=sys.stderr)
            return False

        # Confirm it landed in the saved-hosts file under the right name+ticket.
        # (`zuko ls` only prints names now, so read the hosts file directly to
        # also verify the saved ticket matches.)
        hosts_path = os.path.join(env["XDG_CONFIG_HOME"], "zuko", "hosts")
        with open(hosts_path) as f:
            hosts = f.read()
        print("---- saved hosts file ----", file=sys.stderr)
        print(hosts, file=sys.stderr)
        for line in hosts.splitlines():
            parts = line.split()
            if len(parts) == 2 and parts[0] == "e2e-claimed":
                if parts[1] != expected_ticket:
                    print(red(f"FAIL: claimed ticket != host ticket\n"
                              f"  claimed: {parts[1]}\n  host:    {expected_ticket}"),
                          file=sys.stderr)
                    return False
                print(green("OK: share/claim delivered the real ticket"), file=sys.stderr)
                return True
        print(red("FAIL: e2e-claimed not in saved-hosts file"), file=sys.stderr)
        return False
    finally:
        share.terminate()
        try:
            share.wait(timeout=5)
        except Exception:
            share.kill()


# ─────────────────────────────── runner ────────────────────────────────────

def main():
    if not os.path.isfile(ZUKO) or not os.access(ZUKO, os.X_OK):
        print(red(f"zuko binary not found or not executable: {ZUKO}\n"
                  f"build it first:  cargo build --release --manifest-path zuko/Cargo.toml"),
              file=sys.stderr)
        return 2

    # Isolate ALL zuko state (key, current_ticket, hosts) in a tempdir so the
    # test is hermetic and never touches the operator's real config.
    xdg = tempfile.mkdtemp(prefix="zuko-e2e-")
    env = dict(os.environ, XDG_CONFIG_HOME=xdg, RUST_LOG="info")
    print(f"XDG_CONFIG_HOME={xdg}", file=sys.stderr, flush=True)

    host = subprocess.Popen(
        [ZUKO, "host", "--shell", "/bin/sh"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        env=env,
    )
    failures = 0
    try:
        # The host keeps the long-lived ticket off stdout; read it from the
        # current_ticket file the daemon writes (the same source `zuko share`
        # reads).
        ticket_path = os.path.join(xdg, "zuko", "current_ticket")
        ticket = wait_for_file(ticket_path, HOST_ONLINE_TIMEOUT)
        if not ticket:
            print(red(f"FAIL: no ticket written to {ticket_path}"), file=sys.stderr)
            return 1
        print(f"host ticket: {ticket[:32]}...", file=sys.stderr)

        if not test_host_connect(env, "e2e-direct", ticket):
            failures += 1
        if not test_share_claim(env, ticket):
            failures += 1

        if failures == 0:
            print(green("\nITEST OK: all end-to-end checks passed"), file=sys.stderr)
            return 0
        print(red(f"\nITEST FAIL: {failures} check(s) failed"), file=sys.stderr)
        return 1
    finally:
        host.terminate()
        try:
            host.wait(timeout=5)
        except Exception:
            host.kill()
        shutil.rmtree(xdg, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())

