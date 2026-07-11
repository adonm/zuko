# Microsoft Store publishing

The manual `publish-flutter-windows.yml` workflow builds the Flutter Windows
client from an immutable `vX.Y.Z` release tag, packages and signs
MSIX/MSIXBundle artifacts, uploads a Partner Center draft, and separates final
submission behind a second protected approval.

Partner Center assigns the package identity. Configure the exact values and
signing credentials documented in
[`flutter/windows/store/README.md`](../flutter/windows/store/README.md); never
invent or commit placeholders for them. The workflow validates the live Partner
Center identity, selected source commit, and package metadata before upload.

Use `lane=draft` first. Run WACK against the retained signed bundle, review the
draft in Partner Center, then dispatch `lane=submit` through the protected
`microsoft-store-submit` environment. Store listing metadata, age ratings,
privacy declarations, agreements, and the initial Partner Center submission
remain maintainer-owned portal work.

Repeated runs use the same tagged source and package version before
certification. After Partner Center accepts a package version, increment the
Zuko release version for the next submission; Microsoft does not accept a
second package with the published version.
