[English](../architecture.md) | **简体中文**

# 启动架构与 generation

[返回项目首页](../../README_zh_CN.md)

本文以 `v0.1.0-alpha` / `c26c2c1` 为基线。systemd-boot 是当前采用并经维护者
真机验证的方案；过去的 rEFInd + UKI 实现保留在 Git 历史中。

## 启动链

```text
Project Aloha UEFI
  └─ EFI/BOOT/BOOTAA64.EFI：systemd-boot
       ├─ NixOS：linux + initrd + devicetree + options
       │    └─ Linux EFI stub → initrd → 指定 generation 的 init → 系统与桌面
       └─ Android：EFI/Android/Reboot2Android.efi
```

[`nixos/boot.nix`](../../nixos/boot.nix) 使用 NixOS 原生配置：

```nix
boot.loader.systemd-boot.enable = true;
boot.loader.systemd-boot.installDeviceTree = true;
hardware.deviceTree.enable = true;
hardware.deviceTree.name = "qcom/sm8150-xiaomi-nabu.dtb";
boot.loader.efi.efiSysMountPoint = "/boot/efi";
boot.loader.efi.canTouchEfiVariables = false;
```

当前部署依靠可移动介质回退路径，不依赖固件 NVRAM 中的 BootOrder 注册。
Android 启动程序和 GopRotate 通过 `extraFiles` 部署，Android 菜单由 `extraEntries`
声明；这两组配置也用于首次 ESP 镜像构建。菜单旋转驱动来自先前 nabu 引导资源，
不代表仍由 rEFInd 启动。各阶段的横屏设置见[桌面说明](desktop.md#屏幕方向)。

## 为什么不需要 UKI

关键是向内核提供正确、配套的 DTB。systemd-boot 通过 Boot Loader Specification
的 `devicetree` 字段加载外部文件，将其交给 EFI-stub 内核。这个方案已经在本设备上
成功启动，因此没有必要继续把内核、initrd、DTB 和命令行封装成 UKI。
当前路径也不需要额外的 `dtb=` 参数。

早期调研发现所用 Aloha 源码的 nabu Linux DTB 资源是占位内容；这说明不能依赖
该固件自动提供适用设备树，并不说明它只能启动 UKI。不同固件构建可能不同，不应把
这个发现推广为所有 Aloha 固件的固定缺陷。

当前外部 DTB 启动路径以关闭 Secure Boot 的固件为前提；本项目没有提供 Secure Boot
签名和密钥管理方案。上游 systemd-boot 会在启用 Secure Boot 时跳过未验证的外部 DTB。
参见 [systemd-boot 源码](https://github.com/systemd/systemd/blob/main/src/boot/boot.c)
与[设备树加载实现](https://github.com/systemd/systemd/blob/main/src/boot/devicetree.c)。

## 每代绑定什么

在设备上执行 `nixos-rebuild boot` 或 `switch`，nixpkgs 安装器读取各代 bootspec，
生成对应启动条目并部署所需启动文件。条目中的 `init=` 指向具体 store 闭包，
不是 `/nix/var/nix/profiles/system/init` 这样的可变入口。

不同 generations 可以引用相同的内核、initrd 或 DTB。仅用户态改变且启动文件未变时，
不必在 ESP 重复保存完整启动镜像；内核或 initrd 等发生变化时，旧条目继续使用旧文件。
文件保留与清理由 nixpkgs 的 systemd-boot 安装器管理，仍需关注 ESP 可用空间。

回滚的范围是 NixOS 系统配置和包闭包，不包含 `/home`、数据库或其他可变数据，
也不是整个 UEFI 固件的回滚。可选的 tmpfs root + Btrfs 方案见[存储说明](storage.md)，
它保留选定状态，不自动创建数据快照。

## 首次镜像和日常更新的区别

[`nixos/images/esp.nix`](../../nixos/images/esp.nix) 的 `system.build.esp-image` 在普通构建环境中组装初始 FAT 镜像：

| 初始 ESP 路径 | 内容 |
| --- | --- |
| `EFI/BOOT/BOOTAA64.EFI` | systemd-boot 回退入口 |
| `EFI/systemd/systemd-bootaa64.efi` | systemd-boot 厂商路径 |
| `EFI/systemd/drivers/GopRotate_aa64.efi` | 菜单旋转驱动 |
| `EFI/Android/Reboot2Android.efi` | Android 启动程序 |
| `loader/entries/nixos-nabu.conf` | 初始 generation 1，绑定配套闭包 |
| `nixos/kernel`、`nixos/initrd`、`nixos/nabu.dtb` | 初始启动文件 |

这部分仍是项目自己的镜像打包逻辑，并没有在构建沙箱中运行完整设备端安装器。
日常 rebuild 使用 nixpkgs 安装器生成的名称和路径，不能假定它们一直叫
`nixos-nabu.conf` 或 `/nixos/kernel`。初始镜像的文件也不能假定会全部被该安装器
自动清理；确认不再有启动条目引用后才能手动处理。

[`nixos/images/rootfs.nix`](../../nixos/images/rootfs.nix) 将同一个系统闭包放进选定的
ext4 或 Btrfs 布局，创建初始 profile 链接，并在首次启动注册 Nix store 数据库。
两个镜像入口都在 `config.system.build` 下，flake 只组合配置和导出产物。
ESP 和 rootfs 必须来自同一套配置求值，不能随意混用两个发布或原生/交叉构建的产物。

## 代码入口

- [`nixos/boot.nix`](../../nixos/boot.nix)：引导器、DTB、Android、旋转驱动和启动日志。
- [`nixos/hardware-nabu.nix`](../../nixos/hardware-nabu.nix)：内核、驱动、固件、分区和设备服务。
- [`nixos/configuration.nix`](../../nixos/configuration.nix)：系统基础配置及模块组合。
- [`nixos/niri.nix`](../../nixos/niri.nix)、[`nixos/niri.kdl`](../../nixos/niri.kdl)：当前桌面。
- [`flake.nix`](../../flake.nix)、[`scripts/build-image.sh`](../../scripts/build-image.sh)：构建与导出。
