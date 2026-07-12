# m3max-src-boot-bench

**目标**:在 M3 Max (macOS host) 上以 src 方式构建 FreeBSD / NetBSD / Linux / OpenBSD 四个系统,用 Virtualization.framework 拉起 VM 运行,自动采集 dmesg 与启动耗时,全流程跑在 GitHub Actions 上供公开围观。

---

## 0. 总体架构

```
GitHub (public repo)
├── build 阶段 → GitHub-hosted macos-15 runner (arm64, M系) ← 任何人可复现
│     产物: kernel / world / 磁盘镜像 → upload-artifact
└── boot 阶段 → self-hosted runner (你的 M3 Max, label: m3max-vz)
      下载产物 → Swift VZ harness 启动 → 串口日志打时间戳
      → 提取 dmesg + 计时 JSON → GITHUB_STEP_SUMMARY 表格 + artifact
```

**关键硬件事实**:GitHub 托管的 macOS arm64 runner 目前是 M1/M2 底层的 VM,**不支持嵌套虚拟化**,所以 boot 阶段只能走 self-hosted。而 M3 是 Apple 第一颗支持 nested virt 的芯片(需 macOS 15+),这给了一个安全红利:self-hosted runner 可以跑在 M3 Max 上的一台 macOS guest VM 里,guest 内再开 nested VZ 启动被测系统——公开 repo 的 runner 被隔离在一层 VM 内,不直接暴露宿主。

**四个系统的可交叉性是不对称的**,计划按此分层,不硬凑:

| OS | macOS host 交叉构建 | 路线 |
|---|---|---|
| FreeBSD | 官方支持 (`tools/build/make.py`) | macOS 全交叉 |
| NetBSD | 官方支持 (`build.sh`,最强 host 无关性) | macOS 全交叉 |
| Linux | 支持 (`LLVM=1`) | macOS 交叉编内核,rootfs 用预制 |
| OpenBSD | 官方明确不支持交叉全量构建 | VM 内 native `make build`(仍是 M3 Max 算力,作为对照组) |

---

## 1. Phase 1 — 工具链与宿主环境准备

### 1.1 文件系统
```bash
# 大小写敏感 APFS volume,四个 src 树都放这里
diskutil apfs addVolume disk3 "Case-sensitive APFS" src
```

### 1.2 Homebrew 依赖
```bash
brew install llvm lld make coreutils findutils gnu-sed grep gnu-tar \
             bash pkgconf ccache git jq
# Linux 内核额外: brew install libelf  (arm64 不需要 objtool,依赖比 x86 少)
```

### 1.3 各系统 bootstrap 验证(不做全量,只验证工具链自举)

**FreeBSD** — src 树自带 host 无关引导:
```bash
git clone https://git.freebsd.org/src.git freebsd-src
cd freebsd-src
./tools/build/make.py TARGET=arm64 TARGET_ARCH=aarch64 -n buildworld  # 干跑验证
```
`make.py` 会自举 bmake,再用宿主 clang(或 `--cross-bindir` 指定 brew llvm)。镜像组装用 src 内 host tools 交叉编出的 `makefs`/`mkimg`(CheriBSD 的 cheribuild 已验证此路线在 macOS 上可行,可作参考实现)。

**NetBSD** — `build.sh` 是四家里 host 无关性最好的:
```bash
git clone https://github.com/NetBSD/src.git netbsd-src
cd netbsd-src
./build.sh -U -u -j$(sysctl -n hw.ncpu) -m evbarm -a aarch64 tools
```
`-U` 无特权模式,tools 阶段会把整套交叉工具链(含 makefs)构建到 `obj/tooldir`。

**Linux**:
```bash
git clone --depth 1 https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git
cd linux
gmake LLVM=1 ARCH=arm64 defconfig
```
rootfs 不在 macOS 上做:预制一个 busybox initramfs(在 Linux VM 里一次性构建,checked in 或存 release asset),内核才是被测对象。

**OpenBSD**:
```bash
# 官方 arm64 snapshot 起一个基线 VM,src 树在 VM 内
ftp https://cdn.openbsd.org/pub/OpenBSD/snapshots/arm64/install*.img
```
诚实标注:这一路测的是「M3 Max 虚拟化核上的 native 构建吞吐」,不是交叉编译,正好当 native vs cross 的对照数据。

### 1.4 验收标准
四个树各完成一次最小目标(FreeBSD/NetBSD: tools 阶段;Linux: defconfig + `gmake -j Image` 前 100 个对象;OpenBSD: VM 可 SSH),记录 bootstrap 耗时。

---

## 2. Phase 2 — 编译

统一包装脚本 `build/<os>/build.sh`,输出规范化 JSON:`{os, git_rev, target, jobs, wall_time_s, ccache_hit_rate, artifact_sha256}`。

| OS | 命令 | 产物 |
|---|---|---|
| FreeBSD | `make.py TARGET=arm64 TARGET_ARCH=aarch64 -j16 buildworld buildkernel` + `makefs`/`mkimg` 组装 UFS 镜像 (ESP + loader.efi) | `freebsd.img` |
| NetBSD | `./build.sh -U -u -j16 -m evbarm -a aarch64 release live-image` | `arm64.img` (自带 EFI) |
| Linux | `gmake LLVM=1 ARCH=arm64 -j16 Image` | `Image` + 预制 `initramfs.cpio.gz` |
| OpenBSD | VM 内 `make obj && make build && make release` | `miniroot/install 镜像` |

计时口径:冷缓存全量 + ccache 热缓存增量各一次,记录 `hw.ncpu`、`-j`、峰值内存(`/usr/bin/time -l`)。这组数字本身就是 M3 Max 交叉编译能力的公开 benchmark。

