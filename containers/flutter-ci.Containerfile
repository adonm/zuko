FROM docker.io/library/ubuntu@sha256:52df9b1ee71626e0088f7d400d5c6b5f7bb916f8f0c82b474289a4ece6cf3faf

ARG MISE_VERSION=2026.7.5
ARG MISE_SHA256=5f7ab76afdf0780d12edeaa67e908094e9ccf7924cfe203e415c1cfb87bbf778
ARG ANDROID_COMMAND_LINE_TOOLS_VERSION=14742923
ARG ANDROID_COMMAND_LINE_TOOLS_SHA256=04453066b540409d975c676d781da1477479dde3761310f1a7eb92a1dfb15af7

COPY scripts/install-android-platform-tools.sh /app/bin/install-android-platform-tools

RUN set -eux; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      bash binutils build-essential ca-certificates cage clang cmake curl git \
      gzip jq libegl-dev libgl-dev libgtk-4-dev libsecret-1-dev \
      mesa-vulkan-drivers ninja-build openjdk-17-jdk-headless pkg-config \
      python3 tar unzip xz-utils; \
    rm -rf /var/lib/apt/lists/*; \
    asset="mise-v${MISE_VERSION}-linux-x64"; \
    curl --fail --location --retry 3 \
      "https://github.com/jdx/mise/releases/download/v${MISE_VERSION}/${asset}" \
      --output /app/bin/mise; \
    printf '%s  %s\n' "$MISE_SHA256" /app/bin/mise | sha256sum --check -; \
    chmod 0755 /app/bin/mise /app/bin/install-android-platform-tools; \
    pkg-config --modversion gtk4

ENV JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64 \
    ANDROID_HOME=/opt/android-sdk \
    ANDROID_SDK_ROOT=/opt/android-sdk \
    MISE_DATA_DIR=/opt/mise/data \
    MISE_CACHE_DIR=/opt/mise/cache \
    MISE_STATE_DIR=/opt/mise/state \
    MISE_CONFIG_DIR=/opt/mise/config \
    MISE_YES=1 \
    MISE_AUTO_INSTALL=0 \
    CARGO_HOME=/var/cache/zuko/cargo \
    PUB_CACHE=/var/cache/zuko/pub \
    GRADLE_USER_HOME=/var/cache/zuko/gradle \
    CI=true \
    FLUTTER_SUPPRESS_ANALYTICS=true \
    TAR_OPTIONS=--no-same-owner \
    PATH=/opt/android-sdk/cmdline-tools/latest/bin:/opt/android-sdk/platform-tools:/usr/lib/jvm/java-17-openjdk-amd64/bin:/app/wasm-bindgen/bin:/app/bin:/opt/mise/data/shims:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

RUN set -eux; \
    archive=/tmp/android-command-line-tools.zip; \
    curl --fail --location --retry 3 \
      "https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_COMMAND_LINE_TOOLS_VERSION}_latest.zip" \
      --output "$archive"; \
    printf '%s  %s\n' "$ANDROID_COMMAND_LINE_TOOLS_SHA256" "$archive" \
      | sha256sum --check -; \
    mkdir -p /opt/android-sdk/cmdline-tools /root/.android; \
    unzip -q "$archive" -d /opt/android-sdk/cmdline-tools; \
    mv /opt/android-sdk/cmdline-tools/cmdline-tools \
      /opt/android-sdk/cmdline-tools/latest; \
    touch /root/.android/repositories.cfg; \
    yes | sdkmanager --licenses >/dev/null; \
    /app/bin/install-android-platform-tools /opt/android-sdk; \
    sdkmanager \
      'platforms;android-34' \
      'platforms;android-35' \
      'platforms;android-36' \
      'build-tools;36.0.0' \
      'cmake;3.22.1' \
      'ndk;29.0.14206865'; \
    rm -f "$archive"; \
    rm -rf /root/.android/cache /root/.cache

COPY mise.toml /opt/zuko/mise.toml

RUN set -eux; \
    cd /opt/zuko; \
    mise trust mise.toml; \
    mise install; \
    mise exec -- rustup target add wasm32-unknown-unknown; \
    mise exec -- cargo install wasm-bindgen-cli \
      --version 0.2.122 --locked --root /app/wasm-bindgen; \
    mise exec -- flutter --version; \
    mise exec -- rustc --version; \
    mise exec -- just --version; \
    java -version; \
    sdkmanager --version; \
    rm -rf /var/cache/zuko/cargo/registry /var/cache/zuko/cargo/git

WORKDIR /workspace
