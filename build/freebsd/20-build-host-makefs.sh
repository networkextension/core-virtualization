#!/bin/bash
# Build FreeBSD's own `makefs` (and its libnetbsd dependency) as *host* tools on
# macOS, without rebuilding the whole bootstrap phase.
#
# Why: a plain `buildworld buildkernel` leaves MK_DISK_IMAGE_TOOLS_BOOTSTRAP=no,
# so `makefs` is only built for the target (ELF), unusable on the host. Re-running
# the full `_bootstrap-tools` phase to flip that flag needlessly recompiles
# llvm-tblgen (30-60 min). Instead we invoke just the two per-tool bootstrap
# targets, reusing the exact env `make.py` uses for stage 1.2.
#
# Prereq: 10-build-world-kernel.sh has already run (populates tmp/legacy + bmake).
# Result: $WORLDTMP/legacy/usr/sbin/makefs (Mach-O), consumed by 30-assemble-image.sh.
set -eu
SRC="${SRC:-/Volumes/cross-buld/freebsd-src}"
OBJA="${OBJA:-/Volumes/cross-buld/obj/freebsd/Volumes/cross-buld/freebsd-src/arm64.aarch64}"
WORLDTMP="$OBJA/tmp"
OBJTOOLS="$WORLDTMP/obj-tools"
BMAKE="${BMAKE:-/Volumes/cross-buld/obj/freebsd/bmake-install/bin/bmake}"
unset LDFLAGS CPPFLAGS PKG_CONFIG_PATH
cd "$SRC"
env \
  INSTALL="sh $SRC/tools/install.sh" \
  TOOLS_PREFIX="$WORLDTMP" \
  PATH="$WORLDTMP/legacy/usr/sbin:$WORLDTMP/legacy/usr/bin:$WORLDTMP/legacy/bin:$WORLDTMP/legacy/usr/libexec:/opt/homebrew/opt/llvm/bin:/opt/homebrew/opt/lld/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  WORLDTMP="$WORLDTMP" \
  MAKEFLAGS="-m $SRC/tools/build/mk -D WITH_AUTO_OBJ -D WITHOUT_CLEAN -m $SRC/share/mk" \
  "$BMAKE" -f Makefile.inc1 \
    DESTDIR= OBJTOP="$OBJTOOLS" OBJROOT='${OBJTOP}/' \
    UNIVERSE_TOOLCHAIN_PATH= MAKEOBJDIRPREFIX= BOOTSTRAPPING=0 BWPHASE=bootstrap-tools \
    -DNO_CPU_CFLAGS -DNO_PIC -DNO_SHARED \
    MK_ASAN=no MK_CTF=no MK_CLANG_EXTRAS=no MK_CLANG_FORMAT=no MK_CLANG_FULL=no \
    MK_HTML=no MK_MAN=no MK_RETPOLINE=no MK_SSP=no MK_TESTS=no MK_UBSAN=no \
    MK_WERROR=no MK_INCLUDES=yes MK_MAN_UTILS=yes MK_LLVM_TARGET_ALL=no \
    MK_DISK_IMAGE_TOOLS_BOOTSTRAP=yes TARGET=arm64 TARGET_ARCH=aarch64 \
    _bootstrap-tools-lib/libnetbsd _bootstrap-tools-usr.sbin/makefs
echo "=== built host makefs ==="
ls -l "$WORLDTMP/legacy/usr/sbin/makefs"
