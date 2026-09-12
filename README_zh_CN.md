[English](README.md) | **简体中文**

# NixOS for Nabu

为小米平板 5（**nabu**）提供可构建、可更新的 NixOS 系统。当前主线采用
**systemd-boot + 独立内核、initrd 和设备树**，提供 NixOS 原生 generation 启动菜单，
默认桌面为 **niri + Noctalia**。

本项目是 [Mooling0602/nixos-for-nabu](https://github.com/Mooling0602/nixos-for-nabu)
移植工作的延续。原仓库建立了 NixOS 配置、内核与设备软件包、可启动的NixOS镜像及其构建基础；
本分支在此基础上推进验证、Nixpkgs 原生启动管理和日常桌面使用。
本项目离不开诸多其它项目的工作与贡献。有关的项目与贡献者详见下方致谢。

## 存储版本

仓库提供两套存储配置，开箱即可选择。两者共用现有 GPT 中的 `esp` 与 `linux` 分区，不重新分区：

- **`ext4-nabu`（默认，主机名 `nabu`）**：常规 ext4 根文件系统，适合一般用途和日常使用。
- **`impermanent-nabu`**：偏激进的 tmpfs root 方案，面向希望「无状态根 + 声明式持久化」的
  Nix 用户。`/` 为 tmpfs（上限为内存的 25%），`/nix`、`/nix/persistent` 与 `/home` 位于同一
  Btrfs 分区的子卷，重启只丢弃根目录内容。仓库已为该方案准备好 btrfs 镜像目标
  （`nabu-rootfs.btrfs.img`），但仍需实机验证。

目录布局、持久化清单、声明式密码与迁移方式见[存储方案](docs/zh_CN/storage.md)。

## 当前发布

[**v0.1.0-alpha**](https://github.com/hybrid-orbital/nixos-for-nabu/releases/tag/v0.1.0-alpha)
对应提交 `c26c2c1` 正式采用 systemd-boot 的引导方案，维护者通过实机验证 systemd-boot、generation 菜单和
niri + Noctalia 镜像可用，但仍缺乏更充分的测试，并不意味着所有硬件功能已完成适配。

### 已知问题

| 项目 | 当前限制 |
| --- | --- |
| 相机 | 尚不可用 |
| 低功耗休眠 | 可进入 s2idle 且不再秒醒（蓝牙 UART 唤醒问题已修复并实机验证）；电源键、自动挂起与待机功耗仍需推进 |
| 电源键 | 当前被刻意忽略，实用的熄屏、休眠和唤醒方案仍需适配 |
| 启动可靠性 | 偶尔启动失败，原因仍待排查 |
| Wi-Fi 久置卡死 | 空闲较久后 ath10k_snoc 检测到固件/WMI 无响应并反复恢复失败，Wi-Fi 失效，需手动重载驱动（仍待长期观察） |

其余硬件也需要更完整的测试记录，不能仅凭配置中启用驱动就认为已经验证。报告问题时请
附上镜像版本、固件版本、重现步骤和日志；启动失败请区分冷启动与热重启。

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

### 现在提供与后续计划

**现在提供**

- systemd-boot 原生 generation 菜单、Android 启动入口
- niri + Noctalia 桌面及登录界面；横屏菜单、登录界面、桌面及数位笔输出映射
- ext4 镜像，以及实验性的 tmpfs root + Btrfs 版本
- ARM64 原生构建与 x86_64 交叉构建入口；本地镜像导出脚本

**后续计划**

- **构建与缓存：** 改善交叉构建入口和错误提示，记录兼容性；探索 ARM64 原生 builder 与
  二进制缓存，降低平板首次 rebuild 的成本。
- **系统与体积：** 测量闭包和大依赖，缩减 rootfs，拆分公共设备模块与 TTY、niri、KDE
  配置；验证 Btrfs/Impermanence 版本在平板上的行为，完善恢复流程。
- **设备适配：** 排查偶发启动失败，推进相机支持；完成电源键、熄屏、低功耗休眠与唤醒，
  并测量实际待机功耗。
- **CI 与发布：** 建设 GitHub Actions 求值检查和镜像构建，完善缓存、校验值、压缩分卷与
  发布记录；自动构建结果和真机测试结果分别记录。
- **文档与协作：** 保持中英文首页、安装步骤与设备状态同步，为新配置提供可复现的用法和
  验证记录，逐步补齐详细指南的英文版本。

这些是计划工作，目标是[路线图](docs/zh_CN/roadmap.md)，已实现与已验证的部分见
[设备状态](docs/zh_CN/device-status.md)。目前没有独立 TTY/KDE 输出或自动镜像 CI；
欢迎提交带有配置、日志和验证结果的改进，提交与测试约定见[贡献指南](CONTRIBUTING.md)。

## 安装发布镜像

从 [v0.1.0-alpha 发布页](https://github.com/hybrid-orbital/nixos-for-nabu/releases/tag/v0.1.0-alpha)
下载 `esp.img`、`nabu-rootfs.ext4.img.zst.part00` 和 `nabu-rootfs.ext4.img.zst.part01`。
`efi-files.zip` 是 ESP 文件归档，供检查或手动部署，不是分区镜像。

本仓库**不生成 Aloha UEFI / DBKP，也不自动分区**。下面步骤仅适用于已经具备
可用 Aloha/双启动环境、关闭 Secure Boot，且拥有 `esp` 和 `linux` 分区的 nabu。
`esp` 为 FAT EFI 系统分区，挂载于 `/boot/efi`；`linux` 为 ext4 根分区。
刷写会覆盖现有 ESP 和 Linux 数据，操作前备份并确认分区容量。

将两个 rootfs 分卷放在同一目录，依次合并并解压：

```sh
cat nabu-rootfs.ext4.img.zst.part00 nabu-rootfs.ext4.img.zst.part01 > nabu-rootfs.ext4.img.zst
zstd -t nabu-rootfs.ext4.img.zst
zstd -d nabu-rootfs.ext4.img.zst
```

为分卷、合并压缩包和解压镜像预留磁盘空间；设备分区需要容纳**解压后的镜像**。
ESP 镜像为 350105600 字节。此次发布未附 `SHA256SUMS`，`zstd -t` 只检查压缩流完整性。
进入支持该分区布局的 fastboot 环境，确认目标设备及分区后刷写：

```sh
fastboot devices
fastboot getvar partition-size:esp
fastboot getvar partition-size:linux
fastboot flash linux nabu-rootfs.ext4.img
fastboot flash esp esp.img
fastboot reboot
```

如果无法查询或访问这些分区，先检查设备模式与布局，不要猜测其他分区名。
首次启动会将 rootfs 扩展到已有 `linux` 分区大小。

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
# 分支名可以自取；起点既可以是发布标签（v0.1.0-alpha、后续版本…），
# 也可以是 main 或其他分支
git switch -c my-nabu v0.1.0-alpha
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

## 构建入口

仓库预设的 `nixos/configuration.nix` 已经把 `https://nix-nabu.cachix.org` 加入
`nix.settings.extra-substituters`（并带上对应的 `extra-trusted-public-keys`）。该缓存
预构建了 `nixosConfigurations.nabu.config.system.build.kernel` 等产物，所以平板上普通
`nixos-rebuild` 通常不必重新编译内核。如果要在别的 Nix 机器（包括交叉构建主机）上构建，
把那两行加到那台机器的配置里即可：

```nix
nix.settings.extra-substituters = [ "https://nix-nabu.cachix.org" ];
nix.settings.extra-trusted-public-keys = [
  "nix-nabu.cachix.org-1:6oBp/ANDnp5za8MMMfz6EpkJbN1jaRlRpPIoKL4tCGM="
];
```

在启用了 flakes 的 Linux/Nix 环境，按上面的命令检出仓库，从仓库目录运行：

```sh
# 配套构建；保持源码、flake.lock 与本地配置一致
nix build .#nabu-esp .#nabu-rootfs

# 导出 esp.img、efi-files.zip、rootfs 和 SHA256SUMS 到新的目录
# 尚未测试该脚本是否有效，建议手动拷贝 nix build 的产物到你喜欢的地方
bash scripts/build-image.sh
```

当前只有 `nixosConfigurations.nabu`，包含 niri + Noctalia。`nabu-esp`、
`nabu-rootfs`、`nabu-kernel` 提供 `x86_64-linux` 和 `aarch64-linux` 输出；默认输出为 ESP。
导出脚本默认写入新的 `result-images/build-*` 目录，并拒绝覆盖同名产物。
ESP 和 rootfs 必须配套构建，不能混用不同提交、配置或原生/交叉构建的产物。
构建期间保持工作树和 lock 不变，并准备足够磁盘、内存和依赖缓存或网络。

**交叉构建特别说明：** x86_64 → aarch64 与 aarch64 原生构建使用不同的
`buildPlatform` 和构建依赖，通常产生不同的 derivation/store 路径。交叉镜像在平板上
启动后，首次原生 rebuild 仍可能重新构建内核和大量包；已有交叉产物不能保证命中原生缓存。
这来自构建输入差异，不是更换机器本身改变 hash；已有匹配产物或原生缓存仍可复用。
虽然 flake 暴露了交叉构建入口，但是不能保证交叉编译能通过，不同的平台可能需要对nixpkgs做不同的override; 

在本地有 aarch64-linux builder 或者已存在缓存的情况下，可以使用`nix build .#packages.aarch64-linux.<>` 指定 flake outputs 的 system 参数来选择原生 ARM64 输出，不使用交叉编译；

当前 flake 输出未压缩 rootfs；release 中的 zstd 压缩与分卷是发布时的额外处理。
旧 `scripts/qemu-smoke.sh` 尚未适配当前非 UKI 产物，不能作为本版本的测试入口。更多排障与测量方法见[构建指南](docs/zh_CN/building.md)。

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

`pkgs/kernel/patches/` 下的改动来自以下作者与上游提交，本仓库只做回移与适配：

- **`0001-nabu-match-fedora-runtime-fixes.patch`**：sm8150 主线 fork 的下游修复，作者
  **Nicola Guerrera**（提交 `53a8b558`、`01fc3dd3`、`6963e380`）。
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
