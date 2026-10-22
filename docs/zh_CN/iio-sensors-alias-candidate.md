# nabu SDSP：context-bank alias 实验版本

> 唤醒后的 libssc 崩溃修复、设备重建恢复及内核 TODO 见
> [后续报告](iio-sensors-resume.md)。

2026-10-22。接续 `2f10562` 的真机结果：Linux 7.2.6 下四个 remoteproc
均为 running，进入 sensors-lab 正常；手动启动 hexagonrpcd 后立即卡死，约十秒重启。
本次直接实现可测试的替代方案，不把它描述成已经验证的根因修复。

后续真机反馈：用户报告 mainline-latest 的传感器功能全部正常工作。
sm8150-fork 的 CI 在 postConfigure 校验失败，尚未进入 C 编译：日志中
`QCOM_APR=y` 会 select 隐藏的 `QCOM_PDR_HELPERS=y`，原检查却只接受 `m`。
现仅对该依赖接受 `m` 或 `y`，其余 fork 配置要求保持严格；局部模块构建脚本同步修正。
这项修复不改变已验证的 mainline 驱动及 DT，fork 仍待重新 CI 编译和上机验证。

## 实现选择

撤换原先的 sensors-PD remote-heap 一行补丁。nabu 没有定义 FastRPC 物理
remote-heap pool；给普通 AP DMA 内存换一个分配设备，不能保证 SLPI 可达。
但是也没有足够依据从物理地址空间中随意划出一个新的固件共享区。
本版采用 Kumar 的另一条路线：**消息与数据均经已有 context bank，保留低 IOVA，
再将带 session selector 的高 IOVA 映射到相同物理页。** 不同时叠加物理 heap 策略。

