#!/usr/bin/env python3
"""End-to-end smoke tests for `zuko`, run against a real Iroh network.

Two flows are exercised:

1. **host <-> connect** — spawn `zuko host`, grab the ticket it prints, drive
   `zuko connect <ticket>` under a PTY (the client's raw-mode path needs a
   controlling terminal), type a command, and confirm the shell's output
   comes back.

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
HOST_TICKET_TIMEOUT = 60
CLIENT_WINDOW = 45
SHARE_CODE_TIMEOUT = 45
CLAIM_TIMEOUT = 90


def green(s):
    return f"\033[32m{s}\033[0m" if sys.stderr.isatty() else s


def red(s):
    return f"\033[31m{s}\033[0m" if sys.stderr.isatty() else s


def banner(msg):
    print(f"\n=== {msg} ===", file=sys.stderr, flush=True)


def wait_for_line(proc, prefix, timeout):
    """Read proc.stdout line-by-line until one starts with `prefix`."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        line = proc.stdout.readline()
        if not line:
            time.sleep(0.1)
            continue
        text = line.decode(errors="replace").strip()
        if text.startswith(prefix):
            return text
    return None


# ─────────────────────────── host <-> connect ──────────────────────────────

def run_client_under_pty(ticket):
    """Fork `zuko connect` on a PTY, type `echo <TOKEN>`, expect it echoed."""
    pid, fd = pty.fork()
    if pid == 0:
        # Child: become the client. The PTY is its controlling terminal, so
        # crossterm's enable_raw_mode on stdin works.
        os.environ["RUST_LOG"] = ""
        os.execvp(ZUKO, [ZUKO, "connect", ticket])

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


def test_host_connect(env, ticket):
    banner("test: host <-> connect")
    out = run_client_under_pty(ticket)
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
    # `zuko share` reads current_ticket (written by the host), serves one claim.
    share = subprocess.Popen(
        [ZUKO, "share", "--count", "1", "--timeout", "120", "--label", "e2e-host"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        env=env,
    )
    try:
        code = wait_for_line(share, prefix="", timeout=SHARE_CODE_TIMEOUT)
        # The first stdout line is the code; share's banner goes to stderr.
        # Be defensive: skip any leading blank, take the first non-empty line.
        # wait_for_line with prefix="" returns the first line read.
        if not code:
            print(red("FAIL: no code printed by `zuko share`"), file=sys.stderr)
            return False
        # Re-read in case the first line was blank: drain until a short dashed code.
        while code == "" and share.stdout:
            line = share.stdout.readline()
            if not line:
                break
            code = line.decode(errors="replace").strip()
        print(f"share code: {code}", file=sys.stderr)

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
        ls = subprocess.run(
            [ZUKO, "ls"], capture_output=True, env=env, timeout=30
        )
        hosts = ls.stdout.decode(errors="replace")
        print("---- zuko ls ----", file=sys.stderr)
        print(hosts, file=sys.stderr)
        if "e2e-claimed" not in hosts:
            print(red("FAIL: claimed host not in `zuko ls`"), file=sys.stderr)
            return False
        # The claimed ticket must equal the host's real ticket.
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
        print(red("FAIL: claimed entry malformed"), file=sys.stderr)
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
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        env=env,
    )
    failures = 0
    try:
        ticket = wait_for_line(host, prefix="endpointa", timeout=HOST_TICKET_TIMEOUT)
        if not ticket:
            print(red("FAIL: no ticket from `zuko host`"), file=sys.stderr)
            return 1
        print(f"host ticket: {ticket[:32]}...", file=sys.stderr)

        if not test_host_connect(env, ticket):
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
