#!/bin/sh
set -eu

dir="${ZUKO_IOS_SIGNING_DIR:-$HOME/.config/zuko/ios-signing}"
missing=0
echo "iOS signing workspace: $dir"
for file in zuko.key zuko.csr zuko.cer zuko.p12 p12-password \
  Zuko_AppStore.mobileprovision team-id asc-key-id asc-issuer-id; do
  if [ -f "$dir/$file" ]; then
    echo "  ok:      $file"
  else
    echo "  missing: $file"
    missing=1
  fi
done
if ls "$dir"/AuthKey_*.p8 >/dev/null 2>&1; then
  echo "  ok:      AuthKey_*.p8"
else
  echo "  missing: AuthKey_*.p8"
  missing=1
fi
if [ "$missing" -ne 0 ]; then
  echo "Run: just setup-ios-signing"
  exit 1
fi
