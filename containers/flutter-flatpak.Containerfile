FROM ghcr.io/flathub-infra/flatpak-github-actions@sha256:bc5938197c339664f893828925061b08486e7f355c3e91eefcaae7293d3cfd6b

ARG MISE_VERSION=2026.7.5
ARG MISE_SHA256=5f7ab76afdf0780d12edeaa67e908094e9ccf7924cfe203e415c1cfb87bbf778

RUN set -eux; \
    asset="mise-v${MISE_VERSION}-linux-x64"; \
    curl --fail --location --retry 3 \
      "https://github.com/jdx/mise/releases/download/v${MISE_VERSION}/${asset}" \
      --output /app/bin/mise; \
    printf '%s  %s\n' "$MISE_SHA256" /app/bin/mise | sha256sum --check -; \
    chmod 0755 /app/bin/mise

ENV MISE_DATA_DIR=/opt/mise/data \
    MISE_CACHE_DIR=/opt/mise/cache \
    MISE_STATE_DIR=/opt/mise/state \
    MISE_CONFIG_DIR=/opt/mise/config \
    MISE_YES=1 \
    MISE_AUTO_INSTALL=0 \
    CARGO_HOME=/var/cache/zuko/cargo \
    PUB_CACHE=/var/cache/zuko/pub \
    CI=true \
    FLUTTER_SUPPRESS_ANALYTICS=true \
    PATH=/app/bin:/opt/mise/data/shims:/usr/bin:/bin

RUN set -eux; \
    # Flutter hard-codes clang/clang++ for Linux CMake builds. The pinned \
    # Freedesktop SDK image provides GCC instead; CMake still identifies and \
    # configures the compiler as GNU when reached through these names. \
    ln -s /usr/bin/gcc /app/bin/clang; \
    ln -s /usr/bin/g++ /app/bin/clang++; \
    dbus-uuidgen --ensure=/etc/machine-id

COPY mise.toml /opt/zuko/mise.toml

RUN set -eux; \
    cd /opt/zuko; \
    mise trust mise.toml; \
    mise install flutter rust just; \
    mise exec -- flutter --version; \
    mise exec -- rustc --version; \
    mise exec -- just --version

WORKDIR /workspace
