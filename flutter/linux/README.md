# Linux runtime requirements

GitHub Releases ship the Flutter Linux client as a Flatpak bundle with app ID
`dev.adonm.zuko`. It uses the Freedesktop 25.08 runtime and accesses credentials
through the host Secret Service portal.

Install and launch a downloaded release:

```sh
flatpak --user install ./zuko-linux-vX.Y.Z-x86_64.flatpak
flatpak run dev.adonm.zuko
```

Wayland is preferred with fallback X11 support. See
[`../../flatpak/README.md`](../../flatpak/README.md) for build, validation,
permission, and smoke-test details.
