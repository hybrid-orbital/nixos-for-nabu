[English](README.md) | **简体中文**

# NixOS for Nabu

为小米平板 5（**nabu**）提供可构建、可更新的 NixOS 系统。当前主线采用
**systemd-boot + 独立内核、initrd 和设备树**，提供 NixOS 原生 generation 启动菜单，
默认桌面为 **niri + Noctalia**。

本项目是 [Mooling0602/nixos-for-nabu](https://github.com/Mooling0602/nixos-for-nabu)
移植工作的延续。原仓库建立了 NixOS 配置、内核与设备软件包、可启动的NixOS镜像及其构建基础；
本分支在此基础上推进验证、Nixpkgs 原生启动管理和日常桌面使用。
本项目离不开诸多其它项目的工作与贡献。有关的项目与贡献者详见下方致谢。

存储版本、持久化目录与构建方式见[存储方案](docs/storage.md)。

## 当前发布

[**v0.1.0-alpha**](https://github.com/hybrid-orbital/nixos-for-nabu/releases/tag/v0.1.0-alpha)
对应提交 `c26c2c1` 正式采用 systemd-boot 的引导方案，维护者通过实机验证 systemd-boot、generation 菜单和
niri + Noctalia 镜像可用，但仍缺乏更充分的测试，并不意味着所有硬件功能已完成适配。

### 已知问题

| 项目 | 当前限制 |
| --- | --- |
| 相机 | 尚不可用 |
| 低功耗休眠 | 尚不可用；锁屏、熄屏不等于进入低功耗状态 |
| 电源键 | 当前被刻意忽略，实用的熄屏、休眠和唤醒方案仍需适配 |
| 启动可靠性 | 偶尔启动失败，原因仍待排查 |
| Wi-Fi MAC 地址 | 每次重启都会随机选择新的地址，不能依赖跨重启保持固定 MAC |
| Wi-Fi 久置卡死 | 空闲较久后 ath10k_snoc 检测到固件/WMI 无响应并反复恢复失败，Wi-Fi 失效，需手动重载驱动 |
| 镜像体积 | 当前 rootfs 较大，缩减闭包与拆分配置是后续重点 |

Wi-Fi MAC 地址变化可能影响基于 MAC 的 DHCP 地址预留和网络准入规则；
目前仅确认这一现象，尚未确定原因或验证修复方法。其他硬件也需要更完整的测试记录，
不能仅凭配置中启用驱动就认为已经验证。报告问题时请附上镜像版本、固件版本、
重现步骤和日志；启动失败请区分冷启动与热重启。

Wi-Fi 在长时间空闲后可能卡死：`ath10k_snoc`（WCN3990）检测到固件/WMI 无响应后会尝试
自动恢复，连续失败后驱动放弃（进入 wedged 状态），Wi-Fi 不再可用。dmesg 中 `mac.c`
的 `WARN_ON` 是恢复失败后的结果，不是根因；根因目前仍在排查，疑似与 SNOC 电源管理 /
WMI 超时有关，与固件版本无关（固件经 TQFTP 加载，已是较新的 HL 3.2.0）。卡死后可
手动重载驱动恢复：

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

### 已实现与计划中的功能

| 现在提供 | 仍需推进 |
| --- | --- |
| systemd-boot 原生 generation 菜单、Android 入口 | 缩减镜像体积、完善发布验证 |
| niri + Noctalia 桌面及登录界面 | TTY、KDE 等独立配置变体 |
| ext4 镜像和实验性的 tmpfs root + Btrfs 版本 | 持久化与恢复的实机验证 |
| ARM64 原生构建与 x86_64 交叉构建入口 | 交叉构建兼容性和缓存体验 |
| 横屏菜单、登录界面、桌面及数位笔输出映射 | 熄屏、休眠、唤醒和其他硬件适配 |
| 本地镜像导出脚本 | GitHub Actions 自动构建与发布设施 |

交叉构建入口存在不等于任意配置均能交叉编译；目前也没有 TTY/KDE 等现成
flake 输出，新增的 Btrfs 版本仍需实机验证。[设备状态](docs/device-status.md)与[路线图](docs/roadmap.md)区分已实现与计划工作。

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

**ESP 必须刷入 `esp`，不是 `boot`。发布页早期说明中的 `fastboot flash boot esp.img`
是笔误。** 如果无法查询或访问这些分区，先检查设备模式与布局，不要猜测其他分区名。
首次启动会将 ext4 扩展到已有 `linux` 分区大小，不会调整分区表。

进入 Noctalia 登录界面后，默认用户和初始密码均为 **`nabu`**。ext4 版本登录后运行
`passwd` 修改密码；无状态版本使用[声明式密码](docs/storage.md#无状态版本的密码)。
当前还启用了 **TTY 自动登录和 SSH 密码认证**，长期使用时应按需要修改配置；
修改密码不会关闭 TTY 自动登录。可用 `systemctl --failed` 检查失败服务，
`findmnt /boot/efi` 检查 ESP 挂载，`bootctl list` 检查启动项。

从旧安装保留数据迁移时不要直接刷写 rootfs；备份后使用设备上的 `nixos-rebuild boot`
部署并验证新启动入口。完整迁移与首次启动说明见[安装指南](docs/installation.md)。

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
被自动清理，手动删除前须确认没有保留的条目引用。更完整的实现见[技术说明](docs/architecture.md)。

## 设备上更新与回滚

在平板上保留仓库配置副本。可以从本次发布创建自己的配置分支：

```sh
git clone https://github.com/hybrid-orbital/nixos-for-nabu.git
cd nixos-for-nabu
git switch -c my-nabu v0.1.0-alpha
```

修改配置后，新文件需要先 `git add` 才能被 Git flake 读取，不必先提交。
从仓库目录更新：

```sh
sudo nixos-rebuild switch --flake .#nabu
```

`switch` 更新启动菜单并激活配置；内核、initrd 和启动参数的改变在重启后生效。
只准备下次启动可使用 `sudo nixos-rebuild boot --flake .#nabu`。
`flake.lock` 固定依赖版本，普通 rebuild 不会自动升级它们；需要更新输入时再运行
`nix flake update` 并构建验证。

系统仍能运行时，可回滚到前一代：

```sh
sudo nixos-rebuild switch --rollback
```

如果新代无法启动，在 systemd-boot 菜单选择保留的旧代 ( 你可以通过使用音量键来选择，按下电源键确认 )。手动选
择旧代不会自动把系统profile 永久回滚，进入系统后检查并回滚或修复配置。
**generation 回滚不会恢复用户文件或数据库。**

共享启动文件减少了重复占用，但不同内核和 initrd 仍会消耗 ESP 空间。可在配置中设置
`boot.loader.systemd-boot.configurationLimit = 10;` 限制菜单代数；它不会自动删除
Nix store 的历史系统。清理前保留已验证可启动的版本，具体方法见[设备使用与回滚](docs/usage-on-device.md)。

## 构建入口

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
交叉编译也可能因包或工具链适配问题失败，求值通过不代表构建或真机启动成功。
`--system aarch64-linux` 只选择原生 ARM64 输出，不会自动提供交叉编译能力；该输出
需要 ARM64 builder、匹配缓存或已配置的模拟环境。

当前 flake 输出未压缩 rootfs；release 中的 zstd 压缩与分卷是发布时的额外处理。
压缩只减少下载大小，不会缩减设备上的系统闭包。旧 `scripts/qemu-smoke.sh` 尚未适配
当前非 UKI 产物，不能作为本版本的测试入口。更多排障与测量方法见[构建指南](docs/building.md)。

## 接下来要做什么

- **构建与缓存：** 改善交叉构建入口和错误提示，记录兼容性，探索 ARM64 原生 builder
  与二进制缓存，降低平板首次 rebuild 的成本。
- **系统与体积：** 测量闭包和大依赖，缩减 rootfs，拆分公共设备模块与 TTY、niri、KDE
  配置；验证新增的 Btrfs/Impermanence 版本在平板上的行为，完善恢复流程。
- **设备适配：** 排查偶发启动失败和 Wi-Fi MAC 地址跨重启变化，推进相机支持；
  探索内核选项，完成电源键、熄屏、低功耗休眠与唤醒，并测量实际待机功耗。
- **CI 与发布：** 建设 GitHub Actions 求值检查和镜像构建，完善缓存、校验值、压缩分卷与
  发布记录；自动构建结果和真机测试结果分别记录。
- **文档与协作：** 保持中英文首页、安装步骤与设备状态同步，为新配置提供可复现的用法和
  验证记录，逐步补齐详细指南的英文版本。

这些是计划工作，目前没有独立 TTY/KDE 输出或自动镜像 CI。
欢迎提交带有配置、日志和验证结果的改进，具体目标见[路线图](docs/roadmap.md)，
提交与测试约定见[贡献指南](CONTRIBUTING.md)。

## 进一步阅读

- [安装、发布镜像与首次启动](docs/installation.md)
- [构建、交叉编译与缓存](docs/building.md)
- [启动架构与 generation](docs/architecture.md)
- [设备上更新、回滚与清理](docs/usage-on-device.md)
- [niri + Noctalia 桌面](docs/desktop.md)
- [设备支持状态](docs/device-status.md) · [启动日志排查](docs/boot-logging.md)
- [路线图](docs/roadmap.md) · [贡献指南](CONTRIBUTING.md)
- [项目沿革、上游与致谢](docs/history.md)

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


更完整的演进记录见[项目沿革](docs/history.md)。

## 许可

项目配置和脚本采用 MIT 许可，见 [LICENSE](LICENSE)。内核、固件、EFI 程序和其他
第三方组件保留各自许可；本仓库的许可不替代它们的许可。
