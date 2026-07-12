# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**m3max-src-boot-bench** — build FreeBSD / NetBSD / Linux / OpenBSD from source on an
M3 Max (macOS host), boot each in a Virtualization.framework VM, and auto-collect
dmesg + boot timing, all runnable on public GitHub Actions. The full design lives in
`doc/design.md` (in Chinese) and is the source of truth for scope, phases, and CI shape.

The repo is currently **design-only** (`doc/design.md`); implementation has not started
and it is not yet a git repository. The build/boot harness, wrapper scripts, and
workflows described below are the *intended* structure, not yet-existing code.

## Where the large assets live (NOT in this repo)

Sources and images are checked out on a dedicated **case-sensitive APFS volume**,
`/Volumes/cross-buld` (note the spelling — no `i`), because these src trees require
case sensitivity and are tens of GB:

| System | Path | Notes |
|---|---|---|
| FreeBSD | `/Volumes/cross-buld/freebsd-src` | full clone of `git.freebsd.org/src.git` |
| NetBSD | `/Volumes/cross-buld/netbsd-src` | full clone |
| Linux | `/Volumes/cross-buld/linux` | shallow (`--depth 1`), mainline HEAD |
| OpenBSD | `/Volumes/cross-buld/openbsd-snapshot/install79.img` | 7.9 arm64 snapshot (native build in VM, no cross) |

Network access on this host goes through an HTTP proxy: `HTTP_PROXY`/`HTTPS_PROXY` =
`http://192.168.11.81:10082`, and git is configured globally with `http.proxy`/`https.proxy`
to match. Any fetch/clone must go through it.

## The single most important constraint: FreeBSD does not boot on Apple VZ out of the box

Stock FreeBSD/arm64 **silently fails** to boot under Virtualization.framework (200% CPU
spin, no console). A working boot requires a kernel with the Apple-VZ fix chain:

1. GIC version=0 → detect from `GICD_PIDR2` (kernel patch)
2. no readable console → low-level console in `virtio_console(4)` (kernel patch); VZ has
   no UART and a framebuffer-less GPU, so this is the *only* way to see kernel output
3. `vtgpu` hangs → `nodevice virtio_gpu` (kernel config)
4. USB/XHCI is fatal → run the VM **headless, with no USB devices**
5. `boot_verbose` spins forever → never set it in `loader.conf`
6. vtnet feature negotiation fails → `loader.conf` `hw.vtnet.{csum,tso,lro,mq}_disable="1"`

Fixes 1–3 are carried on branch **`apple-vz-virtio-console`** of the fork
`github.com/networkextension/freebsd-src`, already fetched as remote-tracking ref
`networkextension/apple-vz-virtio-console` in the local `freebsd-src` clone. It provides
a ready `sys/arm64/conf/VZ` config (`include GENERIC` + `nodevice virtio_gpu`).

**Consequence for Phase 2:** the FreeBSD leg must build `KERNCONF=VZ` from that branch,
**not** stock GENERIC. Linux boots on the identical VZ config with no changes; NetBSD/OpenBSD
go via EFI.

## Reference implementation to adapt (NOT in this repo)

`/Users/local/github/freebsd-virtualization` is the working Apple-VZ boot harness and the
empirical logbook behind all of the above. The design's Phase 3 `vzrun` should be adapted
from it, not written from scratch:

- `FreeBSD-vz/main.swift` — headless FreeBSD-on-VZ launcher (EFI boot, virtio-console→stdio,
  virtio-blk disk + optional read-only seed as **virtio-blk not USB**, NAT, graphics device
  kept only so EFI has a framebuffer). EFI var store + machine id persist next to the disk image.
- `artifacts/linuxboot.swift` — the Linux `VZLinuxBootLoader` path (`console=hvc0`).
- `FreeBSD-vz/mkimg.sh` — builds the bootable FreeBSD arm64 raw image (GPT ESP+UFS, getty on
  `ttyV0.0`, the loader.conf tunables above, root SSH key).
- Its `CLAUDE.md` is the detailed investigation record; `artifacts/` holds patches, the ACPI
  MADT decode, and expect harnesses.

Building any VZ launcher requires the `com.apple.security.virtualization` entitlement;
ad-hoc codesign (`codesign -s -`) is sufficient. Deployment target macOS 13+.

## Intended per-system build commands (from doc/design.md)

Run from the respective src tree on `/Volumes/cross-buld`. Toolchain deps come from Homebrew
(`llvm lld make coreutils findutils gnu-sed grep gnu-tar bash pkgconf ccache git jq`; `libelf`
for Linux). Wrapper scripts are planned at `build/<os>/build.sh`, emitting normalized JSON
(`{os, git_rev, target, jobs, wall_time_s, ccache_hit_rate, artifact_sha256}`).

```sh
# FreeBSD (full cross) — build from the VZ branch, KERNCONF=VZ
./tools/build/make.py TARGET=arm64 TARGET_ARCH=aarch64 -j16 buildworld buildkernel KERNCONF=VZ
# NetBSD (full cross, best host-independence)
./build.sh -U -u -j16 -m evbarm -a aarch64 release live-image
# Linux (cross kernel only; rootfs is a prebuilt busybox initramfs, not built on macOS)
gmake LLVM=1 ARCH=arm64 -j16 Image
# OpenBSD (native inside VM — control group, not cross)
make obj && make build && make release
```

## Phased plan (see doc/design.md §1–§6 for detail)

1. **Phase 1** — toolchain + host bootstrap validation (dry-runs / tools stages only).
2. **Phase 2** — compile, cold + ccache-warm, capturing wall time and peak memory.
3. **Phase 3** — `vzrun` Swift harness: boot each image, **timestamp every serial line
   host-side** (`[+1.234s]`, the cross-OS timing baseline), watchdog timeout, in-guest rc
   script that dumps dmesg to the console and `poweroff`s. Per-OS serial regexes mark
   kernel-first-line / init / login (see design §3.2).
4. **Phase 4** — GitHub CI: `build.yml` on hosted `macos-15` (public, reproducible),
   `boot.yml` on self-hosted `[self-hosted, m3max-vz]` (hosted runners lack nested virt),
   `openbsd.yml`, `pages.yml`. Self-hosted runner is isolated in a nested macOS guest VM;
   fork-PR triggers on self-hosted jobs are forbidden.

## Project memory

Cross-repo, non-obvious facts are recorded under the session memory dir (`vzrun-reference-impl`,
`freebsd-vz-boot-blockers`). Prefer updating those over duplicating the detail here.
