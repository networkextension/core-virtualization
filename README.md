# core-virtualization

Build **FreeBSD / NetBSD / Linux / OpenBSD** for arm64 *from source* on an Apple
Silicon macOS host, boot each in an **Apple Virtualization.framework** VM, and
auto-collect `dmesg` + host-timestamped boot timing.

The full design (scope, phases, CI shape) is in [`doc/design.md`](doc/design.md).
Guidance for working in this tree is in [`CLAUDE.md`](CLAUDE.md).

## The load-bearing constraint

Stock FreeBSD/arm64 **silently fails** to boot under Virtualization.framework
(200% CPU spin, no console). A working boot needs a kernel carrying the Apple-VZ
fix chain — GIC-version detection from `GICD_PIDR2`, a low-level console in
`virtio_console(4)` (VZ has no UART and a framebuffer-less GPU, so this is the
*only* way to see kernel output), and `nodevice virtio_gpu`. Those fixes live on
the `apple-vz-virtio-console` branch of a FreeBSD fork and ship a ready
`sys/arm64/conf/VZ` kernel config. Consequently the FreeBSD leg builds
`KERNCONF=VZ`, not stock `GENERIC`. Linux boots on the identical VZ setup
unchanged; NetBSD/OpenBSD go via EFI. See `CLAUDE.md` for the complete list.

## Layout

```
harness/
  vzrun.swift          unified VZ boot-bench CLI (one binary boots any of the 4 OSes)
  vzrun.entitlements   com.apple.security.virtualization
  build.sh             swiftc -O + ad-hoc codesign
  summary.py           results/<os>/<rev>.json -> Markdown table (GITHUB_STEP_SUMMARY)
build/freebsd/
  10-build-world-kernel.sh   cross buildworld + buildkernel KERNCONF=VZ
  20-build-host-makefs.sh    build FreeBSD's makefs as a macOS host tool
  30-assemble-image.sh       installworld -DNO_ROOT -> METALOG -> makefs -> mkimg
doc/design.md          source of truth (Chinese)
```

## vzrun

`vzrun` boots a guest, stamps **every serial-console line with a host-side
monotonic clock** (`[+1.234s]` — the cross-OS timing baseline, independent of
whether the guest emits its own timestamps), matches per-OS boot markers
(kernel-first-line / init / login-ready), enforces a watchdog, and writes
`results/<os>/<rev>.{json,serial.log,dmesg.txt}`.

```sh
harness/build.sh

# Linux (direct kernel boot)
harness/vzrun --os linux --disk Image --kernel Image --initrd initramfs.cpio.gz \
              --rev 7.2rc2 --out results --timeout 90

# FreeBSD / NetBSD / OpenBSD (EFI boot from a raw disk image)
harness/vzrun --os freebsd --disk freebsd-vz.raw --rev vz --timeout 180

python3 harness/summary.py results
```

Console notes (measured): Linux → `hvc0`; FreeBSD needs the `virtio_console`
patch (`KERNCONF=VZ`); OpenBSD/NetBSD drive their console on `viogpu`, so serial
capture is blank — time those via a network oracle instead.

## Building a bootable FreeBSD image on macOS

macOS lacks `mdconfig`/`gpart`/`newfs`, so the reference `mkimg.sh` (which runs on
a FreeBSD host) can't be used directly. `build/freebsd/` instead assembles the
image entirely with **host cross-tools**: `installworld`/`installkernel`/
`distribution` with `-DNO_ROOT` produce a staging tree plus a `METALOG` manifest;
FreeBSD's own `makefs` turns that into a UFS2 root (ownership from the manifest)
and a FAT16 ESP; `mkimg` writes the GPT. `makefs` itself isn't built by a stock
`buildworld` — `20-build-host-makefs.sh` builds just that tool (and `libnetbsd`)
without the expensive full bootstrap rebuild.

## Status

Phases 1–3 (host bootstrap, from-source builds, the `vzrun` harness) are done;
Phase 4 is the GitHub Actions CI (`build.yml` on hosted `macos-15`, `boot.yml` on
a self-hosted `m3max-vz` runner, since hosted runners lack nested virtualization).

## Not in this repo

The multi-GB source trees and disk images live on a case-sensitive APFS volume,
not here (see `.gitignore` and `CLAUDE.md`). The Apple-VZ boot harness this work
adapts is a separate reference project.
