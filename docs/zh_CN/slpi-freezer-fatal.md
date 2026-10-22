# SLPI 首次唤醒 fatal：freezer 与 FastRPC 重发

2026-10-23，SSH 连接用户授权的 nabu 真机，Linux 7.2.6。
本轮没有全量构建、替换内核或重启整机；进行过冻结测试和 SLPI 单独重启。
调查结束恢复 `pm_test=none`，移除本轮创建的 tracing instance / kprobes，
hexagonrpcd 与 iio-sensor-proxy 均恢复 active。保留设备上原有 GPU tracing 配置。
随后 D-Bus 确认 `HasAccelerometer=true`，但方向属性为 `undefined`。
最后尝试 `timeout 8 monitor-sensor --accel` 时 SSH 失联，新连接报告
`No route to host`；未获得采样结果，也未能确认断线原因。上述恢复状态是断线前
已读取的结果，不代表已经验证动态采样或证明设备此后持续正常。

## 已取得的实机证据

设备尚未部署 `3d253da` 的完整用户态配置：hexagonrpcd unit 没有 device BindsTo，
没有新增的停止超时。不能把此次服务恢复行为当作该提交的验收结果。

`echo freezer > /sys/power/pm_test` 后写 `mem` 到 `/sys/power/state`，仅执行进程冻结
测试，内核约五秒后自动恢复，未进入设备 suspend。此测试重复复现：

```text
PDM: service 'sensor_process' crash:
  'EX:sensor_process:0x1:frpc_dsp:0x6d:PC=0xb206aabc'
qcom_q6v5_pas 2400000.remoteproc: fatal error received:
  err_qdi.c:964:EX:sensor_process:0x1:frpc_dsp:0x6d:PC=0xb206aabc
```

PC 与原始真实休眠日志一致。线程尾号由 0x6e 变为 0x6d，不影响同 PC 的事实。
因此 **设备掉电、SMMU 的设备 suspend/resume 回调不是复现此故障的必要条件**；
无需继续凭猜测修改 IOVA alias、reserved-memory 或 dma-coherent。

在独立 trace instance 中，只启用 `fastrpc_internal_invoke` entry/return kprobe，
捕获到同一 listener 线程：

```text
hexagonrpcd-33797  2278.737417  nabu_rpc_return: ret=-512
hexagonrpcd-33797  2283.870882  nabu_rpc_enter: fastrpc_internal_invoke
```

`-512` 即 `-ERESTARTSYS`。同一轮内核日志在解冻处再次记录上述 fatal。
ftrace 默认时钟和 journal/kernel 时间戳不直接混排；这里只使用各自的顺序。
未解析闭源 DSP 的 PC 指令，因而“重复请求触发固件此处异常”仍属于由实验和
源码共同支持的因果推断，修复后的同条件回归才是最终验证。

一次早期 function tracer 设置因目标函数被编译器内联而失败，短暂启用了过宽的
跟踪，随后停用；该轮不作为时序证据。上述记录来自重新启动 SLPI、恢复服务后，
仅使用两个 kprobe 的独立一轮。

## 源码链路

1. `freeze_task()` 对没有 `TASK_FREEZABLE` 的普通用户进程使用 synthetic signal
   唤醒。FastRPC 原来的 `wait_for_completion_interruptible()` 返回 -ERESTARTSYS。
2. `fastrpc_internal_invoke()` 留住原 context，但既没有恢复旧请求的查找路径，
   也没有在此处进入 freezer。ioctl 返回后进入冻结，解冻时 syscall 被重启。
3. 重新进入 invoke 无条件 `fastrpc_context_alloc → fastrpc_get_args → rpmsg_send`。
   原 DSP 请求仍在等待，新请求已经再次发送。
4. hexagonrpcd 的 `adsp_listener_next2()` 同时返回上一笔 reverse RPC 结果并等待
   下一笔请求；不能把它视为可以任意重复的只读查询。

对应源码：[freezer.c](https://github.com/torvalds/linux/blob/v6.17/kernel/freezer.c)、
[completion.c](https://github.com/torvalds/linux/blob/v6.17/kernel/sched/completion.c)、
[hexagonrpc 0.5.0 listener](https://github.com/linux-msm/hexagonrpc/blob/v0.5.0/hexagonrpcd/listener.c)。
两套内核的本地 FastRPC alias 补丁没有改变原来的 interruptible wait / syscall 重发逻辑。

## 两个内核共用的修复

`pkgs/kernel/patches/0006-misc-fastrpc-preserve-invoke-across-freezer.patch`
在各自 alias/PDR 补丁后应用：

- 用户 RPC 使用 `wait_for_completion_state(..., TASK_INTERRUPTIBLE | TASK_FREEZABLE)`，
  freezer 可以直接冻结等待中的线程，解冻继续同一个 completion。
- 冻结请求可能早于设置睡眠状态；若等待仍返回 -ERESTARTSYS，调用
  `try_to_freeze()`，只有实际进入过 freezer 才继续等待原 completion。
- 不重新分配 context、不重复发送 RPC，不改变 DMA 映射或共享内存生命周期。
- 普通信号仍允许返回 -ERESTARTSYS；kernel RPC 的十秒超时保持原行为。
  这不是“所有信号中断的 RPC 都能恢复”的通用修复，也不把等待改成不可杀死。

上游正在评审更广泛的
[signal-interrupted invoke v3](https://patchew.org/linux/20261002-anandu-fastrpc-interrupted-invoke-v3-v3-1-31e90439d2ba@oss.qualcomm.com/)，
覆盖 interrupted context 保存和恢复。此次不直接回移它：待评审补丁涉及 context
所有权及 SSR 清理，且正文宣称的 `sent` 判定和恢复参数更新未完整出现在实际 diff。
本项目先独立修复已复现的 system freezer 路径，普通信号重试留作后续独立审计。

## 验证和部署边界

- 共享补丁在两个已应用 alias 的源码上零 fuzz 应用。
- 宿主机测试提取补丁中真实 wait helper，覆盖完成、连续冻结竞争、普通信号、
  解冻后仍有信号；检查全过程使用同一个 completion。它不是内核 scheduler 测试。
- `nix flake check --offline --no-build --all-systems --no-update-lock-file` 通过；
  `checks.x86_64-linux.fastrpc-freezer` 在 Nix sandbox 中构建并运行通过。
- CI 仍需编译两个内核；本轮没有在实机加载修改后的驱动，不能声称 fatal 已消失。
- 部署新内核及 `3d253da` 用户态修复后，先重复 freezer-only 测试，再测正常 s2idle。
  两者应无新的 SLPI fatal，服务继续工作且 `monitor-sensor` 可收到方向变化。
  每轮观察至少 45 秒，以覆盖曾出现的约 40 秒 PD 初始化 watchdog。

freezer-only 验收命令（root；不是正常睡眠策略）：

```sh
(
  trap 'echo none > /sys/power/pm_test' EXIT
  echo freezer > /sys/power/pm_test
  echo mem > /sys/power/state
)
```

本轮设备的 EFI RTC 没有 wakealarm，因此未远程触发无法保证自动唤醒的正常休眠。
旧服务在 DSP 重建后曾出现 `Unsupported handle: 4294967295` 并以 0 退出，
调查结束通过停止服务、SLPI stop/start、重新启动服务恢复；没有用无限重试掩盖它。
