#!/bin/bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: apple-setup-signing.sh <ios|macos>" >&2
  exit 2
fi

readonly PLATFORM="$1"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT
readonly SIGNING_DIR="${RUNNER_TEMP:?RUNNER_TEMP is required}/apple-signing"
readonly KEYCHAIN="$SIGNING_DIR/zuko.keychain-db"

require_env() {
  if [ -z "${!1:-}" ]; then
    echo "required Apple signing variable is missing: $1" >&2
    exit 1
  fi
}

decode_secret() {
  local variable="$1"
  local output="$2"
  VARIABLE="$variable" OUTPUT="$output" python3 - <<'PY'
import base64
import os
from pathlib import Path

value = os.environ[os.environ["VARIABLE"]]
try:
    decoded = base64.b64decode(value, validate=True)
except ValueError as error:
    raise SystemExit("invalid base64 Apple signing material") from error
if not decoded:
    raise SystemExit("empty Apple signing material")
path = Path(os.environ["OUTPUT"])
path.write_bytes(decoded)
path.chmod(0o600)
PY
}

certificate_identity() {
  local certificate="$1"
  local password_variable="$2"
  CERTIFICATE="$certificate" PASSWORD_VARIABLE="$password_variable" python3 - <<'PY'
import os
from pathlib import Path

from cryptography.hazmat.primitives.serialization import pkcs12
from cryptography.x509.oid import NameOID

password = os.environ[os.environ["PASSWORD_VARIABLE"]].encode()
_, certificate, _ = pkcs12.load_key_and_certificates(
    Path(os.environ["CERTIFICATE"]).read_bytes(), password
)
if certificate is None:
    raise SystemExit("PKCS#12 file does not contain a certificate")
names = certificate.subject.get_attributes_for_oid(NameOID.COMMON_NAME)
teams = certificate.subject.get_attributes_for_oid(NameOID.ORGANIZATIONAL_UNIT_NAME)
if len(names) != 1 or len(teams) != 1 or teams[0].value != os.environ["TEAM_ID"]:
    raise SystemExit("certificate identity or team does not match TEAM_ID")
print(names[0].value)
PY
}

validate_profile() {
  local profile="$1"
  local expected_platform="$2"
  local plist="$SIGNING_DIR/profile.plist"
  security cms -D -i "$profile" > "$plist"
  PROFILE_PLIST="$plist" EXPECTED_PLATFORM="$expected_platform" python3 - <<'PY'
import datetime
import os
import plistlib
from pathlib import Path

profile = plistlib.loads(Path(os.environ["PROFILE_PLIST"]).read_bytes())
entitlements = profile.get("Entitlements", {})
teams = profile.get("TeamIdentifier", [])
identifier = (
    entitlements.get("application-identifier")
    or entitlements.get("com.apple.application-identifier")
)
expected_identifier = f'{os.environ["TEAM_ID"]}.dev.adonm.zuko'
if teams != [os.environ["TEAM_ID"]] or identifier != expected_identifier:
    raise SystemExit("provisioning profile bundle or team does not match")
if profile.get("ExpirationDate") <= datetime.datetime.now(datetime.UTC).replace(tzinfo=None):
    raise SystemExit("provisioning profile is expired")
if profile.get("ProvisionedDevices") or profile.get("ProvisionsAllDevices"):
    raise SystemExit("provisioning profile is not an App Store profile")
platforms = profile.get("Platform", [])
if os.environ["EXPECTED_PLATFORM"] not in platforms:
    raise SystemExit(f"unexpected provisioning profile platform: {platforms}")
PY
}

require_env TEAM_ID
mkdir -p "$SIGNING_DIR"
chmod 700 "$SIGNING_DIR"

