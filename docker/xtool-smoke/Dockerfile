FROM swift:6.3-jammy

# Local/CI-compatible xtool smoke-build image. Mirrors xtool's upstream
# Dockerfile enough for non-device builds: Swift 6.3, Rust, xtool AppImage,
# libxml2/curl/zip bits, and LLVM tools (llvm-lipo + llvm-objcopy).
#
# This image intentionally does NOT try to log into Apple services or talk to
# usbmuxd. It only validates `scripts/build-ffi.sh` + `xtool dev build` using a
# prebuilt Darwin SDK bundle mounted by the caller.

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        build-essential \
        pkg-config \
        libxml2 \
        libxml2-dev \
        libssl-dev \
        zip \
        unzip \
        xz-utils \
        zlib1g-dev \
        llvm \
        clang \
    && rm -rf /var/lib/apt/lists/*

RUN curl https://sh.rustup.rs -sSf | sh -s -- -y --profile minimal \
    && /root/.cargo/bin/rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios \
    && /root/.cargo/bin/rustup component add llvm-tools-preview

RUN curl -fL "https://github.com/xtool-org/xtool/releases/latest/download/xtool-$(uname -m).AppImage" \
        -o /usr/local/bin/xtool \
    && chmod +x /usr/local/bin/xtool

# Docker doesn't support FUSE, so run AppImage by extraction.
ENV APPIMAGE_EXTRACT_AND_RUN=1
ENV PATH="/root/.cargo/bin:${PATH}"

WORKDIR /work
