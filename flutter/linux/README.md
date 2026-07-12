# Linux runtime requirements

GitHub Releases ship the official Flutter Linux client as a checksummed x86_64
archive containing the complete `bundle/` directory. The pending FlatPark
package repackages that archive under app ID `dev.adonm.zuko`, using the
Freedesktop 25.08 runtime and the host Secret Service for encrypted client
state.

After `dev.adonm.zuko` is published in FlatPark, install and launch it:

```sh
flatpak --user remote-add --if-not-exists flatpark \
  https://dl.flatpark.org/flatpark.flatpakrepo
flatpak --user install flatpark dev.adonm.zuko
flatpak run dev.adonm.zuko
```

The packaged client requires Wayland and uses Flutter's Impeller/OpenGL
renderer. X11 sockets are intentionally not exposed. See
[Linux delivery through FlatPark](../../docs/flatpark.md) for provenance,
permissions, and package maintenance details.