参考固定版本：
[Kumar FastRPC](https://github.com/Kumar-Jy/linux/blob/739161a890128f23bd1aa679d8754a9ea299269e/drivers/misc/fastrpc.c)、
[nabu sensors DT](https://github.com/Kumar-Jy/linux/blob/739161a890128f23bd1aa679d8754a9ea299269e/arch/arm64/boot/dts/qcom/sm8150-xiaomi-nabu-sensors.dtsi)。

设备树补齐三个 SLPI compute context bank 的 `dma-coherent`，以及
`qcom,protection-domain = "tms/servreg", "msm/slpi/root_pd"`；同时补充绑定定义。
coherency 是沿用可工作参考树的板级假设，**尚未经本项目独立硬件验证**，不是通用缓存修复。
不会把 `slpi_mem` 固件区改成 DMA pool，也不改其他 DSP 的 DT。

驱动行为仅以 `xiaomi,nabu` + SDSP 为条件启用：

- context-bank 的 streaming/coherent DMA mask 均设为 32 位。正常 DMA 分配保留
  在低 4 GiB；高位 alias 不参与 DMA allocator 分配。
- 发送给 DSP 的地址仍带 session selector。主线保留原来的 SoC SID 编码函数，
  fork 使用其原有的高 32 位编码；不撤回其他 SoC 的支持。
- DMA handle 单独保存。free、用户态 mmap 和 dma-buf 导出均使用原始 handle，
  不再从发送给 DSP 的地址反推 DMA handle。
- alias 检查 IOMMU DMA domain、页大小、DMA mask、低地址范围、溢出和 domain
  aperture。逐页解析原映射；遇到已占用的 alias 拒绝请求，不覆盖别人的页表。
  中途失败撤销本次已经建立的映射；释放时先撤销 alias，再释放低地址 DMA allocation。
- dma-buf 导入验证 DMA scatterlist 是连续的 IOVA 区间，对整个区间建立 alias；
  物理页可以不连续。修正导入失败时原有的重复 detach / 未正确 unmap 的清理路径。
- attach 前等待 PDR 公告的 root PD UP，最多 15 秒；超时返回错误。PD mapper
  两个 SLPI 域条目继续保留。FastRPC 在 NET/QRTR 可用时选择 PDR helpers，配置
  检查要求该功能内置或作为模块启用。remoteproc running 不作为 PD readiness 的替代；PDR 已 DOWN 时拒绝新的 invoke。
- 仅在 sensors attach 成功、PD 仍 UP 且通道未移除时发送 nabu 的 release RPC。
  PDR 等待失败后的 close 不会再向未就绪 DSP 发一次 release。通道移除唤醒等待者，
  释放 PDR 订阅后再释放 channel 对象。

## 路径覆盖与明确边界

| 路径 | 本版处理 |
| --- | --- |
| `INIT_ATTACH_SNS` 的 RPC 消息 | context-bank 分配 + alias；先等待 PD UP |
| listener 注册及普通 invoke 消息 | 相同消息分配路径 |
| `apps_mem_request_map64` / `ADSP_MMAP_ADD_PAGES` | 数据分配也建立 alias |
| `ALLOC_DMA_BUFF`、导出、mmap | 分配时 alias；DMA API 始终使用原始 handle |
| invoke 的 fd 参数、MEM_MAP 等 dma-buf 导入 | 检查连续低 IOVA，建立 alias；正常及错误出口撤销 |
| `ADSP_MMAP_REMOTE_HEAP_ADDR` | nabu 返回 `EOPNOTSUPP`，避免发送未经授权的物理地址 |
| secure dma-buf 导入 | nabu 返回 `EOPNOTSUPP`，不假设不存在的 VMID/内存授权 |
| 其他 SoC / ADSP / CDSP | 不启用 nabu alias 或 PDR gate |

“覆盖路径”不表示所有 FastRPC ABI 都强行成功。hexagonrpc 0.5.0 的 apps_mem
实现使用 ADD_PAGES；不支持的物理 heap/secure 操作明确失败。若将来固件确实要求这些
操作，需要另行取得真实 carveout/VMID ABI，不能将 IOVA 冒充物理地址交给 SCM。

本版也不宣称解决上游驱动全部并发/remoteproc 重启问题；尚需验证中断中的 DSP crash、
重新 attach 与 suspend/resume。alias 在 DMA domain 中额外建表属于板级兼容方案，
后续上游化需要与 IOMMU/FastRPC 维护者确认其分配与生命周期约定。

## 验证与部署

本地不全量构建内核。两份 C/Kconfig 补丁及 DT/binding 补丁按对应基线零 fuzz 应用；
两个 DTB 重新预处理、编译，并检查实际合并后的 PDR 属性和三个 coherent context bank。
`tests/test-fastrpc-alias.py` 从两份补丁提取实际 alias helper，用宿主 C 编译器运行
故障注入：页映射失败回滚、目标地址冲突、缺少源映射、范围/页对齐/aperture 拒绝、
非连续物理页、coherency 标志、重复清理。它不模拟真实 ARM SMMU，也不替代内核编译。
`checks.<system>.fastrpc-alias` 将此测试纳入 flake checks。

完整 ARM64 编译仍由 CI 完成。必须部署**配套 DTB、内核和模块**；只替换两个 `.ko`
不足以启用 PDR DT 属性和 context-bank 配置。局部模块脚本要求已有匹配的 PDR helpers
配置/Module.symvers；输入源码应为干净基线或本版补丁后的源码，不能保留旧 remote-heap 补丁。

保留可启动旧代。普通启动仍关闭 SLPI；sensors-lab 仍只提供手动服务，未开启自动重试、
自动 proxy 或开机采样。按[前一轮操作说明](iio-sensors-followup.md#4-可执行的验证顺序)
启动默认项、SLPI-only、lab，然后手动启动一次服务。预期结果是服务保持运行、SSC 能
读到随运动变化的数据。若 attach 返回超时/映射错误，保留完整日志，不循环重试。

附：上一轮文字推导中的 `setup_environment()` 并不发送 RPC，它只调用 `setenv()`；
真正后续 RPC 在 listener 注册中。内核 attach 本身有 `10 * HZ` 的 completion timeout，
所以约十秒后重启也不能单独证明 watchdog。此次没有以时间现象代替根因证据。
