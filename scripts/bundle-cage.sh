#!/bin/bash
set -euo pipefail

mkdir -p dist/cage
docker run --rm -v "$PWD/dist/cage:/out:z" fedora:latest bash -c '
  set -e
  dnf install -y -q --setopt=install_weak_deps=False cage >/dev/null
  cp /usr/bin/cage /out/cage
  chmod 0755 /out/cage
  for lib in libwlroots-0.20.so libliftoff.so.0 libseat.so.1 libxcb-errors.so.0; do
    cp -L "/usr/lib64/$lib" /out/ 2>/dev/null || true
  done
'
echo "--- bundled cage ---"
ls -la dist/cage
