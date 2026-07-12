#!/bin/bash
# Assemble a bootable FreeBSD/arm64 disk image on a macOS host from the
# cross-built world + KERNCONF=VZ kernel, using makefs (UFS2 via METALOG) + mkimg.
# Mirrors the reference mkimg.sh but with host cross-tools instead of mdconfig/gpart.
set -eu

SRC=/Volumes/cross-buld/freebsd-src
export MAKEOBJDIRPREFIX=/Volumes/cross-buld/obj/freebsd
OBJ=$MAKEOBJDIRPREFIX/Volumes/cross-buld/freebsd-src/arm64.aarch64
STAGE=/Volumes/cross-buld/fbsd-stage
OUT=/Volumes/cross-buld/freebsd-vm
IMG=$OUT/freebsd-vz.raw
KEYPUB="$OUT/fbsd_key.pub"

MAKEFS="$OBJ/tmp/legacy/usr/sbin/makefs"
MKIMG="$OBJ/tmp/legacy/bin/mkimg"

unset LDFLAGS CPPFLAGS PKG_CONFIG_PATH
export PATH=/opt/homebrew/opt/llvm/bin:/opt/homebrew/opt/lld/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin

mkdir -p "$OUT"
# --- ssh key for the guest ---
if [ ! -f "$OUT/fbsd_key" ]; then
  ssh-keygen -t ed25519 -N '' -f "$OUT/fbsd_key" -C fbsd-vz >/dev/null
fi
SSHKEY="$(cat "$KEYPUB")"

echo "=== [1/6] installworld/installkernel(VZ)/distribution -> $STAGE (NO_ROOT) ==="
rm -rf "$STAGE"; mkdir -p "$STAGE"
mkw() { "$SRC/tools/build/make.py" --cross-bindir=/Volumes/cross-buld/shim/xbin \
        TARGET=arm64 TARGET_ARCH=aarch64 DESTDIR="$STAGE" \
        -DNO_ROOT MK_DISK_IMAGE_TOOLS_BOOTSTRAP=yes \
        -DWITHOUT_MAN -DWITHOUT_TESTS -DWITHOUT_DEBUG_FILES "$@"; }
mkw installworld  >/tmp/iw.log  2>&1 || { tail -30 /tmp/iw.log; exit 1; }
mkw installkernel KERNCONF=VZ >/tmp/ik.log 2>&1 || { tail -30 /tmp/ik.log; exit 1; }
mkw distribution  >/tmp/di.log 2>&1 || { tail -30 /tmp/di.log; exit 1; }
METALOG="$STAGE/METALOG"
test -s "$METALOG" || { echo "no METALOG produced"; exit 1; }
echo "METALOG lines: $(wc -l < "$METALOG")"

echo "=== [2/6] guest config (fstab, rc.conf, loader.conf, ttys, ssh) ==="
add() { # add file to METALOG:  add <relpath-from-stage> <mode>
  local rel="${1#./}"; local mode="$2"
  grep -q "^\./$rel " "$METALOG" || \
    echo "./$rel type=file uname=root gname=wheel mode=$mode" >> "$METALOG"
}
cat > "$STAGE/etc/fstab" <<'E'
/dev/gpt/rootfs	/	ufs	rw	1	1
E
add etc/fstab 0644
cat > "$STAGE/etc/rc.conf" <<'E'
hostname="fbsdvz"
ifconfig_vtnet0="DHCP"
sshd_enable="YES"
growfs_enable="YES"
E
add etc/rc.conf 0644
# Apple VZ workarounds: keep boot_verbose off; trim virtio-net offloads.
cat > "$STAGE/boot/loader.conf" <<'E'
autoboot_delay="3"
hw.vtnet.csum_disable="1"
hw.vtnet.tso_disable="1"
hw.vtnet.lro_disable="1"
hw.vtnet.mq_disable="1"
E
add boot/loader.conf 0644
# getty on virtio console ttyV0.0
if grep -q '^ttyV0.0' "$STAGE/etc/ttys"; then
  sed -i '' 's|^ttyV0.0.*|ttyV0.0 "/usr/libexec/getty 3wire" vt100 on secure|' "$STAGE/etc/ttys"
else
  echo 'ttyV0.0 "/usr/libexec/getty 3wire" vt100 on secure' >> "$STAGE/etc/ttys"
fi
mkdir -p "$STAGE/root/.ssh"
echo "$SSHKEY" > "$STAGE/root/.ssh/authorized_keys"
# directory entry MUST precede its child in the mtree manifest
grep -q '^\./root/\.ssh ' "$METALOG" || \
  echo "./root/.ssh type=dir uname=root gname=wheel mode=0700" >> "$METALOG"
grep -q '^\./root/\.ssh/authorized_keys ' "$METALOG" || \
  echo "./root/.ssh/authorized_keys type=file uname=root gname=wheel mode=0600" >> "$METALOG"
cat >> "$STAGE/etc/ssh/sshd_config" <<'E'
PermitRootLogin prohibit-password
PubkeyAuthentication yes
PasswordAuthentication no
E
# empty root password so console login works too
sed -i '' 's|^root:[^:]*:|root::|' "$STAGE/etc/master.passwd"

echo "=== [3/6] pwd_mkdb (host, against staged etc) ==="
PWDMKDB="$OBJ/tmp/legacy/usr/sbin/pwd_mkdb"
[ -x "$PWDMKDB" ] || PWDMKDB="$(command -v pwd_mkdb || true)"
"$PWDMKDB" -p -d "$STAGE/etc" "$STAGE/etc/master.passwd"
for f in pwd.db spwd.db passwd; do add etc/$f 0644; done

echo "=== [4/6] root UFS2 image (makefs + METALOG) ==="
# CRITICAL: installworld records size= for every file in METALOG. The config
# edits above (ttys/master.passwd/sshd_config/pwd_mkdb) change file sizes, and
# makefs trusts size=: larger files are SILENTLY TRUNCATED (corrupt image),
# smaller ones abort the populate — either way a broken or stale image that
# boots the kernel but never reaches init. Strip size= (optional in mtree) so
# makefs uses the real on-disk sizes.
sed -i '' -E 's/ size=[0-9]+//g' "$METALOG"
ROOTFS=$OUT/rootfs.ufs
"$MAKEFS" -t ffs -B little -o label=rootfs,version=2 \
  -M 3g -F "$METALOG" -N "$STAGE/etc" "$ROOTFS" "$STAGE"

echo "=== [5/6] ESP (FAT16 with BOOTAA64.EFI) ==="
ESPDIR=$OUT/esp; rm -rf "$ESPDIR"; mkdir -p "$ESPDIR/EFI/BOOT"
cp "$STAGE/boot/loader.efi" "$ESPDIR/EFI/BOOT/BOOTAA64.EFI"
ESPIMG=$OUT/esp.img
"$MAKEFS" -t msdos -o fat_type=16,volume_label=EFISYS \
  -s 100m "$ESPIMG" "$ESPDIR"

echo "=== [6/6] GPT assembly (mkimg) ==="
"$MKIMG" -s gpt \
  -p efi:="$ESPIMG" \
  -p freebsd-ufs/rootfs:="$ROOTFS" \
  -o "$IMG"
echo "=== DONE ==="
ls -lh "$IMG"
