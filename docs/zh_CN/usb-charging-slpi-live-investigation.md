**电脑 USB 充电与 SLPI handover 日志：实机调查**

2026-10-24，在运行 Linux 7.2.6、已应用 `e2fe1e2` 充电修复的 nabu 上采集。用户确认快充充电器可以正常充电；本次依次测试未接电源、扩展坞 USB-C、电脑前面板 USB-C、再次连接扩展坞。下列时间为设备本地时间 UTC+8；括号中的时间为采样程序的 `CLOCK_MONOTONIC`，可与内核日志对应，不能直接与包含休眠时长的 `/proc/uptime` 混用。

本次确认了三件事：

- 捕获到的桌面“停充”对应电池净电流转负。期间 SMB5 保持有效输入和 Charging，UPower 根据负电流显示 discharging。
- 前面板端口宣告 Type-C 3A，但 SMB5 仅配置并实际限制在 500mA。现有驱动缺少 Type-C 电流协调，而且仅修改电流数值不能解除当前 SDP 模式下的限制。
- SLPI 的重复 handover 来自当前主线 SMP2P 清零边沿历史的回归。实机 trace 与源码路径一致，不能据这些日志判定传感器固件反复崩溃。

**1. 扩展坞上的图标切换发生在哪里**

第一次接扩展坞在 `1908s`，APSD 识别为 CDP，Type-C 宣告 1.5A。SMB5 配置 `0x1370=0x1e`，即 1.5A，但 AICL 有效限流通常约 0.65–0.9A。稳定连接的 `1920–2247s` 窗口内，校正标度后的输入电流平均约 0.708A，输入电压平均约 4.622V；电池净电流范围约 -362 到 +500mA，随负载变化。

第二次接回扩展坞后，用户明确在图标变为未充电时报告“出现了”。这次同步记录了 UPower：

| 设备时间 | 电池电流 | 内核 battery/charger status | UPower |
| --- | ---: | --- | --- |
| 03:03:15.961（2447.541s） | -20,996µA | Charging / Charging | 03:03:15.960 切到 discharging |
| 03:03:22.966（2454.546s） | -17,089µA | Charging / Charging | 03:03:22.538 charging，22.639 又 discharging |
| 03:03:25.967（2457.547s） | +28,808µA | Charging / Charging | 03:03:25.818 恢复 charging |

这些是相近时刻的独立读取，不是一次原子快照。该窗口的寄存器一直为：`0x1006=0x03`（FULLON_CHARGE）、`0x110b=0x95`（USB 输入路径有效）、`0x1340=0`（软件未 suspend）、`0x1310=0x10`（USB 插入）。TCPM 在插入后的协商回退完成后没有对应的拔插或 VBUS off。周期 1 秒采样不能排除所有亚秒暂态，但已经能解释这次用户看到的图标变化。

采样结束前 03:06:49（约 2660s）确实记录到 Type-C 和充电器同时离线；用户确认那次是手动拔线，不计作自动断充。

