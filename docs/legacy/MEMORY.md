# MEMORY.md — 早期移植记录（历史资料）

> **已归档为历史资料**，现存放于 `docs/legacy/MEMORY.md`。当前项目已发布
> systemd-boot + niri/Noctalia 镜像。当前操作与目标请阅读
> [README](../../README_zh_CN.md)、[启动架构](../zh_CN/architecture.md) 和
> [路线图](../zh_CN/roadmap.md)。下文的 UKI、构建进度、机器资源和操作约定仅适用于历史上下文。

> 更新：2026-09-03 后续会话；2026-09-03 凌晨追加 **§7（平板本机 Podman 构建环境已打通）**——最新状态先读 §7.6。
> 本文记录当时的移植环境和决策，不能作为当前构建、启动或项目状态的依据。

## 1. 项目目标

把 NixOS 移植到 **Xiaomi Pad 5（nabu）**：
- SoC：Snapdragon 860（SM8150 家族），aarch64，UFS 存储
- 用户设备已运行 [nabu_fedora](https://github.com/jhuang6451/nabu_fedora) 双启动栈：Project-Aloha UEFI + DBKP + rEFInd + ESP 分区（PARTLABEL=esp）+ ext4 rootfs（PARTLABEL=linux）
- **一级交付物：UKI `.efi`**（内核 + initrd + DTB + cmdline 打包的单文件），直接复制进平板 ESP 的 `EFI/nixos/` 即可在 rEFInd 菜单选择启动测试，不动现有系统

## 2. 当前状态

| 项目 | 状态 |
|---|---|
| flake 骨架 / NixOS 配置 / 设备软件包 | ✅ 完成，`nix flake check --no-build` 零错误零警告 |
| 内核配置管线 | ✅ 修复并**验证通过**（见 §3；2026-09-03 又在平板本机容器内复验，见 §7.2） |
| 平板本机 rootless Podman 构建环境 | ✅ **已打通**（2026-09-03，见 §7.2） |
| 内核全量编译 | 🔄 已在本机容器发起过 `nix build .#nabu-uki`，内核驱动对象已编译到 ~15000+.o；**但未产出最终产物（store 无 uki/linux 实际输出，仅 .drv）**，需重跑至完成（见 §7.6，磁盘 110G 充足） |
| UKI 组装 / 上机测试 | ❌ 未开始（依赖编译完成） |

历史失败原因（x86_64 环境，仅参考）：x86_64 交叉编译内核峰值吃约 20G 磁盘（构建 chroot 在 /nix/store 同盘），当时只剩 9.5G，死在 `rsync: Broken pipe`（ENOSPC）。GC 已回收 10.8G。**新设备请确保 ≥ 25G 可用**。

## 3. 关键技术决策（血泪教训，勿回退）

### 3.1 nixpkgs 新版 buildLinux 已移除 `configfile` 参数

pinned nixpkgs（nixos-unstable，rev 83199d0）的 buildLinux **不再接受** `configfile`/`config` 传入——传了会被 `...}@args` 静默吞掉。可用参数只有：`defconfig`（目标名字符串）、`extraConfig`（legacy 答案字符串）、`structuredExtraConfig`（attrset）、`kernelPatches`、`modDirVersion`、`ignoreConfigErrors`。

其内部管线：`make ${defconfig}` 打底 → `generate-config.pl` 跑两遍交互式 `make config`，答案来自 intermediate config（common-config.nix 默认值 + structuredExtraConfig + extraConfig 拼接，**后行覆盖前行**）。

**交互式答案机制的坑**（本会话踩过）：
- `SYMBOL y` 答案在符号被依赖钳制为 m 时是非法答案 → kconfig 重复提问 → perl `die "repeated question"` 构建失败（实例：BRIDGE_NETFILTER=y 但 BRIDGE=m）
- 字符串值必须**去引号裸传**；空字符串值无法表达
- common-config.nix 无条件强制 `NR_CPUS=384`，会覆盖 fragment，需在 extraConfig 末尾钉死
- aarch64 默认 preferBuiltin=true + autoModules=true → 大量 n→m 模块膨胀（正常，勿惊慌）

### 3.2 本项目的内核配置方案（已验证）

`pkgs/kernel/default.nix`：
1. `mergedConfig` derivation（buildPackages.stdenv，构建机上跑 kconfig）复刻 reference RPM 的合并流程：`make ARCH=arm64 defconfig sm8150.config`（源码树内 fragment）→ `sed -i '/^CONFIG_LOCALVERSION=/d'` → `cat extra-sm8150.config`（CRLF 已 sed 剥离）→ 追加 `CONFIG_SPI_MT65XX=n` → `olddefconfig`
2. 产物通过 `defconfigPatch` derivation 生成 unified diff，作为 kernelPatches 注入源码树 `arch/arm64/configs/nabu_defconfig`
3. `buildLinux { defconfig = "nabu_defconfig"; ... }` —— olddefconfig 语义（y 钳制 m 等）完整保留
4. `extraConfig` 额外钉死：`SPI_MT65XX n` / `LOCALVERSION_AUTO n` / `NR_CPUS 8`

**已验证的最终配置**（`nix build .#nabu-kernel.configfile`，几分钟即可复现检查）：
- `CONFIG_LOCALVERSION=""` + AUTO not set → kernel release = `6.17.0`（与 modDirVersion 一致，模块目录 `lib/modules/6.17.0` 已在编译日志证实）
- `CONFIG_SPI_MT65XX` 完全消失（COMPILE_TEST=n 使其不可见 = MTK 驱动不编译）✓
- `CONFIG_TOUCHSCREEN_NT36523_SPI=m`、`CONFIG_DRM_MSM=y`、`CONFIG_SCSI_UFS_QCOM=y`、`NR_CPUS=8`、`CONFIG_HZ_1000=y`、`CONFIG_BRIDGE_NETFILTER=m`（正确钳制）✓
- 设备关键符号全部保留：PINCTRL_SM8150/SM_GCC_8150/SM_GPUCC_8150=y、面板 NT36523/AMS639RQ08=m、KTZ8866 背光=m、CS35L41 音频=m、IDTP9418 充电=m、BATTERY_QCOM_FG/CHARGER_QCOM_SMB2=y、ATH10K_SNOC=m、QRTR 系列齐 ✓

### 3.3 SPI_MT65XX 编译错误（已修复，勿回退）

源码 gitlab.com/sm8150-mainline/linux tag v6.17.0-sm8150（hash `sha256-K+cbu6aGdNxLiM2YimsEQLrL5YQvpPyOcUCvQ2M92Yk=`）。其 arm64 defconfig 被 fork 改成设备就绪版，含 `CONFIG_SPI_MT65XX=y`（错误地为 Qualcomm 板启用 MTK SPI 控制器）。nt36523 触摸屏驱动 `drivers/input/touchscreen/nt36523/nt36xxx.c:1280` 有 `#ifdef CONFIG_SPI_MT65XX` 保护的 MTK 专用代码（引用不存在的 `mtk_chip_config`/`spi_ctrl`/`spi_ctrdata`）→ 编译失败。**禁用 SPI_MT65XX 即根治**，该文件其余部分正常。

### 3.4 其他要点

- 上游 sm8150.config fragment 是 **CRLF 行尾**，且有一行 `CONIG_SERIAL_TEGRA_TCU` typo（上游自己的，无害）。树内 fragment 方式使用则无此问题
- reference RPM 用 `EXTRAVERSION=-sm8150-1 LOCALVERSION=`，其模块目录是 6.17.0-sm8150-1；nixpkgs 内我们用 `modDirVersion="6.17.0"` 自洽命名，**不要**改成带后缀（nixpkgs 自己装配模块）
- 交叉求值：flake 里 `nixpkgs.buildPlatform.system = system` + hostPlatform=aarch64（见 flake.nix `crossConfigFor`）；x86_64 无 aarch64 binfmt，只能交叉
- ukify 的 aarch64 EFI stub 取自 `pkgsCross.aarch64-multiplatform.systemd`（x86_64 主机时）

## 4. 在新设备上继续（操作指引）

```bash
git clone <repo> && cd nixos-for-nabu
nix flake check --no-build          # 应零错误
nix build --no-link --print-out-paths .#nabu-kernel.configfile   # 快速验证配置（几分钟）
grep -E 'NR_CPUS|NT36523_SPI|DRM_MSM=|LOCALVERSION' <上面的输出路径>
nix build .#nabu-uki --print-out-paths   # 全量编译 ~50-60 分钟，需 ≥25G 磁盘
# 产物：<store路径>/nabu-6.17.0-sm8150.efi（另有 nabu.efi 符号链接）
```

上机测试：按 `testing-uki.md`（复制进 ESP、rEFInd 选择、串口/现象判断标准）。

### 下一步任务队列
1. 全量构建 nabu-uki（新设备上）
2. 失败则读 `nix log <drv>` 修（触摸屏已过，若再挂大概率在 drivers/ 后段或 modules-shrunk/initrd/ukify 环节）
3. 成功后上机：UEFI → rEFInd → nabu.efi，按 testing-uki.md 判定
4. rootfs 镜像（`nixos/rootfs-image.nix` 已写好，`scripts/build-image.sh rootfs`；交叉构建 ext4 偶发 flaky，必要时上 aarch64 机器）
5. 首次真机启动调通后：清理 README 状态清单、加 CI、DE 变体（见 README）

## 5. 环境注意事项（跨设备经验）

- **flake dirty-tree**：nix 读 git index，改完文件必须 `git add -A` 再 build/eval，否则用旧内容
- 网络（若还在国内环境）：GitHub 直连慢；镜像 `https://proxy.staringplanet.top/gh/<owner>/<repo>.git`；Clash 代理 `127.0.0.1:7897`（时有时无）
- nixpkgs 内核交叉编译磁盘峰值 ~20G；磁盘紧张时先 `nix-collect-garbage`
- Git 提交流程（用户规矩）：**提交信息必须先给用户审查确认**，格式 `feat: ...` 标题 + 英文正文

## 6. 文件导览

```
flake.nix                     # nixosConfigurations.nabu + packages.{nabu-uki,nabu-kernel}
pkgs/kernel/default.nix       # 内核（本会话重写的核心，见 §3.2）
pkgs/kernel/configs/extra-sm8150.config   # 设备附加 fragment（上游 sm8150.config 用树内版）
pkgs/pd-mapper.nix            # andersson/pd-mapper（qrtr 服务链必需，nixpkgs 无此包）
pkgs/nabu-firmware.nix        # pmOS 设备固件（adsp/cdsp/modem/wlan/触摸）
pkgs/alsa-ucm/                # SM8150 UCM 音频配置
nixos/hardware-nabu.nix       # UFS/ESP 挂载、qrtr→pd-mapper→rmtfs/tqftpserv/q6voiced、RTC、ath10k、zram
nixos/configuration.nix       # 用户 nabu、fcitx5、NetworkManager+iwd
nixos/rootfs-image.nix        # 无特权 mke2fs ext4 rootfs 镜像
scripts/build-image.sh        # esp/uki/rootfs 三种构建模式
testing-uki.md           # 上机测试步骤与判定标准
README.md / README_zh_CN.md   # 双语文档（启动链图、状态清单）
```

## 7. 2026-09-03 凌晨会话：平板本机构建环境打通

> 本节由后续会话补写：原会话（「你好」会话，00:36–01:36，用 B.AI `deepseek-v4-flash-vision-exp` 当 agent 模型）在 01:33 起被提供商连续 `finish_reason: content_filter` 拒答而中断，用户「写入 MEMORY.md」的最后指令未及执行。**教训：该模型不适合当长技术会话的 agent 主力，换 glm-5.3/zai 系列更稳。**

### 7.1 重大事实：这台机器就是平板本身

- 主机名 `mipad5-fedora`，Fedora 43 **aarch64 原生**，8 核 / 11G 内存，根分区剩余 **110G**（充足）
- 无 `/dev/kvm`、`vmx/svm`=0 → 确实无硬件虚拟化，**但不影响**：aarch64 原生构建 UKI/rootfs 无需交叉、无需 KVM（§4 说的"新设备"其实可以是本机）
- 用户原话"本机没条件构建 rootfs（硬件不支持虚拟化）"的顾虑已被排除——rootfs 镜像同样能在本机容器原生构建

### 7.2 已打通并验证的构建环境（rootless Podman）⭐

1. **关键修复**：`/usr/bin/newuidmap`、`/usr/bin/newgidmap` 原本无 setuid/cap 位（rootless podman 报 `cannot set up namespace`）。已用 **request_sudo 技能**（`SUDO_ASKPASS=/usr/bin/ksshaskpass sudo -A`，GUI 密码框；技能在 https://github.com/Mooling0602/mooling-skills/blob/main/request_sudo.md ）给两者 setcap `cap_setgid,cap_setuid=ep` → **rootless podman 完全可用**（alpine 冒烟通过，`podman info` rootless=true）。此修复持久生效，勿回退。
2. **构建容器 `nabu-builder`**（镜像 `docker.io/nixos/nix:latest`，nix 2.35.2，arm64）：仓库 bind 挂载 `/home/mooling/Documents/Workspace/nixos-for-nabu -> /repo`，**host 网络**（走宿主代理）。写入本文件时仍在运行。
3. ✅ **容器内校验构建通过**：`nix build .#nabu-kernel.configfile` 退出码 0，产物 `/nix/store/l94vpbghyhsb9rbac0c86b94ybg0nyna-linux-config-6.17.0-sm8150`；日志在 `/home/mooling/nix-build-tmp/container-configfile.log`（仅预期内的 unused-option 警告，含 SPI_MT65XX）。
4. **复用命令**（改 target 即可）：
   ```bash
   podman exec -w /repo nabu-builder nix --extra-experimental-features 'nix-command flakes' \
     build -L --no-link --print-out-paths --option sandbox false --cores 4 --max-jobs 2 .#nabu-kernel.configfile
   # 全量：把 target 换成 .#nabu-uki（平板 8 核原生编译，建议 --cores 6 --max-jobs 1 并盯内存）
   ```

### 7.3 踩坑记录（勿重走）

- **nix-portable proot 路线已弃用**：`~/.nix-portable`（nix 2.20.6）经 proot 映射 `/nix` 可跑 mini 构建，但 fetchFromGitLab 的 242MB 内核源码解包时 tar `Cannot change mode` 连环失败 → source.drv 挂（小 tar 对照正常，大规模解包崩，未深究）。proot 不在 PATH，需全路径 `$HOME/.nix-portable/bin/proot`
- **bwrap 路线不通**：宿主只读根建不了 `/nix` 顶层挂载点（tmpfs 临时根方案能跑 mini 构建但无必要再折腾）
- `--userns=host` / `--userns=keep-id` 都绕不开 newuidmap 的 cap 需求（setcap 才是正解，见 7.2）
- `~/.local/bin/ddgs`（uv 0.11.28）联网搜索已装好可用；Clash Verge 控制端在 unix socket `/tmp/verge/verge-mihomo.sock`（无 secret，只读探测安全）

### 7.4 网络环境（用户已开代理，勿用镜像）

- Clash Verge **TUN 模式**，mixed-port `7897`；gitlab 242MB 源码经代理实测 400KB/s～1.5MB/s；`cache.nixos.org` 很快（非瓶颈）
- 节点到 gitlab 延迟实测（01:31，结果文件 `/home/mooling/nix-build-tmp/delay_results.txt`，含 2 行订阅信息垃圾行）：最优 **🇺🇸US 04 (315ms) / US 03 (328ms) / US 02 (347ms) / 🇯🇵Japan 01 (477ms)**；当时的 🇲🇾Malaysia 01 为 686ms——切换可提速约一倍，但测试时**未改动**任何节点
- 用户规矩：**不考虑镜像方案**，网络有问题让用户修

### 7.5 用户规矩（新增，叠加 §5）

- 任务清单与沟通**用中文**
- 校验类构建通过后**必须停下等用户明确确认**，才可启动全量 `nabu-uki` 编译
- Git 提交信息仍须先给用户审查（§5 老规矩不变）
- **未获明确指示不主动推进**：不启动构建、不改文件、不部署产物、不推断用户未说明的意图；只在收到明确指令后才做事（2026-09-03 会话明确立规）

### 7.6 当前进度与下一步（新会话从这里接手）

**当前状态**：`nabu-builder` 容器运行中（rootless podman），repo 挂载 `/repo`。内核配置管线已验证通过。全量 `nix build .#nabu-uki` 已在容器内发起并推进到内核驱动编译（`.o` 到 ~15000+），但**未产出生效构建**——`nix path-info /repo#nabu-uki` 显示 `these 14 derivations will be built`，store 里只有 `.drv` 描述文件、无实际产物（无 `-linux-6.17.0-sm8150` 目录、无 vmlinux/Image/efi）。**结论：编译未完成，需重新构建。**

**下一步**：
1. 在 `nabu-builder` 容器内重新启动 `nix build .#nabu-uki`（命令见 7.2；磁盘 110G 充足；平板原生 8 核，建议 `--cores 6 --max-jobs 1` 并盯内存）。nix 会尽量复用已缓存的部分，但内核主体因未成功登记，重跑大概率从头、需预留完整时长。
2. 重跑期间务必**监控电量**（见 7.7）——上次构建期间电量持续下滑、电源充电跟不上。
3. 失败读 `nix log <drv>` 或 `/home/mooling/nix-build-tmp/` 下日志修（若挂大概率在 drivers/ 后段或 modules-shrunk/initrd/ukify 环节）。
4. 成功后产物 `nabu-6.17.0-sm8150.efi`，按 `testing-uki.md` 复制进 ESP 上机测试（rEFInd 选择）。
5. rootfs 镜像（`scripts/build-image.sh rootfs`）同样可在本容器原生构建，无需虚拟化。
6. 首启调通后：清理 README 状态清单、加 CI、DE 变体（同 §4 队列）。

### 7.7 电量/电源注意事项（本次踩坑，勿忽略）

- 电量读取：`/sys/class/power_supply/qcom-battery/capacity`；状态在 `/sys/class/power_supply/qcom-battery/status`。
- **实测**：intensive 内核编译期间，即便 `status=Charging`，充电功率也跟不上编译功耗，电量从 50% 一路降到 1%（02:20 → 04:35）。`qcom-battery` 的 `current_now` 偏低，外接电源实际不足以供满负载。
- **教训**：在平板本机跑全量编译，必须保持**外接电源 + 高功率充电器**，或**降低编译并行度**（`--cores 4`/`--max-jobs 1`）以拉低功耗、给充电留余量；切勿在电量不足时开跑长任务。
- 若需自动化关机/监控：预留脚本可参考 `~/watch_build.sh`（读电量、编译结束读产物、读密码文件后删文件再 `sudo -S poweroff`）。