---

## 3. Phase 3 — 运行与 dmesg 计时

### 3.1 Harness:`vzrun`(~400 行 Swift CLI)
- `VZVirtualMachineConfiguration` + `VZEFIBootLoader`(FreeBSD/NetBSD/OpenBSD 走 EFI)或 `VZLinuxBootLoader`(Linux 直接喂 `Image`,免 bootloader)
- virtio-blk 挂镜像、virtio-net NAT、串口重定向到文件
- **host 侧对串口每一行打单调时钟时间戳** `[+1.234s]` —— 这是跨四系统统一的计时基准,不依赖 guest 是否支持 printk timestamp
- 超时看门狗(默认 300s),异常退出即 CI fail

### 3.2 计时标记(串口正则,per-OS)
| 事件 | FreeBSD | NetBSD | OpenBSD | Linux |
|---|---|---|---|---|
| t0 | VZ start | 同左 | 同左 | 同左 |
| kernel 首行 | `Copyright.*FreeBSD` | `NetBSD.*aarch64` | `OpenBSD.*GENERIC` | `Booting Linux` |
| init 启动 | `exec /sbin/init` | `init: entering` | `init: kern securelevel` | `Run /init` |
| 就绪 | `login:` | `login:` | `login:` | rc 脚本 marker |

### 3.3 guest 内自动化
镜像里注入一个 rc 脚本(FreeBSD `rc.local` / NetBSD `rc.local` / OpenBSD `rc.firsttime` / Linux init):
```sh
dmesg > /dev/console        # 完整 dmesg 打到串口,host 侧全量捕获
echo "BENCH_READY $(sysctl -n kern.boottime 2>/dev/null)"
poweroff                    # 干净退出 → harness 计算总时长
```
增强项(可选):
- Linux 开 `CONFIG_PRINTK_TIME`,guest 内 dmesg 自带时间戳
- FreeBSD kernel 加 `options TSLOG`,用 Colin Percival 的 boot-profiling 脚本出火焰图级的启动剖析——这是四家里最细的启动数据,值得单独展示

### 3.4 输出
每次 run 产出 `results/<os>/<git_rev>.json` + `dmesg.txt` + `serial.log`,并在 `GITHUB_STEP_SUMMARY` 渲染:

```
| OS      | build (cold) | build (warm) | kernel→login | dmesg lines |
|---------|-------------:|-------------:|-------------:|------------:|
| FreeBSD |      41m 12s |       6m 03s |        4.81s |         312 |
| NetBSD  |          ... |          ... |          ... |         ... |
```

---

## 4. Phase 4 — GitHub CI

### 4.1 Workflows
```
.github/workflows/
├── build.yml     # matrix: [freebsd, netbsd, linux] × macos-15 (hosted, 公开可复现)
│                 # ccache 用 actions/cache;产物 upload-artifact (保留 14 天)
├── boot.yml      # needs: build → runs-on: [self-hosted, m3max-vz]
│                 # 下载产物 → vzrun → 解析 → summary + artifacts
├── openbsd.yml   # self-hosted only (VM 内 native build),周期触发
└── pages.yml     # results/*.json → 静态 dashboard (历史趋势折线) → GitHub Pages
```

### 4.2 Self-hosted runner 安全(公开 repo 的硬性要求)
- runner 跑在 M3 Max 上的 macOS guest VM 内(nested virt),非宿主直跑
- Settings → Actions:**禁止 fork PR 触发 self-hosted job**;boot.yml 仅 `push`(main, 本人)+ `workflow_dispatch`
- runner 用户无 sudo,工作目录独立 volume,每次 job 后快照回滚(可用 `tart` 管理 runner VM 生命周期)

### 4.3 围观体验
- README 顶部放最新一轮的耗时徽章 + summary 表格截图
- 每个 run 的 dmesg.txt 直接作为 artifact 可下载——"在 M3 Max 上从 src 到四个 OS 的 dmesg" 本身就是传播点
- Pages dashboard 展示随上游 commit 的构建/启动时长趋势,顺带能抓到上游回归

---

## 5. 里程碑

| 周 | 交付 |
|---|---|
| W1 | Phase 1 全部验收;`vzrun` 能用官方镜像启动 FreeBSD + Linux 并打时间戳 |
| W2 | FreeBSD + Linux 全链路(本地):src → 镜像 → boot → JSON |
| W3 | NetBSD 接入;OpenBSD VM native 流程;TSLOG 剖析 |
| W4 | CI 双层跑通,Pages 上线,写 announce(FreeBSD hackers / HN) |

## 6. 风险与预案
- **FreeBSD 镜像组装在 macOS 上踩坑** → 降级方案:kernel-only 交叉 + 官方 rootfs 换内核;或参考 cheribuild 的 disk-image 实现
- **NetBSD live-image 在 VZ EFI 下不起** → 先用 `-m evbarm64` GENERIC64 + 官方 arm64 镜像换内核
- **hosted macos-15 runner 太慢/配额** → build 也挪到 self-hosted,hosted 只保留 lint + 干跑,保住"可复现"叙事
- **上游 HEAD 构建断裂** → 默认 pin 到最近 release tag,每周一个 job 追 HEAD 并允许 fail

## 7. 与现有工作的衔接
- `vzrun` 的 VZ 封装可直接沉淀为 polard/APR 的 VM 管理模块
- FreeBSD arm64 16K page、Virtualization.framework 两条 hackers 邮件工作线在此获得公开、可复现的数据支撑
- OpenBSD/NetBSD 的 dmesg 语料顺带成为 APR 设计的参考(三家 BSD 的 arm64 启动路径对比)