[UPower v1.91.4 的 battery 读取函数](https://gitlab.freedesktop.org/upower/upower/-/blob/v1.91.4/src/linux/up-device-supply-battery.c) 先读内核 status；只要未满电且 `current_now < 0`，就覆盖为 DISCHARGING。这是该版本明确的处理逻辑。内核 Charging 表示充电硬件所处阶段，不能保证输入功率扣除平板负载后仍有电流充入电池。

第二次插入的 APSD 原始结果变为 `0x1308=0x10`（FLOAT），当前驱动将它归为 DCP；并不是第二次已准确识别为专用充电器。两次均配置 1.5A，第二次有效限流为 750mA，校正后的输入约 4.60V、0.73A，约 3.36W。这种功率水平下亮屏负载使电池电流在零附近波动，与实测一致。

输入电压降低并伴随 AICL 限流，说明输入路径存在供电裕量限制。数据尚不能区分扩展坞输出能力、线材/连接器/板内压降的各自贡献，不能直接断言扩展坞或线材损坏。没有为消除图标切换而禁用 AICL、降低保护阈值或强制保持 Charging。

**2. 前面板 USB-C：3A 授权与 500mA 实际限制脱节**

在 `2258s` 接入电脑前面板自带 USB-C，得到：

| 观测 | 结果 |
| --- | --- |
| Type-C | sink / device，`power_operation_mode=3.0A` |
| TCPM power supply | online=1，USB_TYPE=C，5V / 3A；没有 PD 合约 |
| APSD | `0x1307=0x01`、`0x1308=0x01`，SDP |
| 软件 ICL 配置 | `0x1370=0x0a`，500mA |
| 有效 ICL | `0x1108=0x0a`，500mA |
| 模式 | `0x1365=0xa5`，APSD 后 override 位未置位；`0x1366=0x03` |
| 实际输入 ADC | 校正后约 4.829V / 0.481A，约 2.32W |
| 电池电流（2265–2322s） | 平均 -186mA，全窗口为负值 |

源码中 `smb_status_change_work()` 只按 APSD 的 SDP/CDP/DCP 选择电流；SDP 固定为 500mA。`qcom_pmic_typec` 没有提供向充电器传递电流的 `set_current_limit` 回调，`qcom_smbx` 也没有消费 TCPM power supply 的电流变化。TCPM 的 3A 记录因此没有进入 SMB5 的限流决策。

做过一次 30 秒的可恢复对照：确认端口仍在线且宣告 3A 后，仅通过现有 charger `current_max` 属性将目标设为 1A，随后自动恢复 500mA。采样确认 `0x1370` 变为 `0x14`，但 `0x1108` 仍为 `0x0a`，输入仍约 0.48A。因此仅把 SDP 常量从 500mA 改大，不能证明硬件实际采用了新值。期间电池电流转正也不能归功于调流，因为输入没有增加，系统负载并未固定。

小米 [smb5-lib.c](https://github.com/MiCode/Xiaomi_Kernel_OpenSource/blob/nabu-r-oss/drivers/power/supply/qcom/smb5-lib.c) 的 `smblib_set_icl_current()` 同时配置电流与 ICL 模式：USB51 模式用于默认 USB 电流，获授权的高电流使用 HC 模式和 `ICL_OVERRIDE_AFTER_APSD`。现有 `smb_set_current_limit()` 只写数值寄存器。后续修复必须同时接入 Type-C/PD 电流授权及对应限流模式，并在拔出、角色变化、降额、PD reset 时恢复限制；不能无条件提高所有 SDP 的电流。

两个端口的 UDC 都显示 `not attached`，没有绑定 USB gadget。这表示 USB 数据设备没有枚举；普通默认电流的 SDP 还需考虑枚举约束。但本次前面板明确宣告了 Type-C 3A，不能把它的 500mA 限制简单归结为“没有 gadget”。

**3. SLPI 重复 handover 是 SMP2P 边沿历史丢失**

在没有接电源时启用 `qcom_smp2p` trace，捕获约 24 秒：131 条通知均为稳定的 `slave-kernel` 值 `0x6`，却持续报告变化位 `status=0x6`，约每 187.5ms 一次。窗口内没有 `smp2p_ssr_ack`；ready 和 handover IRQ 计数同步增加，fatal/watchdog 计数没有增加。典型记录：

```text
1859.774154: smp2p_notify_in: smp2p-slpi: slave-kernel: status:0x6 val:0x6
1859.961757: smp2p_notify_in: smp2p-slpi: slave-kernel: status:0x6 val:0x6
1860.149186: smp2p_notify_in: smp2p-slpi: slave-kernel: status:0x6 val:0x6
```

[7.2.6 的 qcom_smp2p_check_ssr()](https://github.com/gregkh/linux/blob/v7.2.6/drivers/soc/qcom/smp2p.c) 计算 `restart` 后，无论真假都把所有已绑定 inbound entry 的 `last_value` 清零。后续通知处理执行 `value ^ last_value`，稳定的 `0x6` 因而反复变成 ready/handover 的新上升沿。

这段循环来自 [SMP2P v2 支持补丁](https://lkml.iu.edu/hypermail/linux/kernel/2601.3/03403.html)，其说明要求在检测到 SSR 时清零，代码却缺少条件。仓库固定的 6.17 sm8150 fork 没有这段循环，不受同一回归影响。传感器活动使错误路径频繁执行；这份证据并不支持把原因归到之前的 FastRPC freezer 或 libssc 修复。也没有证据表明 SLPI handover 直接关闭 USB 充电。

修复为在 `restart == false` 时提前返回，真实 SSR 仍重置历史。补丁 [0013](../../pkgs/kernel/mainline-latest/patches/0013-soc-qcom-smp2p-reset-state-only-on-ssr.patch) 仅接入 mainline-latest。没有通过屏蔽 handover 日志掩盖错误 IRQ。

**4. ADC 标度错误会误导排查**

当前 `voltage_now` 报告约 74–77V、电流约 0.10–0.15A，不能直接用于功率计算：

- DT 已给 `ADC5_USB_IN_V_16` 设置 1:16 prescale，[ADC5 / VADC provider](https://github.com/gregkh/linux/blob/v7.2.6/drivers/iio/adc/qcom-vadc-common.c) 已将其还原为输入微伏，charger 又乘了 16。
- `ADC5_USB_IN_I` 返回电流检测端的微伏值；PM8150B buck 模式是 0.2V/A，需要乘 5 才是微安。换算依据同上小米 `smblib_get_prop_usb_current_now()`。

共用补丁 [0008](../../pkgs/kernel/patches/0008-power-supply-qcom-smbx-fix-smb5-adc-units.patch) 修正这两处上报，接入两个内核包。它不修改输入限流、充电电压或保护设置。本报告的输入 ADC 数值按此公式校正，未用外部仪表校准。原有 helper 在状态不是 Charging 时直接返回零的行为仍存在，因此其零电压不能单独证明 VBUS 消失。

**验证与尚需完成的工作**

- SMP2P 回归测试从实际 7.2.6 源码提取 SSR helper 编译运行：原版在“普通通知保留 last_value”断言失败，应用补丁后通过；同时验证真实 SSR 两种极性、ack 后不重复重放、未绑定 entry、未协商 SSR 支持。
- `nix build .#checks.x86_64-linux.smp2p-ssr --no-link` 通过；`nix flake check --no-build --all-systems` 通过。ADC 补丁在两个源码版本上零 fuzz 应用成功；临时 C harness 提取实际 getter，验证 5V、500mA、SMB2 保持原行为及 IIO 错误传播，原版的 5V 断言失败，修复后的两个版本均通过。
- 补丁需要经 CI 完整构建并安装后复测。实机目前运行的仍是旧内核，采样不能当作新补丁已上板验证。
- USB 电流授权与模式联动尚未实现；这次提交的 SMP2P 和 ADC 补丁不会自动解决电脑端口输入功率不足。后续实现需覆盖 Type-C 1.5A/3A、默认 SDP、CDP/DCP、插拔、source 角色、PD 电流变化，以及 AICL 保持有效等场景。
- 扩展坞输入路径还需用相同线材直连、换线及固定负载对照，才能进一步定位约 4.6V / 0.75A 限制来自哪里。

原始采样、power-supply uevent、TCPM 日志、UPower 事件与 SMP2P trace 保存于调查工作站 `/tmp/nabu-usb-audit/` 和设备 `/tmp/nabu-usb-live/`，未将大量原始日志纳入 git。临时限流对照已恢复，未重启、替换内核或写入 PMIC 调试寄存器。
