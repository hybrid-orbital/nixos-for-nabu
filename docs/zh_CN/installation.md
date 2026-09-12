[English](../installation.md) | **简体中文**

# 安装与首次启动

[返回项目首页](../../README_zh_CN.md)

当前发布为 [v0.1.0-alpha](https://github.com/hybrid-orbital/nixos-for-nabu/releases/tag/v0.1.0-alpha)，
维护者已验证 niri + Noctalia 和 systemd-boot generation 菜单可用。
仍有相机不可用和偶发启动失败（重启后随机 Wi-Fi MAC 地址问题已解决；低功耗休眠已可
进入 s2idle，蓝牙 UART 秒醒问题已修复），
见[设备状态](device-status.md)。

## 适用设备与已有环境

仅面向小米平板 5（nabu）。本仓库生成 rootfs 和 ESP，**不生成 Aloha UEFI 或 DBKP 镜像**，
也不自动为设备分区。以下步骤假设已经具备可用的 Aloha/双启动环境、关闭 Secure Boot，
且分区布局与 [`nixos/hardware-nabu.nix`](../../nixos/hardware-nabu.nix) 一致：

| 分区标签 | 用途 | Linux 挂载点 |
| --- | --- | --- |
| `esp` | FAT EFI 系统分区，存放 systemd-boot 和启动文件 | `/boot/efi` |
| `linux` | ext4 NixOS 根文件系统 | `/` |

不要仅凭设备型号假定现有分区布局正确。刷写会替换现有 Linux 数据和 ESP 内容，
包括旧发行版和自定义启动配置；先备份。该镜像保留 Android 启动入口，但不备份 Android
或其他数据，也不保证任意第三方固件和分区布局兼容。

## 下载与合并

`v0.1.0-alpha` 提供：

- `esp.img`：350105600 字节的 ESP 分区镜像。
- `efi-files.zip`：ESP 内文件的归档，供检查或手动部署；不是分区镜像。
- `nabu-rootfs.ext4.img.zst.part00` 与 `nabu-rootfs.ext4.img.zst.part01`：压缩 rootfs 的两个分卷。

将两个分卷放在同一目录，按顺序合并后解压：

```sh
cat nabu-rootfs.ext4.img.zst.part00 nabu-rootfs.ext4.img.zst.part01 > nabu-rootfs.ext4.img.zst
zstd -t nabu-rootfs.ext4.img.zst
zstd -d nabu-rootfs.ext4.img.zst
```

需要为分卷、合并压缩包和解压镜像预留空间。压缩文件大小不是设备所需分区大小。
`zstd -t` 检查压缩流完整性，不替代可信的发布校验值。
此次 release 未附 `SHA256SUMS`；本地 `scripts/build-image.sh` 会生成该文件，
使用这类产物时应在目录中运行 `sha256sum -c SHA256SUMS`。不要混合不同版本的 ESP 和 rootfs。

## 刷写到现有分区

进入已支持该布局的 fastboot 环境，确认设备和分区容量后：

```sh
fastboot devices
fastboot getvar partition-size:esp
fastboot getvar partition-size:linux
fastboot flash linux nabu-rootfs.ext4.img
fastboot flash esp esp.img
fastboot reboot
```

**这里是 `fastboot flash esp esp.img`，不是 `fastboot flash boot esp.img`。**
`v0.1.0-alpha` 初始 release 说明中的 `boot` 是笔误；`boot` 是固件/Android 启动链使用的
分区，ESP 镜像不能写到那里。以上指令仅适用于确认具有 `linux`、`esp` 分区的设备。
如果 fastboot 无法查询或访问相应分区，先确认设备模式与布局，不要改猜其他分区名。

当前 rootfs 会用 `x-systemd.growfs` 扩展 ext4 到已有 `linux` 分区大小，不修改 GPT，
也不能把过小的分区变大。此流程将 ESP 的回退入口切换为 systemd-boot，不再使用 rEFInd。

另有可选的 tmpfs root + Btrfs 镜像，构建、安装和更新方法见[存储说明](storage.md)。
本页的 release 安装步骤继续使用传统 ext4 版本。

## 首次启动

1. systemd-boot 显示 NixOS 和 Android 入口；初始镜像只有一个 NixOS generation。
2. 进入 Noctalia 登录界面，再登录 niri。默认用户为 `nabu`，初始密码为 `nabu`。
3. 首次启动注册 Nix store 数据库，日常更新之后使用 `nixos-rebuild`。
4. 修改密码，并确认网络和日志可用：

```sh
passwd
systemctl --failed
findmnt /
findmnt /boot/efi
bootctl list
cat /proc/cmdline
```

当前配置同时开启 TTY 自动登录和 SSH 密码认证。部署为个人长期使用系统时，应在配置中
调整自动登录、SSH 访问和用户设置；单独修改密码不会关闭 TTY 自动登录。

屏幕菜单、登录界面和桌面的横屏分别配置，见[桌面说明](desktop.md)。相机仍不可用，
电源键被刻意忽略；低功耗休眠已可进入 s2idle，但锁屏不代表已进入低功耗状态。

## 从旧 UKI/rEFInd 安装迁移

直接刷 rootfs 是重装，会覆盖原 Linux 数据。如果需要保留现有 NixOS，请先备份 ESP、
记录可用启动入口与当前系统配置，再在设备上构建和部署本版本：

```sh
sudo nixos-rebuild boot --flake .#nabu
```

重启前检查 `bootctl list`、ESP 的 systemd-boot 入口和 Android 文件。旧 UKI、旧 rEFInd
配置可能仍留在 ESP，不能假定新安装器会删除这些非其管理的文件。先完成新系统启动和
回滚验证，再按引用关系清理。交叉镜像迁移到原生 rebuild 的成本见[构建说明](building.md)。

## 验证与报告

发布前与新设备测试时，记录：菜单是否可操作、桌面是否可登录、一次更新后的 generation
是否出现、能否选择保留的旧代，以及 Android 入口是否可用。冷启动、热重启和重复启动
应分别记录；一次成功不等于偶发启动问题已经解决。

失败时按[日志排查](boot-logging.md)采集资料。只有黑屏或重启现象不足以断言是 DTB、
签名、显示驱动或 rootfs 的某一项故障。
