#!/usr/bin/env bash
# Build a static aarch64-linux-musl zag binary inside a Linux container.
# Native-arch compile on Apple Silicon; the Docker VM memory cap bounds the
# LLVM peak so a runaway build cannot freeze the host. Never cross-compile
# for linux on the macOS host.
set -euo pipefail

repo="$(git -C "$(cd "$(dirname "$0")" && pwd)" rev-parse --show-toplevel)"
bench="$repo/bench/terminal-bench"
image=zag-zig-builder:0.16.0

docker build -t "$image" -f "$bench/zig-builder.Dockerfile" "$bench"
docker volume create zag-zig-cache >/dev/null

# Flags mirror the Makefile's release-aarch64-linux-musl target; --prefix keeps
# the linux artifact out of zig-out/ so it cannot clobber a native host build.
docker run --rm \
  -v "$repo:/work" -w /work \
  -v zag-zig-cache:/zig-cache \
  -e ZIG_GLOBAL_CACHE_DIR=/zig-cache/global \
  -e ZIG_LOCAL_CACHE_DIR=/zig-cache/local \
  "$image" \
  zig build -Dtarget=aarch64-linux-musl -Dsim=false -Doptimize=ReleaseSafe \
    --prefix /work/bench/terminal-bench/zig-out-linux

mkdir -p "$bench/bin"
cp "$bench/zig-out-linux/bin/zag" "$bench/bin/zag-linux-aarch64"
file "$bench/bin/zag-linux-aarch64"
