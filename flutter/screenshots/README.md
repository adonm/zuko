# Zuko pair and connect screenshots

These images document the pairing and connection flow. They are rendered
deterministically from the real widget tree — Yaru themes, the bundled fonts,
the window frame, and the flterm terminal widget — by
`test/screenshot_flow_test.dart`, and written at 2x resolution.

| File | Scene |
|---|---|
| `welcome.png` | First-run welcome screen with host setup steps |
| `pairing-code.png` | Manual pairing with a share code entered |
| `pairing-scan.png` | Camera pairing with the animated viewfinder |
| `pairing-confirmed.png` | Success confirmation shown after a claim |
| `connecting.png` | Opening a saved host |
| `retrying.png` | Automatic reconnect countdown after a dropped link |
| `connected.png` | Attached terminal session |

## Regenerate

From the repository root, inside the pinned Flutter environment:

```sh
just screenshots
```

or directly:

```sh
cd flutter
flutter test test/screenshot_flow_test.dart --dart-define=SCREENSHOTS=true --no-pub
```

Regenerate the images whenever the pairing screens, the sidebar, the session
overlay, or the terminal theming changes, and review the diff before
committing.
