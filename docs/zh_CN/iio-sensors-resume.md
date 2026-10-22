# 唤醒后 SSC / iio-sensor-proxy 故障修复

2026-10-23。依据用户提供的 `dmesg.log` 与 `iio-sensor.log`，以及锁定的
libssc 0.4.4、iio-sensor-proxy 3.9 和 Linux 7.2.6 源码。原始日志留在工作区，
不纳入提交（其中含设备、网络和用户环境信息）。

后续 SSH 实机调查已将首次 fatal 收敛到 **freezer 打断 FastRPC 后重发请求**，
两个内核新增共享修复，尚待 CI 编译及修复后上机验收。
证据、补丁边界和验收步骤见 [SLPI freezer 调查](slpi-freezer-fatal.md)。

## 日志能确定什么

- dmesg 的 82.884 s 开始 s2idle；83.895 s PDM 报 `sensor_process` 的
  `frpc_dsp` 异常，83.912 s SLPI fatal，84.119 s remoteproc 恢复。FastRPC
  设备和三个 context bank 随即重新注册。
- 124.154 s 再次发生 `USER-PD DOG detects stalled initialization`，约为
  第一次重启后 40 秒。这与新 DSP 没有可用文件服务的情形相符，但没有 hexagonrpcd
  日志，不能把该推断写成已经证明的固件 watchdog 根因。
- proxy journal 的两次 SIGSEGV 都在 `Stopping IIO Sensor Proxy service` 之后，
  栈均为 `ssc_sensor_accelerometer_close_sync → sensor_close_ready → g_log → strlen`。
  能确定的是关闭传感器的错误路径崩溃，不能仅凭这份跨多个 boot 的 journal 宣称
  proxy 在 resume 回调中自行崩溃。两份日志也不能逐条跨时钟直接对齐。

## 已确定并修复的用户态错误

libssc 的 `sensor_close_ready()` 原来执行：

```c
g_task_return_error (task, error);
g_clear_object (&task);
g_debug ("Sensor disable request failed: %s", error->message);
```

