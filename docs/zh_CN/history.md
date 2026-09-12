[English](../history.md) | **简体中文**

# 项目沿革与致谢

[返回项目首页](../../README_zh_CN.md)

本项目建立在 [Mooling0602/nixos-for-nabu](https://github.com/Mooling0602/nixos-for-nabu)
的工作之上。原作者搭建了 nabu 的 NixOS 移植骨架，整理了内核、固件和设备软件包，
推进 rootfs 镜像及早期启动、显示适配，为后续真机可用系统提供了基础。
这些贡献与提交历史保留在本仓库中。

早期方案借鉴 Fedora for Nabu 的启动和硬件配置，使用 rEFInd 与 UKI 封装内核、
initrd、DTB 和命令行。它让 NixOS 具备了可构建、可交付并继续调试的起点。
后续分支逐步完成设备验证、桌面集成和启动方案重构。

当前由 hybrid-orbital 维护的分支选择 systemd-boot，利用 nixpkgs 原生外部 DTB 与
NixOS generation 支持，并发布 niri + Noctalia 镜像。目标从早期启动探索进一步转向
可维护的设备系统、桌面体验、配置变体和持续构建。技术上的取舍变化不否定早期方案
在当时的探索价值，也不代表原作者或其他上游为本分支当前发布提供支持承诺。

## 上游与资源

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

## 历史资料的使用

[`MEMORY.md`](../legacy/MEMORY.md) 保留早期移植和构建笔记，不代表当前状态。
旧 UKI 测试路径和 QEMU 脚本属于历史方案，不应作为现有 release 的安装步骤。
当前操作以[安装说明](installation.md)、[构建指南](building.md)和[设备使用](usage-on-device.md)为准。

配置和脚本的许可见 [LICENSE](../../LICENSE)。内核、固件、驱动与其他引入组件保留各自许可，
引用和打包时应保留其来源与许可信息。
