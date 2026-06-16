FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl xz-utils ca-certificates \
 && rm -rf /var/lib/apt/lists/*
ARG ZIG_VERSION=0.16.0
# Zig toolchain host arch. build-linux.sh sets this to the build machine's arch
# so the compile is native (Apple Silicon -> aarch64, a Hetzner/Linux box ->
# x86_64); never a cross-compile, which the Zig 0.16 toolchain SEGVs from an
# x86_64 host.
ARG ZIG_ARCH=aarch64
RUN curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}.tar.xz" -o /tmp/zig.tar.xz \
 && mkdir -p /opt/zig \
 && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 \
 && rm /tmp/zig.tar.xz
ENV PATH="/opt/zig:${PATH}"