`g_task_return_error()` 转移 GError 的所有权，还可能在返回前就执行完成回调。
完成回调可以取走并释放错误，因此最后一行是 use-after-free。`sensor_open_ready()`
有相同问题。补丁将两处日志移到所有权转移之前，不改变向调用方返回的错误。
[GLib 的明确契约](https://docs.gtk.org/gio/method.Task.return_error.html)。

overlay 修补 `pkgs.libssc`，确保 ssccli 和 proxy 链接到同一个修复版本，而非仅把
一个修复后的动态库额外安装到 PATH。Nix 配置测试验证 proxy 的实际 buildInputs。

回归测试从 libssc 源码提取两个真实回调，以真实 GLib/GTask 执行可重入完成回调；
仅替换 SSC 传输。完成回调立即取走并释放错误，要求错误日志在此前已经完成。
未修改的 0.4.4 在此检查失败，打补丁后 open/close 的成功及错误路径通过。
open 的发送成功本身不完成 task，测试模拟后续 sensor report 完成它。
不需要 DSP、ARM64 编译或复现一次真实崩溃来确认这个修复。

## 设备重建后的连接生命周期

kernel 的 `fastrpc_rpmsg_remove()` 使旧 channel 的 `rpdev` 失效，随后注销 misc
设备。重新 probe 创建的是新 channel；旧 fd 无法因为路径名相同而自动连到新 DSP。
原配置只有 Restart=no 和服务之间的依赖，没有与实际设备的生命周期关联。

本次配置：

1. 给 fastrpc-sdsp 加 `systemd` udev tag。
2. hexagonrpcd `BindsTo` / `After` 对应的 `dev-fastrpc\x2dsdsp.device`。
   设备移除时停止旧 daemon；proxy 通过已有的 BindsTo/After 链先停止。
3. 当 `autoStart=true` 时，设备 add 的 `SYSTEMD_WANTS` 启动文件服务；文件服务
   再通过 Wants/Before 拉起启用的 proxy。lab 模式只绑定移除事件，不自动启动。
4. proxy 停止最长 10 秒，文件服务停止最长 5 秒，避免旧连接的关闭等待无限拖住
   重启。正常关闭无需等待满这些上限。保持 Restart=no，不引入无条件 attach 重试循环。

[systemd device 与 udev 激活语义](https://www.freedesktop.org/software/systemd/man/latest/systemd.device.html)。
这修正了可由源码确定的旧 fd 生命周期缺陷；**实际设备移除/重建时的 systemd 时序
及恢复采样仍需一次真机验收**。它没有修复首次 SLPI firmware fatal，也不代表
任意 DSP 崩溃或 PD-only 重启都能恢复：本配置针对日志里出现的完整 FastRPC 设备重建。

采用用户已在设备上验证的安装矩阵：
`ACCEL_MOUNT_MATRIX="-1,0,0;0,-1,0;0,0,1"`，与 `ssc-accel` 标签一起设置。
日志中的 firmware 全零矩阵会触发 identity fallback；板级 udev 矩阵明确提供正确
坐标方向。源码中的 SSC discover 还依赖实际 SSC new/close 成功，不能把所有“未发现”
都归因于矩阵。

## 本轮验证与部署

- libssc 0.4.4 补丁零 fuzz 应用；真实 GLib 回归测试旧版失败、新版通过。
- Nix 求值检查修复库的实际依赖、mount matrix、device 依赖和 lab 不自动启动。
- 本轮没有修改内核补丁，也没有本地全量构建内核。仅回归测试的 C 程序在宿主机编译。
- 用户此前已确认传感器内核功能正常；本轮修复部署后，保持传感器三个启用选项，
  更新用户态 generation（包括新 libssc、重新链接的 proxy 及 udev/unit 配置）。
  只替换内核或只安装库不能应用此修复。
- 正常重启一次可确保新 udev 属性及 device unit 生效；systemd 不会因为给一个已经
  active 的 device 补加 SYSTEMD_WANTS 就立即启动服务。随后验收一次 suspend/resume：
  proxy 不再在关闭时 SIGSEGV，若 DSP 仍重启，新文件服务及 proxy 应恢复采样。
  不需要为已经确认的 GError bug 额外收集 core。

## 其他内核问题 TODO（本轮不扩展排查或修改）

| 优先级 | 日志证据 | 可能原因 / 已知边界 | 状态 |
| --- | --- | --- | --- |
| 高 | resume 后 `frpc_dsp` fatal，随后 PD 初始化 watchdog | 后续 freezer-only 测试复现同 PC fatal，并捕获 FastRPC 返回 -ERESTARTSYS 后重新进入；源码会发送第二次请求。后续 watchdog 与旧文件服务生命周期仍属另一层问题 | 已补 freezer 等待修复；待新内核上机验收，见专项报告 |
| 中 | SLPI 从启动开始反复 `Handover signaled, but it already happened`，部分间隔约 187 ms | q6v5 源码在 `handover_issued=true` 再收到 handover IRQ 时打印；重复通知源可能是固件或 SMP2P/中断信号。不是重新执行了 handover 资源释放 | TODO；不能简单屏蔽消息当作修复 |
| 中 | UFS 约 10 s 就绪，根 Btrfs 15 s 挂载，19.8 s 进入 stage 2，33 s 大批硬件 probe，54.5 s SLIM master capability | 启动耗时分散在存储、initrd、用户态模块加载和 DSP/音频 readiness；dmesg 不是 systemd critical chain，无法把总启动慢归咎于一条 WARN | TODO |
| 中 | 20.7 s cpufreq/USB/DSI deferred probe；33 s 已出现 CPU energy model、backlight 等初始化 | interconnect、Type-C connector、backlight 等供应者较晚出现；至少部分 deferred probe 是暂态，而非永久缺驱动 | TODO |
| 中 | SLIM QMI wait timeout；四个 CS35L41 在 54–55 s POST_PMD 返回 -110；随后出现无 backend DAI 提示 | DSP/SLIM 初始化时序、放大器状态切换或 UCM 路由尚未就绪；不能只凭这些日志认为扬声器硬件坏了 | TODO |
| 低 | `nvt_esd_check_wq` 未设 WQ_PERCPU/WQ_UNBOUND，引发 WARN | 旧触控驱动的 workqueue flags 不符合新内核 API 要求；内核明确回退为 WQ_PERCPU。触控固件首轮 reset-state 失败后也有 Update firmware success | 原因明确的兼容性 TODO，不是 sensor crash 栈 |
| 低 | `ufs_rpmb0` 加入未注册的 `ufs_rpmb` bus；ICE probe -95 | RPMB 总线初始化顺序及 ICE 能力/固件接口不支持的候选；普通 UFS 分区随后正常枚举和挂载 | TODO；不能等同根文件系统故障 |
| 低 | ramoops header ECC 错误、PSCI PC mode -3 | 旧/未初始化持久内存记录或布局不一致；固件拒绝可选 PSCI 模式。不能作为本轮 Linux panic 的证据 | TODO |
| 低 | Bluetooth reassembly -84；ath10k invalid frequency / DFS 提示 | 串口传输/固件事件和 host 解码、监管域处理的候选；已有独立蓝牙调查未改动 | TODO |
