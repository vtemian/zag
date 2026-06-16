#!/usr/bin/env bash
# Build a static linux-musl zag binary inside a Linux container, matching the
# BUILD MACHINE's CPU arch (Apple Silicon -> aarch64, a Hetzner/Linux box ->
# x86_64). Native-arch compile only; the Docker VM memory cap bounds the LLVM
# peak so a runaway build cannot freeze the host. Never cross-compile for linux
# (the Zig 0.16 toolchain SEGVs cross-compiling from an x86_64 host, and a
# macOS-host linux cross-compile balloons to an 11.7GB LLVM peak that freezes
# the machine).
set -euo pipefail

# Derive paths from this script's location, not git, so the build also works
# from a plain source tree (e.g. one rsync'd to a remote build/bench host).
bench="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$bench/../.." && pwd)"
image=zag-zig-builder:0.16.0

# Map the host CPU arch to the Zig toolchain arch, the zag build target, and
# the output binary name. The container base image (debian:bookworm-slim) is
# multi-arch, so docker pulls the host-arch variant automatically.
host_arch="$(uname -m)"
case "$host_arch" in
  x86_64|amd64)     zig_arch=x86_64;  target=x86_64-linux-musl;  out=zag-linux-x86_64 ;;
  aarch64|arm64)    zig_arch=aarch64; target=aarch64-linux-musl; out=zag-linux-aarch64 ;;
  *) echo "unsupported build host arch: $host_arch" >&2; exit 1 ;;
esac
echo "building $target (zig $zig_arch) on host $host_arch -> bin/$out"

docker build -t "$image" --build-arg "ZIG_ARCH=$zig_arch" \
  -f "$bench/zig-builder.Dockerfile" "$bench"
docker volume create zag-zig-cache >/dev/null

# Flags mirror the Makefile's release-<target> target; --prefix keeps the linux
# artifact out of zig-out/ so it cannot clobber a native host build.
docker run --rm \
  -v "$repo:/work" -w /work \
  -v zag-zig-cache:/zig-cache \
  -e ZIG_GLOBAL_CACHE_DIR=/zig-cache/global \
  -e ZIG_LOCAL_CACHE_DIR=/zig-cache/local \
  "$image" \
  zig build -Dtarget="$target" -Dsim=false -Doptimize=ReleaseSafe \
    --prefix /work/bench/terminal-bench/zig-out-linux

mkdir -p "$bench/bin"
cp "$bench/zig-out-linux/bin/zag" "$bench/bin/$out"
# Diagnostic only; `file` is not installed everywhere (e.g. a minimal Linux
# build host), so never let its absence fail an otherwise-good build.
file "$bench/bin/$out" 2>/dev/null || ls -l "$bench/bin/$out"
