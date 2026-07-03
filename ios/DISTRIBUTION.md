# iOS distribution

Signed `.ipa` + TestFlight upload runs from GitHub Actions:

```text
Actions → release-ios → Run workflow
```

Workflow: `.github/workflows/release-ios.yml`.

## Secrets

Set repo Actions secrets:

| Secret | Value |
|--------|-------|
| `BUILD_CERTIFICATE_BASE64` | base64 of `zuko.p12` |
| `P12_PASSWORD` | `.p12` password |
| `PROVISIONING_PROFILE_BASE64` | base64 of App Store `.mobileprovision` |
| `TEAM_ID` | Apple team id |
| `ASC_KEY_ID` | App Store Connect API key id |
| `ASC_ISSUER_ID` | App Store Connect issuer id |
| `ASC_KEY_CONTENT` | `.p8` API key PEM |

Automated setup from any machine with `openssl` + `gh`:

```sh
mise run setup-ios-signing
```

Artifacts are written under `~/.config/zuko/ios-signing/` unless
`ZUKO_IOS_SIGNING_DIR` is set.

## Manual signing material

```sh
openssl req -newkey rsa:2048 -nodes \
  -keyout zuko.key \
  -out zuko.csr \
  -subj "/CN=Zuko Distribution"
```

Then in Apple Developer portal:

1. Certificates → Apple Distribution → upload CSR → download `.cer`.
2. Profiles → App Store → bundle id `dev.adonm.zuko` → download profile.

Create `.p12`:

```sh
export P12_PASSWORD='choose-a-strong-password'
openssl pkcs12 -export \
  -out zuko.p12 \
  -inkey zuko.key \
  -in zuko.cer \
  -password pass:"$P12_PASSWORD"
```

## Workflow inputs

- `beta`: build signed `.ipa`, upload to TestFlight.
- `build`: build signed `.ipa`, upload as workflow artifact only.

Rotate by replacing certificate/profile secrets and `P12_PASSWORD`.
