# Linux runtime requirements

GitHub Releases ship the Flutter Linux client as a Flatpak bundle with app ID
`dev.adonm.zuko`. It uses the Freedesktop 25.08 runtime and accesses credentials
through the host Secret Service portal.

Install and launch a downloaded release:

```sh
flatpak --user install ./zuko-linux-vX.Y.Z-x86_64.flatpak
flatpak run dev.adonm.zuko
```

The packaged client requires Wayland and uses Flutter's Impeller/OpenGL
renderer. X11 sockets are intentionally not exposed. See
[`../../flatpak/README.md`](../../flatpak/README.md) for build, validation,
permission, and smoke-test details.
