[English](../device-status.md) | **简体中文**

# 设备支持状态

[返回项目首页](../../README_zh_CN.md)

基线：`v0.1.0-alpha` / `c26c2c1`，2026-09-07。
“已验证”指维护者在现有 nabu 设备上报告的结果，不代表所有硬件批次、固件版本和
使用场景都已覆盖。配置中启用某项功能也不等于完成了该项硬件验证。

## 已验证的发布路径

- systemd-boot 可以启动当前 NixOS 镜像，提供原生 generation 菜单。
- niri + Noctalia 桌面镜像已发布并在真机可用。
- systemd-boot 菜单横屏已经验证；登录界面和桌面配置了对应的横屏方向。
- 数位笔在配置中绑定内屏 `DSI-1`，随输出旋转；详细设置见[桌面说明](desktop.md)。

## 已知问题

| 项目 | 当前状态 | 后续调查 |
| --- | --- | --- |
| 相机 | 维护者确认不可用 | 检查内核驱动、设备树、固件及用户态相机栈 |
| 低功耗休眠 | 维护者确认可进入 s2idle，蓝牙 UART 秒醒已修复并实机验证 | 电源键、自动挂起、恢复显示与待机功耗 |
| 启动可靠性 | 偶尔启动失败，原因未定 | 分别记录冷启动/热重启、失败阶段、日志和硬件/固件版本 |
| 电源键 | 当前刻意忽略 | 配合显示与休眠验证重新设计按键行为 |
| rootfs 体积 | 当前桌面镜像较大 | 测量闭包、拆分变体、减少非必要依赖 |

当前 `services.logind.settings.Login.HandlePowerKey = "ignore"` 与 niri 的
`disable-power-key-handling` 共同避免现有挂起/熄屏问题。它们是临时行为约束，
不是完成的电源管理方案。锁屏、屏幕关闭、低功耗休眠、恢复显示和解锁应分别测试。

跨重启随机 Wi-Fi MAC 的问题已解决：通用 board-2.bin 不含 MAC，内核补丁
（`pkgs/kernel/patches/0002-nabu-ath10k-mac-address.patch`）从 SMBIOS 主板序列号派生
稳定的本地管理地址，必要时可用 `ath10k_core.macaddr=` 模块参数覆盖，方案源自
[TwinbornPlate75/linux-nabu](https://github.com/TwinbornPlate75/linux-nabu)。

挂起后立即唤醒（suspend-to-idle 秒醒）的问题已解决，维护者已在真机确认可以正常进入挂起。
nabu 的 WCN3991 蓝牙 UART（`uart13` / `c8c000.serial`，别名 `hsuart0`）是常开 serdev，
系统挂起时 runtime PM 引用计数不会归零，`qcom_geni_serial_runtime_suspend()` 从不执行，
`geni_se_resources_off()` 被跳过，sleep pinctrl（`qup_uart13_sleep`：GPIO 输入 +
`gpio46` 上拉）从未生效，QUP13 引脚停在 `bias-disable` 的默认态；蓝牙控制器的收发活动
加上 TLMM 对边沿型唤醒中断的锁存（掩蔽期间仍会锁存状态位），使专用唤醒中断在
`dpm_suspend_noirq` 被使能的瞬间就触发，于是刚进入 suspend-to-idle 便立即恢复。
修复回移自上游提交 `d0cd9c8d0fd5`（"serial: qcom-geni: add force suspend/resume to
system sleep callbacks"，作者 **Praveen Talari** `<praveen.talari@oss.qualcomm.com>`，
经 tty-next 合入 v6.18-rc4，6.17.y 中没有该修复），落在
`pkgs/kernel/patches/0005-qcom-geni-serial-force-suspend-system-sleep.patch`；补丁保留了
上游的作者、提交信息与 sign-off 链。蓝牙工作与唤醒能力均保持不变，仍待补充的是电源键、
自动挂起、恢复显示与待机功耗的记录。

## 已有配置，但需要更完整的验证记录

代码包含 UFS、Wi-Fi、图形、面板/背光、触摸、数位笔、音频及高通服务支持。
例如扬声器目前仍依赖特定 ALSA 路由设置；服务启用不能证明所有音频输入输出均正常。
Bluetooth、传感器、外接设备以及不同存储批次等项目，应按具体设备和版本补充结果，
不在缺少报告时自动列为“正常”或“损坏”。

Android 菜单和 Reboot2Android 程序由配置部署；迁移固件、重新刷写或发布新镜像时，
仍需将 Android 返回路径纳入回归测试。

## 如何提供有用的报告

请包含：

1. 镜像 tag/提交、原生或交叉构建、是否修改配置。
2. Aloha/DBKP 版本、Secure Boot 状态、设备内存与存储规格（已知时提供芯片批次）。
3. 重现步骤、期望与实际行为；冷启动和热重启分别统计成功/失败次数。
4. 失败停在菜单、EFI stub、内核日志、登录界面还是桌面；SSH 是否仍能连接。
5. `/proc/cmdline`、`systemctl --failed` 和相关 journal，方法见[日志说明](boot-logging.md)。

公开日志前检查其中的用户名、地址、网络名称等信息。一次恢复启动、一次桌面可用
或一次 suspend 命令返回，都不足以关闭间歇性问题。
