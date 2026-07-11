# Windows host through WSL2

Zuko has a native Windows **client**, but no native Windows host or Windows
service. WSL2 can run the glibc Linux host and expose a WSL Linux shell. It does
not expose PowerShell or a native Windows desktop session.

This is a practical, best-effort setup rather than a Core always-on host. WSL
shutdown, Windows restart or sleep, and host-process restart end every in-memory
PTY. Prefer a Linux or macOS host when unattended availability matters.

## 1. Install WSL2 with systemd

In an Administrator PowerShell window:

```powershell
wsl --install -d Ubuntu
wsl --update
```

Restart Windows if requested, open Ubuntu, and verify systemd:

```sh
ps -p 1 -o comm=
systemctl status
```

Current Ubuntu WSL installations enable systemd by default. If PID 1 is not
`systemd`, add this to `/etc/wsl.conf` inside Ubuntu:

```ini
[boot]
systemd=true
```

Then apply it from PowerShell:

```powershell
wsl --shutdown
```

Open Ubuntu again and rerun `systemctl status`. See Microsoft's
[WSL systemd guide](https://learn.microsoft.com/windows/wsl/systemd) for distro
requirements and troubleshooting.

## 2. Install and start Zuko inside WSL

Run these commands in Ubuntu, not PowerShell:

```sh
curl --proto '=https' --tlsv1.2 -LsSf https://zuko.adonm.dev/install.sh | sh
# Exit and reopen Ubuntu here if the installer requests it.
zuko install
zuko doctor
```

Inspect the user service with:

```sh
systemctl --user status zuko-host
journalctl --user -u zuko-host -f
```

Pair normally with `zuko share`. The remote session starts the Linux shell
inside this WSL distribution.

## Service lifetime

Microsoft explicitly notes that systemd services do **not** keep a WSL instance
alive. `zuko install` keeps the host supervised while the distribution is
running, but it does not turn WSL into an always-on VM.

For the most predictable interactive use, keep an Ubuntu window open and run:

```sh
zuko host
```

After `wsl --shutdown`, Windows restart, or a stopped distribution, open the
distribution again and check `zuko doctor`. A Windows Scheduled Task can launch
the distribution at sign-in, but Zuko does not test or install such a task.

## Networking and firewall

Zuko/Iroh initiates outbound connections and does not expose a stable inbound
application port. Do not create a `netsh interface portproxy` rule for Zuko.
WSL2's default NAT normally works through Iroh's relay fallback; mirrored mode
can improve compatibility with VPNs and IPv6.

If `zuko doctor` cannot register with a relay:

1. verify DNS and outbound HTTPS/QUIC inside WSL;
2. review Windows Firewall and, on current Windows 11, Hyper-V firewall policy;
3. check VPN or enterprise egress rules rather than disabling the firewall.

Microsoft references:

- [WSL networking](https://learn.microsoft.com/windows/wsl/networking)
- [Hyper-V firewall](https://learn.microsoft.com/windows/security/operating-system-security/network-security/windows-firewall/hyper-v-firewall)
