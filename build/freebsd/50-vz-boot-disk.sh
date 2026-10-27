#!/bin/bash
# Build a small read-only *boot disk* that lets an unmodified official FreeBSD
# arm64 VM image boot under Apple Virtualization.framework.
#
# Stock GENERIC cannot boot on VZ (GIC version from GICD_PIDR2, virtio_console
# low-level console, no virtio_gpu — see README). Instead of re-rolling the whole
# image, the VM gets two disks: this one first (EFI boots it: loader.efi + the
# KERNCONF=VZ kernel built from the *same release branch*), and the official
# image second, untouched, mounted as / via its GPT label. Modules loaded after
# root mount come from the official /boot/kernel — same branch, same KBI.
#
#   LOADER_EFI=/path/loader.efi build/freebsd/50-vz-boot-disk.sh
#     (loader.efi taken from the official image's ESP, so loader and its Lua
#      scripts below match the release)
#
# Layout: GPT  p1 efi (FAT: /efi/boot/bootaa64.efi + /efi/freebsd/loader.env)
#              p2 freebsd-ufs label "vzboot" (/boot/{kernel,lua,defaults,loader.conf})
set -eu

SRC="${SRC:-/Volumes/cross-buld/freebsd-vz151}"            # releng/15.x + VZ patches
export MAKEOBJDIRPREFIX="${MAKEOBJDIRPREFIX:-/Volumes/cross-buld/obj/freebsd-vz151}"
TOOLS="${TOOLS:-/Volumes/cross-buld/obj/freebsd/Volumes/cross-buld/freebsd-src/arm64.aarch64/tmp/legacy}"
MAKEFS="$TOOLS/usr/sbin/makefs"
MKIMG="$TOOLS/bin/mkimg"
STAGE="${STAGE:-/Volumes/cross-buld/vz-boot-stage}"
OUT="${OUT:-/Volumes/cross-buld/freebsd-vm/vz-boot.raw}"
LOADER_EFI="${LOADER_EFI:?LOADER_EFI= path to the official image loader.efi}"
ROOTDEV="${ROOTDEV:-ufs:/dev/gpt/rootfs}"                   # official VM images label / as rootfs
KERNCONF="${KERNCONF:-VZ}"

unset LDFLAGS CPPFLAGS PKG_CONFIG_PATH
rm -rf "$STAGE"; mkdir -p "$STAGE/ufs" "$STAGE/esp/efi/boot" "$STAGE/esp/efi/freebsd"

echo "=== installkernel KERNCONF=$KERNCONF"
"$SRC/tools/build/make.py" --cross-bindir=/Volumes/cross-buld/shim/xbin \
  TARGET=arm64 TARGET_ARCH=aarch64 DESTDIR="$STAGE/ufs" -DNO_ROOT -DWITHOUT_DEBUG_FILES \
  installkernel KERNCONF="$KERNCONF" >"$STAGE/ik.log" 2>&1 || { tail -30 "$STAGE/ik.log"; exit 1; }
rm -f "$STAGE/ufs/METALOG"
# Only the kernel itself: after root mount, kldload resolves /boot/kernel on the
# official image (same branch → same KBI), so shipping modules here only adds size.
find "$STAGE/ufs/boot/kernel" -type f ! -name kernel -delete
# installkernel still drops kernel.debug under usr/lib/debug; VZ is ACPI, no dtb.
rm -rf "$STAGE/ufs/usr" "$STAGE/ufs/boot/dtb"

echo "=== loader scripts + loader.conf"
mkdir -p "$STAGE/ufs/boot/lua" "$STAGE/ufs/boot/defaults"
for f in $(sed -n '/^FILES=/,/^$/p' "$SRC/stand/lua/Makefile" | tr -d '\\' | sed 's/^FILES=//'); do
  cp "$SRC/stand/lua/$f" "$STAGE/ufs/boot/lua/"
done
cp "$SRC/stand/defaults/loader.conf" "$STAGE/ufs/boot/defaults/loader.conf"
cat > "$STAGE/ufs/boot/loader.conf" <<E
# vz-boot: kernel from this disk, / from the official image (second disk)
vfs.root.mountfrom="$ROOTDEV"
autoboot_delay="2"
# Apple VZ virtio-net: offloads misbehave (same as the polar golden image)
hw.vtnet.csum_disable="1"
hw.vtnet.tso_disable="1"
hw.vtnet.lro_disable="1"
hw.vtnet.mq_disable="1"
E

echo "=== ESP"
cp "$LOADER_EFI" "$STAGE/esp/efi/boot/bootaa64.efi"
# Pin the loader to this disk's UFS partition; without it loader.efi may pick
# the official image's / and boot its stock (VZ-incompatible) kernel.
printf 'rootdev=disk0p2:\n' > "$STAGE/esp/efi/freebsd/loader.env"

echo "=== makefs + mkimg"
"$MAKEFS" -t msdos -o fat_type=16 -o volume_label=EFISYS -s 32m "$STAGE/esp.img" "$STAGE/esp"
"$MAKEFS" -t ffs -B little -o label=vzboot -o version=2 -o minfree=0 -b 10% "$STAGE/ufs.img" "$STAGE/ufs"
mkdir -p "$(dirname "$OUT")"
"$MKIMG" -s gpt -p efi:="$STAGE/esp.img" -p freebsd-ufs/vzboot:="$STAGE/ufs.img" -o "$OUT"
ls -l "$OUT"; shasum -a 256 "$OUT"
