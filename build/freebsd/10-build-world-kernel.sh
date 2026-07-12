#!/bin/sh
# Cross-build FreeBSD/arm64 world + the Apple-VZ kernel (KERNCONF=VZ) on a macOS host.
# Prereqs: Homebrew llvm+lld linked into a single cross-bindir, sources on a
# case-sensitive volume. See ../../CLAUDE.md and doc/design.md.
set -eu
SRC="${SRC:-/Volumes/cross-buld/freebsd-src}"
export MAKEOBJDIRPREFIX="${MAKEOBJDIRPREFIX:-/Volumes/cross-buld/obj/freebsd}"
XBIN="${XBIN:-/Volumes/cross-buld/shim/xbin}"     # symlinks of llvm/bin/* + lld/bin/*
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
# Shell-profile openssl LDFLAGS/CPPFLAGS leak corrupts the cross link — drop them.
unset LDFLAGS CPPFLAGS PKG_CONFIG_PATH
cd "$SRC"
exec ./tools/build/make.py --cross-bindir="$XBIN" \
  TARGET=arm64 TARGET_ARCH=aarch64 -j"$JOBS" \
  buildworld buildkernel KERNCONF=VZ
