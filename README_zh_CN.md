[English](README.md) | **简体中文**

# NixOS for Nabu

为小米平板 5（**nabu**）提供可构建、可更新的 NixOS 系统。当前主线采用
**systemd-boot + 独立内核、initrd 和设备树**，提供 NixOS 原生 generation 启动菜单，
默认桌面为 **niri + Noctalia**。

本项目是 [Mooling0602/nixos-for-nabu](https://github.com/Mooling0602/nixos-for-nabu)
移植工作的延续。原仓库建立了 NixOS 配置、内核与设备软件包、可启动的NixOS镜像及其构建基础；
本分支在此基础上推进验证、Nixpkgs 原生启动管理和日常桌面使用。
本项目离不开诸多其它项目的工作与贡献。有关的项目与贡献者详见下方致谢。

## 文件系统版本

仓库提供两套文件系统配置，开箱即用。两者都使用 `esp` (用作/boot) 与 `linux` (用作/) 分区，不重新分区：

- **`ext4-nabu`（默认，主机名 `nabu`）**：常规 ext4 根文件系统，适合一般用途和日常使用。
- **`impermanent-nabu`**：偏激进的 tmpfs root 方案，面向希望「无状态根 + 声明式持久化」的
  Nix 用户。`/` 为 tmpfs（上限为内存的 25%），`/nix`、`/nix/persistent` 与 `/home` 位于同一
  Btrfs 分区的子卷，重启只丢弃根目录内容。

目录布局、持久化清单、声明式密码与迁移方式见[存储方案](docs/zh_CN/storage.md)。

## 当前发布

[**v2026.09.12.1.1**](https://github.com/hybrid-orbital/nixos-for-nabu/releases/tag/v2026.09.12.1.1)
对应提交 `51763f8`，由 GitHub Actions 在原生 ARM64 环境构建并发布，提供 ext4 和
tmpfs root + Btrfs 两套配套 ESP/rootfs 镜像、压缩分卷、校验文件及构建记录。
本次发布包含挂起、屏幕唤醒和 Wi-Fi 相关修复，以及触屏输入和固件体积优化。
CI 构建成功不等于实机验证；无状态版本的完整实机回归测试仍待完成。

### 已知问题

| 项目 | 当前限制 |
| --- | --- |
| Wi-Fi 久置卡死 | 空闲较久后 ath10k_snoc 检测到固件/WMI 无响应并反复恢复失败，Wi-Fi 失效，需手动重载驱动（仍待长期观察） |
| 低功耗休眠 | 目前修复后可通过 `systemctl suspend` 进入 s2idle；待机功耗需进一步确定 |
| 电源键 | 出于实用性的考量，logind 会忽略电源键的行为，交给桌面环境处理。按下电源键不会进入挂起（但仍能触发从挂起中恢复）|
| 启动可靠性 | 偶尔启动失败，原因仍待排查 |
| 扬声器 | 右上角的扬声器尚不可用、可能存在爆音问题 |
| 麦克风 | 尚不可用 |
| 相机 | 尚不可用 |

### 已修复或已缓解

跨重启随机 Wi-Fi MAC 的问题已解决：通用 board-2.bin 不含 MAC，内核补丁
（`pkgs/kernel/patches/0002-nabu-ath10k-mac-address.patch`）从 SMBIOS 主板序列号派生
稳定的本地管理地址，必要时可用 `ath10k_core.macaddr=` 模块参数覆盖。方案源自
[TwinbornPlate75/linux-nabu](https://github.com/TwinbornPlate75/linux-nabu)。

**挂起后立即唤醒（suspend-to-idle 秒醒）** —— 已修复，并在真机确认可以正常进入挂起。

- **主要原因**：蓝牙 UART（`uart13` / `c8c000.serial`）的端口在挂起期间保持打开，
  GENI 串口的 runtime suspend 回调不会执行，sleep pinctrl 因此从未生效，QUP13 引脚停在
  `bias-disable` 的默认态；再加上 TLMM 会锁存掩蔽期间的边沿，专用唤醒中断在被使能的
  瞬间就触发。
- **解决方案**：回移上游提交 `d0cd9c8d0fd5`（"serial: qcom-geni: add force suspend/resume
  to system sleep callbacks"），让系统睡眠回调强制走 runtime suspend；补丁见
  `pkgs/kernel/patches/0005-qcom-geni-serial-force-suspend-system-sleep.patch`。
- **贡献来源**：上游作者 **Praveen Talari**（Qualcomm），经 tty-next 合入 v6.18-rc4，
  6.17.y 中没有该修复。
- **仍需注意**：这是针对 6.17 分支的回移；蓝牙工作与唤醒能力保持不变，后续合并上游
  代码时应确认该修复已被吸收。

<details><summary>技术细节（点开查看）</summary>

nabu 的 WCN3991 蓝牙 UART 是常开 serdev，系统挂起时 runtime PM 引用计数不会归零
（PM core 在 prepare 阶段还会额外持有一个引用），于是 `qcom_geni_serial_runtime_suspend()`
从不执行、`geni_se_resources_off()` 被跳过，sleep pinctrl（`qup_uart13_sleep`：GPIO 输入 +
`gpio46` 上拉）也没机会生效。蓝牙控制器的收发活动产生下降沿，而 pinctrl-msm 对边沿型中断
在掩蔽期间仍会锁存状态位，使专用唤醒中断在 `dpm_suspend_noirq` 被使能的瞬间即触发，
于是刚进入 suspend-to-idle 便立即恢复。补丁保留了上游的作者、提交信息与 sign-off 链，
仅 rebase 了 diff 上下文。

</details>

**Wi-Fi 久置卡死（`ath10k_snoc` / WCN3990）** —— 根因已定位并回移上游修复，仍需长期观察。

- **主要原因**：`ath10k` 的恢复检查在 QMI 上报路径上同步执行，并把恢复工作排到有序
  （ordered）工作队列，后续触发被合并吞掉——恢复从未真正执行，却持续消耗「连续失败」
  计数，最终把设备判为 `WEDGED`，`ath10k_start()` 从此持续失败（dmesg 中 `mac.c` 的
  `WARN_ON` 只是症状而非根因）。
- **解决方案**：回移上游提交 `f35a07a4842a`（"wifi: ath10k: move recovery check logic into
  a new work"），把检查移到独立工作队列并在 `ath10k_stop()` 中取消；补丁见
  `pkgs/kernel/patches/0004-nabu-ath10k-recovery-check-workqueue.patch`。
- **贡献来源**：上游作者 **Kang Yang**（Qualcomm）。与固件版本无关（经 TQFTP 加载的固件
  已是较新的 HL 3.2.0）。
- **仍需注意**：该回移尚未经历足够长的实机观察；若再次卡死，需要让驱动重新 probe
  （仅重启 NetworkManager 无效），可手动重载驱动恢复：

```sh
# 方法一（推荐）：重新绑定平台设备，不需要额外工具
ls /sys/bus/platform/drivers/ath10k_snoc/          # 确认设备名（通常为 18800000.wifi）
nmcli radio wifi off
echo 18800000.wifi | sudo tee /sys/bus/platform/drivers/ath10k_snoc/unbind
echo 18800000.wifi | sudo tee /sys/bus/platform/drivers/ath10k_snoc/bind
nmcli radio wifi on

# 方法二：卸载/重载内核模块
sudo systemctl stop NetworkManager
sudo modprobe -r ath10k_snoc
sudo modprobe ath10k_snoc
sudo systemctl start NetworkManager
```

仅重启 NetworkManager 无法恢复，必须让驱动重新 probe（unbind/bind 或重载模块）。

<details><summary>根因细节（点开查看）</summary>

`ath10k` 的恢复记账会把设备判为 `WEDGED`，而这些恢复其实从未真正执行：检查逻辑在 QMI
上报路径（`ath10k_snoc_fw_indication()`）上同步运行，最多阻塞 5 秒等待上一次恢复完成，
然后把 `restart_work` 排到有序工作队列，后续触发会被合并吞掉，于是每次触发都只是白白
消耗一次「连续失败」计数；此后 `ath10k_start()` 会持续失败，哪怕接口本来是 down 的。

</details>

### 后续计划

- 提供 TTY、niri、KDE 等配置变体，缩减 rootfs 体积。
- 将目前的配置拆分成 NixOS 模块；通过 flake 提供只包含硬件相关配置的模块，方便在其它项目中导入。
- 排查仍存在的硬件问题。

这些是计划工作，目标是[路线图](docs/zh_CN/roadmap.md)，已实现与已验证的部分见
[设备状态](docs/zh_CN/device-status.md)。目前没有独立 TTY/KDE 输出；
欢迎提交带有配置、日志和验证结果的改进，提交与测试约定见[贡献指南](CONTRIBUTING.md)。

## 安装发布镜像

从 [v2026.09.12.1.1 发布页](https://github.com/hybrid-orbital/nixos-for-nabu/releases/tag/v2026.09.12.1.1)
下载所选版本前缀（`ext4-nabu-` 或 `impermanent-nabu-`）的全部附件，包括 ESP 镜像、
所有 rootfs 分卷、校验文件、`RESTORE.txt` 和 `BUILD-INFO.txt`。
`*-esp.zip` 是 ESP 文件归档，供检查或手动部署，不是分区镜像。
ESP 与 rootfs 必须来自同一发布和同一文件系统版本。以下以 ext4 为例；无状态版本将
命令中的 `ext4-nabu-` 全部替换为 `impermanent-nabu-`。

本仓库**不生成 Aloha UEFI / DBKP，也不自动分区**。下面步骤仅适用于已经具备
可用 Aloha/双启动环境、关闭 Secure Boot，且拥有 `esp` 和 `linux` 分区的 nabu。
`esp` 为 FAT EFI 系统分区，挂载于 `/boot/efi`；`linux` 承载 ext4 或 Btrfs 文件系统。
刷写会覆盖现有 ESP 和 Linux 数据，操作前备份并确认分区容量。

将所选版本的全部附件放在同一目录，校验下载文件、合并解压，再校验原始镜像：

```sh
sha256sum -c ext4-nabu-SHA256SUMS
cat ext4-nabu-rootfs.image.zst.part-* | zstd -d --sparse -o ext4-nabu-rootfs.image
sha256sum -c ext4-nabu-SHA256SUMS.images
```

为分卷和解压镜像预留磁盘空间；设备分区需要容纳**解压后的镜像**。
确认所有校验通过，并按镜像的实际大小检查分区容量。
进入支持该分区布局的 fastboot 环境，确认目标设备及分区后刷写：

```sh
fastboot devices
fastboot getvar partition-size:esp
fastboot getvar partition-size:linux
fastboot flash linux ext4-nabu-rootfs.image
fastboot flash esp ext4-nabu-esp.image
fastboot reboot
```

如果无法查询或访问这些分区，先检查设备模式与布局，不要猜测其他分区名。
首次启动会将 ext4 或 Btrfs 文件系统扩展到已有 `linux` 分区大小。

进入 Noctalia 登录界面后，默认用户和初始密码均为 **`nabu`**。ext4 版本登录后运行
`passwd` 修改密码；无状态版本使用[声明式密码](docs/zh_CN/storage.md#无状态版本的密码)。

当前还启用了 **TTY 自动登录和 SSH 密码认证**，长期使用时应按需要修改配置；
修改密码不会关闭 TTY 自动登录。

可用 `systemctl --failed` 检查失败服务，
`findmnt /boot/efi` 检查 ESP 挂载，`bootctl list` 检查启动项。

## 启动与 generation

```text
Project Aloha UEFI / 现有 DBKP 启动环境
  → systemd-boot（EFI/BOOT/BOOTAA64.EFI）
    → 选择 NixOS generation
      → 对应内核 + initrd + 外部 DTB + init=<该代系统>/init
        → ext4 rootfs → Noctalia 登录界面 → niri 桌面
    → Android 启动入口
```

`boot.loader.systemd-boot.enable = true` 与 `installDeviceTree = true` 负责设备上的
启动部署；相同启动文件可以在各代之间复用。无需每代打包 UKI，也无需维护
`nabu-previous.efi` 或把所有启动项指向可变的 system profile。
每个条目的 `init=` 指向该代具体的 Nix store 系统闭包，旧代保留配套的启动文件，
因此可以从菜单恢复先前的系统配置。外部 DTB 已在当前关闭 Secure Boot 的固件环境验证可用，
UKI 不再是传递设备树的必要条件。

首次 ESP 仍由本项目的 `system.build.esp-image` 逻辑组装，只有一个初始 generation；日常 rebuild 才由
nixpkgs 的 systemd-boot 安装器部署并管理各代。初始文件与旧 UKI/rEFInd 文件不一定会
被自动清理，手动删除前须确认没有保留的条目引用。更完整的实现见[技术说明](docs/zh_CN/architecture.md)。

## 设备上更新与回滚

在平板上保留仓库配置副本。可以从本次发布创建自己的配置分支：

```sh
git clone https://github.com/hybrid-orbital/nixos-for-nabu.git
cd nixos-for-nabu
# 分支名可以自取；起点既可以是发布标签（v2026.09.12.1.1、后续版本…），
# 也可以是 main 或其他分支
git switch -c my-nabu v2026.09.12.1.1
```

修改配置后，新文件需要先 `git add` 才能被 Git flake 读取。
从仓库目录更新：

```sh
# 日常更新：不带 #配置名 时，按当前主机名选择配置（ext4 变体的主机名就是 nabu）
sudo nixos-rebuild switch --flake .

# 也可以显式指定变体：ext4 用 nabu，无状态 root 用 impermanent-nabu
sudo nixos-rebuild switch --flake .#nabu
sudo nixos-rebuild switch --flake .#impermanent-nabu
```

`switch` 更新启动菜单并激活配置；内核、initrd 和启动参数的改变在重启后生效。
只准备下次启动可使用 `sudo nixos-rebuild boot --flake .#nabu`。

系统仍能运行时，可回滚到前一代：

```sh
sudo nixos-rebuild switch --rollback
```

如果新代无法启动，在 systemd-boot 菜单选择保留的旧代 ( 你可以通过使用音量键来选择，按下电源键确认 )。手动选择旧代不会自动把系统profile 永久回滚，进入系统后检查并回滚或修复配置。
**generation 回滚不会恢复用户文件或数据库。**

共享启动文件减少了重复占用，但不同内核和 initrd 仍会消耗 ESP 空间。可在配置中设置
`boot.loader.systemd-boot.configurationLimit = 10;` 限制菜单代数；它不会自动删除
Nix store 的历史系统。清理前保留已验证可启动的版本，具体方法见[设备使用与回滚](docs/zh_CN/usage-on-device.md)。

从旧安装保留数据迁移时不要直接刷写 rootfs：备份后使用设备上的 `nixos-rebuild boot`
部署并验证新启动入口，完整迁移与首次启动说明见[安装指南](docs/zh_CN/installation.md)。

## 构建

### 二进制缓存

仓库预设的 `nixos/configuration.nix` 包含了一个 Cachix 二进制缓存 `https://nix-nabu.cachix.org`。该缓存通过 GitHub Actions 提供 `nixosConfigurations.nabu.config.system.build.kernel` 的构建产物，所以在平板上使用 `nixos-rebuild` 通常不必重新编译内核。

如果要在别的 Nix 机器（包括交叉构建主机）上构建，可以考虑把该缓存添加到那台机器的配置里：

```nix
nix.settings.extra-substituters = [ "https://nix-nabu.cachix.org" ];
nix.settings.extra-trusted-public-keys = [
  "nix-nabu.cachix.org-1:6oBp/ANDnp5za8MMMfz6EpkJbN1jaRlRpPIoKL4tCGM="
];
```
### Flake outputs

在启用了 flakes 的 Linux/Nix 环境，检出仓库，从仓库目录运行：

```sh
# 内核（第二条命令始终选择原生 ARM64 配置）
nix build .#nabu-kernel
nix build .#nixosConfigurations.nabu.config.system.build.kernel

# ext4 的 ESP 文件与镜像、rootfs 镜像
nix build .#ext4-nabu-esp
nix build .#nabu-esp       # ext4-nabu-esp 的别名
nix build .#ext4-nabu-rootfs
nix build .#nabu-rootfs    # ext4-nabu-rootfs 的别名

# Btrfs + tmpfs root
nix build .#impermanent-nabu-esp
nix build .#impermanent-nabu-rootfs

# 系统闭包（原生 ARM64 配置）
nix build .#nixosConfigurations.impermanent-nabu.config.system.build.toplevel
nix build .#nixosConfigurations.ext4-nabu.config.system.build.toplevel
```

ESP 与 rootfs 必须使用相同的源码、`flake.lock`、配置和构建平台，构建期间保持这些输入不变。

**关于交叉编译**

在 `x86_64-linux` 上运行 `nix build .#nabu-kernel` 或上述简写的镜像输出时，
flake 会选择 x86_64 → aarch64 交叉编译。在 `aarch64-linux` 上则选择原生构建。
两者的 `buildPlatform` 和构建依赖不同，通常产生不同的 derivation 和 store 路径；
交叉镜像在平板上首次原生 rebuild 时，可能需要重新构建内核和大量包，除非已有匹配的原生产物或缓存。

交叉编译入口是项目早期只有 `x86_64-linux` 构建机器时的变通方案。随着 nixpkgs 更新，
不能保证它始终可用，可能需要额外的 override。当前 flake 没有 `aarch64-darwin` 包输出；
在 Apple Silicon 上可通过 `aarch64-linux` 虚拟机或远程 Linux builder 构建原生产物。

显式选择原生 ARM64 包输出：

```sh
nix build .#packages.aarch64-linux.nabu-kernel
```

这只选择输出平台，不会自动配置 builder。实际构建需要 `aarch64-linux` builder，
或在 NixOS Linux 主机上启用 `boot.binfmt.emulatedSystems = [ "aarch64-linux" ];`
以使用模拟执行；若全部产物已命中缓存，则无需本地编译。

更多说明见[构建指南](docs/zh_CN/building.md)。


## 进一步阅读

详细文档中英双语：中文在 `docs/zh_CN/`，英文在 `docs/`；已归档的历史资料见
`docs/legacy/`。

- [安装、发布镜像与首次启动](docs/zh_CN/installation.md)
- [构建、交叉编译与缓存](docs/zh_CN/building.md)
- [启动架构与 generation](docs/zh_CN/architecture.md)
- [设备上更新、回滚与清理](docs/zh_CN/usage-on-device.md)
- [niri + Noctalia 桌面](docs/zh_CN/desktop.md)
- [设备支持状态](docs/zh_CN/device-status.md) · [启动日志排查](docs/zh_CN/boot-logging.md)
- [路线图](docs/zh_CN/roadmap.md) · [贡献指南](CONTRIBUTING.md)
- [项目沿革、上游与致谢](docs/zh_CN/history.md)

## 致谢

感谢 **Mooling0602** 为小米平板5 的 NixOS 移植工作提供了 配置骨架、内核和固件软件包（这相当重要），
到 rootfs 镜像、早期启动与显示适配，当前系统建立在这些成果之上。rEFInd + UKI
方案为继续构建、调试和真机验证提供了方便的起点。

nabu 上的 Linux 也依赖多个社区持续推进固件、内核、设备服务与桌面支持：

- [Mooling0602/nixos-for-nabu](https://github.com/Mooling0602/nixos-for-nabu)：原始 NixOS 移植与镜像基础。
- [Mooling0602/nabu-nixos-kde-config](https://github.com/Mooling0602/nabu-nixos-kde-config)：相关 nabu NixOS 实践；当前桌面与启动实现以本仓库为准。
- [jhuang6451/nabu_fedora](https://github.com/jhuang6451/nabu_fedora)：镜像、内核配置、设备服务及硬件适配参考。
- [nabu_fedora_packages](https://github.com/jhuang6451/nabu_fedora_packages)：设备软件包及引导资源；本仓库在 boot.nix 中固定了相应资源 fork 的版本与哈希。
- [sm8150-mainline/linux](https://gitlab.com/sm8150-mainline/linux)：SM8150 系列主线内核工作。
- [Project Aloha](https://github.com/Project-Aloha/mu_aloha_platforms)：设备 UEFI 固件。
- [rodriguezst/nabu-dualboot-img](https://github.com/rodriguezst/nabu-dualboot-img)：nabu 双系统启动工作。
- [GopRotate](https://github.com/apop2/GopRotate)：EFI 显示旋转驱动。
- [nabu-firmware](https://gitlab.postmarketos.org/panpanpanpan/nabu-firmware)：设备固件打包来源。
- [NixOS / nixpkgs](https://github.com/NixOS/nixpkgs)、[systemd](https://github.com/systemd/systemd)：配置系统与原生启动管理。
- [niri](https://github.com/niri-wm/niri)、[Noctalia](https://github.com/noctalia-dev/noctalia-shell)：当前桌面与 shell。
- map220v、timoxa0、nik012003、panpantepan，以及持续参与 nabu Linux 适配和测试的社区贡献者。


### 内核补丁来源

`pkgs/kernel/patches/` 下的改动包含上游回移和本地适配，已核实的来源如下：

- **`0001-nabu-match-fedora-runtime-fixes.patch`**：本仓库提交
  [`f1a0391`](https://github.com/hybrid-orbital/nixos-for-nabu/commit/f1a039140353fad1d336751e42c95a530056e5ba)
  引入的组合补丁。其中关闭霍尔传感器唤醒、修正触屏 `getClient(void)` 声明、移除
  idtp9418 未初始化变量及日志的改动，分别与 **Nicola Guerrera** 的上游提交
  [`53a8b558`](https://gitlab.com/sm8150-mainline/linux/-/commit/53a8b55839d1cd4be6dc25f11aeb93e8348cc270)、
  [`01fc3dd3`](https://gitlab.com/sm8150-mainline/linux/-/commit/01fc3dd3c8317362bcddd9eab9f243909621a4a0)、
  [`6963e380`](https://gitlab.com/sm8150-mainline/linux/-/commit/6963e3800a8e8059c5f01b01dd8e2a5e6a28209a)
  一致。
- **`0001-drm-msm-dsi-Move-MI_DRM_BLANK_UNBLANK-notification-t.patch`**：
  **TwinbornPlate75** `<3342733415@qq.com>`，提交 `bc048e06`。
- **`0002-nabu-ath10k-mac-address.patch`**：方案源自
  [TwinbornPlate75/linux-nabu](https://github.com/TwinbornPlate75/linux-nabu)。
- **`0003-nabu-adreno-do-not-abort-system-suspend.patch`**：思路源自 `CFM880/nabu-iris`
  的 iris VPU5 挂起修复（`42085a8`）。
- **`0004-nabu-ath10k-recovery-check-workqueue.patch`**：上游 `f35a07a4842a`
  （"wifi: ath10k: move recovery check logic into a new work"），作者 **Kang Yang**（Qualcomm）。
- **`0005-qcom-geni-serial-force-suspend-system-sleep.patch`**：上游 `d0cd9c8d0fd5`
  （"serial: qcom-geni: add force suspend/resume to system sleep callbacks"），
  作者 **Praveen Talari**（Qualcomm）。

更完整的演进记录见[项目沿革](docs/zh_CN/history.md)。

## 许可

项目配置和脚本采用 MIT 许可，见 [LICENSE](LICENSE)。内核、固件、EFI 程序和其他
第三方组件保留各自许可；本仓库的许可不替代它们的许可。
