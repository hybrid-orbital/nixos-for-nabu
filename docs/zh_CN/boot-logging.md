[English](../boot-logging.md) | **简体中文**

# 启动日志排查

[返回项目首页](../../README_zh_CN.md) · [设备状态](device-status.md)

当前 alpha 镜像已验证可以启动，但维护者仍报告偶发启动失败，原因尚未确定。
以下记录用于定位问题，不代表已经修复。

日志参数集中在 `nixos/boot.nix`；面板、背光及存储驱动的 initrd 加载顺序在
`nixos/hardware-nabu.nix`。当前保留启动日志，关闭 Plymouth 启动画面，
避免默认启用大量调试输出和强制提前接管屏幕。

## 能看到哪些阶段

- EFI stub：`efi=debug` 请求固件控制台输出加载阶段的调试信息，能否显示取决于 UEFI 实现。
- Linux 内核：控制台日志级别统一设为 7，启用时间戳和 4 MiB 日志缓冲区。
  已产生的 debug 消息仍保留在内核缓冲区，可通过 journal 查看，但不刷到屏幕。
- initrd：包含背光和面板驱动，由 udev 按设备需求加载；不强制提前加载或禁用
  fbcon 的延迟接管策略。systemd 显示启动状态，服务输出使用 NixOS 的默认日志通道。
- 正常系统：显示 systemd 启动状态，管理器日志级别为 info，由 journald 收集。
  登录界面启动后仍可通过 journal 查看日志。

小米平板 5 当前设备树没有提供 simple-framebuffer。Linux 接管后，屏幕必须等待
MSM DRM、面板和背光初始化，单靠日志参数无法保证从第一条内核指令起就有画面。
屏幕点亮前的消息会写入内核缓冲区，但过量日志仍可能覆盖旧记录。
要实时观察显示驱动初始化前的卡死，需要确认可用的硬件串口与 earlycon 配置；
这里不预设未知的 UART 地址，也不启用未经验证的 `earlycon=efifb`。

## 应用配置

在平板的仓库目录运行：

```sh
sudo nixos-rebuild boot --flake .#nabu
sudo reboot
```

这些修改需要重新生成 initrd 和引导参数，重启后生效。
`switch` 也能更新下次启动配置，但不能改变当前运行内核的启动参数。

## 查看和导出

```sh
cat /proc/cmdline
sudo journalctl --list-boots
sudo journalctl -b -k -o short-monotonic
sudo journalctl -b -o short-monotonic
sudo journalctl -b -1 -k -o short-monotonic
sudo journalctl -b -1 -o short-monotonic
sudo journalctl -b -o short-monotonic --no-pager > boot-current.log
sudo journalctl -b -1 -o short-monotonic --no-pager > boot-previous.log
```

`/proc/cmdline` 应只有一个 `loglevel=7`，不含 `quiet`、`splash`、`ignore_loglevel`、
`initcall_debug` 或 `fbcon=nodefer`。
查看 initrd 的切根过程和模块加载：

```sh
sudo journalctl -b -u initrd-switch-root.service -u systemd-modules-load.service
sudo journalctl -b -k --no-pager | grep -Ei 'fbcon|drm|novatek|ktz8866|ath10k'
```

journal 持久存储上限设为 256 MiB，正常写盘同步间隔为 30 秒。
在根文件系统可写并完成日志落盘之前发生的死机、突然断电，以及缓冲区已覆盖的消息，
不保证能通过 `journalctl -b -1` 找回。

## 出现企鹅和日志后灰屏

企鹅和 `[时间戳]` 消息表明 Linux framebuffer console 已经显示过内容，
故障应重点排查此后的显示驱动运行及切换过程；这不能证明系统整体已经死机。

首次增加详细日志时，还同时启用了 `fbcon=nodefer`、主动加载面板/背光驱动、
`initcall_debug` 及 systemd debug 日志到 kmsg。这些设置会改变初始化时序或增加
控制台输出负担。用户报告该改动后出现偶发灰屏，因此当前撤回这些设置，
保留时间戳、较大的缓冲区、启动状态与持久化 journal。当前发布已能在真机运行，但仍有偶发启动失败。尚不能确定是哪一项触发，
也不能据此认定灰屏或启动可靠性问题已经修复。

建议按以下顺序对照，每一步分别记录几次热重启和冷启动结果：

1. 应用当前配置，确认 `/proc/cmdline` 已更新；偶发问题不能凭一次成功启动排除。
2. 如仍灰屏，在 systemd-boot 菜单选中启动项，按 `e`，在参数末尾临时加上
   `systemd.unit=multi-user.target`，回车启动。它仅对这次启动生效，不启动图形登录。
   若文本启动稳定，应继续检查 greetd/niri 与 DRM 的切换；若也灰屏，则继续检查
   内核显示路径或更早的启动阶段。
3. 从启动菜单选择日志改动之前的 generation 对照。旧配置还启用了 Plymouth，
   因此旧版本稳定只能说明这组启动配置值得怀疑，不能直接锁定某一个参数。

灰屏时若 SSH 仍能连接，优先导出当前启动日志；Wi-Fi MAC 会变化，需确认当前 IP。
成功启动后查看 `journalctl --list-boots` 的时间，再选择故障启动的 boot ID，
不要假定 `-b -1` 一定是灰屏那次：很早的失败启动可能没有持久记录。

```sh
sudo journalctl -b -k --no-pager > kernel-current.log
sudo journalctl -b -u greetd.service --no-pager
sudo journalctl -b -k --no-pager | grep -Ei 'drm|msm|dsi|dpu|panel|gmu|adreno|firmware|timeout|lockup|stall'
```

如需更详细的内核初始化跟踪，可在启动菜单中仅对一次启动添加 `initcall_debug`，
保持 `loglevel=7`，再从 journal 导出消息。避免同时恢复全部 debug 和显示时序改动。

参考：[内核启动参数](https://docs.kernel.org/admin-guide/kernel-parameters.html)、
[fbcon 接管行为](https://docs.kernel.org/fb/fbcon.html)、
[systemd 261 启动参数说明](https://github.com/systemd/systemd/blob/v261/man/systemd.xml)。
