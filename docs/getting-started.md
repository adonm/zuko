# Install and connect

Zuko's host and reference CLI are the same binary. Host releases support glibc
Linux and macOS on x86_64 and ARM64.

## Install the CLI

The installer detects or bootstraps [mise](https://mise.jdx.dev/), configures
activation for Bash, Zsh, or Fish, and installs Zuko as a global mise tool:

```sh
curl --proto '=https' --tlsv1.2 -LsSf https://zuko.adonm.dev/install.sh | sh
# Relaunch your shell here if the installer asks.
zuko --version
```

If the installer adds mise activation to your shell profile, exit and relaunch
the shell before running `zuko`. Its Zuko tool entry sets mise's minimum release
age to `0s` so a newly published Zuko release is immediately available; this
does not change the global policy for other tools. Re-running the installer
upgrades an existing mise-managed Zuko installation. To inspect the script
before running it:

```sh
curl --proto '=https' --tlsv1.2 -fsSLo /tmp/zuko-install.sh \
  https://zuko.adonm.dev/install.sh
less /tmp/zuko-install.sh
sh /tmp/zuko-install.sh
```

Optional settings:

```sh
# Install one release rather than latest.
curl --proto '=https' --tlsv1.2 -LsSf https://zuko.adonm.dev/install.sh |
  ZUKO_VERSION=0.10.5 sh
```

Update with `zuko upgrade` or `mise upgrade github:adonm/zuko`. Restarting the
host service ends its in-memory PTYs, so `zuko upgrade` shows the plan before it
does so.

## Start the host

Install and start the per-user service:

```sh
zuko install
zuko doctor
```

Linux uses a systemd user unit. A server that must continue after logout also
needs lingering:

```sh
sudo loginctl enable-linger "$USER"
journalctl --user -u zuko-host -f
```

macOS uses a LaunchAgent. Follow its log with:

```sh
tail -f "${XDG_CONFIG_HOME:-$HOME/.config}/zuko/zuko-host.err.log"
```

You can avoid service installation and keep the host in the foreground:

```sh
zuko host
```

Windows does not have a native host service. See [Windows host through
WSL2](windows-wsl2.md) for the Linux-host workaround and its limitations.

## Pair a client

Install Zuko on a second machine or choose another [client](clients.md). Then:

```sh
# Host: print a one-time two-word code.
zuko share

# Client: claim the code, save the host, and connect.
zuko iridescent-hilton
```

The host must be running while you pair. `zuko share` authorizes that client;
the code is not a reusable password. Future connections use the saved host
name:

```sh
zuko ls
zuko home
```

Use `zuko rm <name>` to revoke a client or forget a host. Continue with
[host operations](host.md) for service control, state, reset, diagnostics, and
session behavior.