case "$PLATFORM" in
  ios)
    require_env BUILD_CERTIFICATE_BASE64
    require_env P12_PASSWORD
    require_env PROVISIONING_PROFILE_BASE64
    application_p12="$SIGNING_DIR/application.p12"
    profile="$SIGNING_DIR/zuko.mobileprovision"
    decode_secret BUILD_CERTIFICATE_BASE64 "$application_p12"
    decode_secret PROVISIONING_PROFILE_BASE64 "$profile"
    validate_profile "$profile" iOS
    application_identity="$(certificate_identity "$application_p12" P12_PASSWORD)"
    application_password_variable=P12_PASSWORD
    case "$application_identity" in
      "Apple Distribution:"*) ;;
      *) echo "iOS certificate is not an Apple Distribution identity" >&2; exit 1 ;;
    esac
    ;;
  macos)
    require_env MACOS_APPLICATION_CERTIFICATE_BASE64
    require_env MACOS_APPLICATION_CERTIFICATE_PASSWORD
    require_env MACOS_INSTALLER_CERTIFICATE_BASE64
    require_env MACOS_INSTALLER_CERTIFICATE_PASSWORD
    require_env MACOS_PROVISIONING_PROFILE_BASE64
    application_p12="$SIGNING_DIR/macos-application.p12"
    installer_p12="$SIGNING_DIR/macos-installer.p12"
    profile="$SIGNING_DIR/zuko.provisionprofile"
    decode_secret MACOS_APPLICATION_CERTIFICATE_BASE64 "$application_p12"
    decode_secret MACOS_INSTALLER_CERTIFICATE_BASE64 "$installer_p12"
    decode_secret MACOS_PROVISIONING_PROFILE_BASE64 "$profile"
    validate_profile "$profile" OSX
    application_identity="$(certificate_identity "$application_p12" MACOS_APPLICATION_CERTIFICATE_PASSWORD)"
    installer_identity="$(certificate_identity "$installer_p12" MACOS_INSTALLER_CERTIFICATE_PASSWORD)"
    application_password_variable=MACOS_APPLICATION_CERTIFICATE_PASSWORD
    case "$application_identity" in
      "3rd Party Mac Developer Application:"*|"Mac App Distribution:"*) ;;
      *) echo "macOS certificate is not a Mac App Distribution identity" >&2; exit 1 ;;
    esac
    case "$installer_identity" in
      "3rd Party Mac Developer Installer:"*|"Mac Installer Distribution:"*) ;;
      *) echo "macOS certificate is not a Mac Installer Distribution identity" >&2; exit 1 ;;
    esac
    ;;
  *)
    echo "platform must be ios or macos" >&2
    exit 2
    ;;
esac

keychain initialize -p "$KEYCHAIN" --timeout 7200
keychain add-certificates -p "$KEYCHAIN" \
  --certificate "$application_p12" \
  --certificate-password "@env:$application_password_variable"

if [ "$PLATFORM" = macos ]; then
  keychain add-certificates -p "$KEYCHAIN" \
    --certificate "$installer_p12" \
    --certificate-password @env:MACOS_INSTALLER_CERTIFICATE_PASSWORD
  printf 'MACOS_INSTALLER_IDENTITY=%s\n' "$installer_identity" >> "${GITHUB_ENV:?GITHUB_ENV is required}"
  project="$ROOT/flutter/macos/Runner.xcodeproj"
else
  project="$ROOT/flutter/ios/Runner.xcodeproj"
fi

xcode-project use-profiles \
  --project "$project" \
  --profile "$profile" \
  --archive-method app-store \
  --export-options-plist "$SIGNING_DIR/ExportOptions.plist" \
  --custom-export-options '{"destination":"export","manageAppVersionAndBuildNumber":false,"stripSwiftSymbols":true,"uploadSymbols":true}'

plutil -lint "$SIGNING_DIR/ExportOptions.plist"
if [ "$PLATFORM" = ios ]; then
  printf 'APPLE_EXPORT_OPTIONS=%s\n' "$SIGNING_DIR/ExportOptions.plist" >> "${GITHUB_ENV:?GITHUB_ENV is required}"
fi

echo "Codemagic configured the $PLATFORM App Store signing profile and identities"
