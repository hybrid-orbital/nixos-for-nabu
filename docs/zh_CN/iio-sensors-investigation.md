# nabu 传感器调查与两个内核的最小补丁方案

调查日期：2026-10-21。基线是 `v6.17.0-sm8150`，以及 `flake.lock` 中
`nixpkgs/20b1ddd1aa5ace70c9468305030aa4f9ef79671b` 的 `linux_latest = 7.2.6`。
Kumar-Jy 参考树固定到 `739161a890128f23bd1aa679d8754a9ea299269e`，避免跟随分支变化。

**结论：缺的是 SLPI/SSC 的完整访问链路，不能通过多开几个 IIO 芯片驱动解决。**
优先测试“启用 SLPI + 一行 FastRPC 修复”，配套安装已有固件和用户态服务。
补丁已接入两个内核构建，固件包安装 SLPI 镜像与 HexagonFS 数据种子；
用户态由 `nixos/sensors.nix` 默认启用。尚无 nabu 真机验证，完整构建交由 CI 完成。

## 缺在哪里

| 环节 | 调查时的缺口（本次提交前） |
| --- | --- |
| IIO 框架 | 不是主要缺口；arm64 defconfig 已启用 IIO，电源 ADC 也使用它。存在 IIO 设备不代表已有运动传感器。 |
| SLPI | 两个 SoC dtsi 已有 `remoteproc@2400000`、GLINK、FastRPC context banks；板级 DTS 未覆盖其 `status = "disabled"`。 |
| 保留内存 | 两个 nabu DTS 都已有 `slpi_mem`：`0x97b00000`，大小 `0x1400000`。无需重新划区。 |
| 固件 | 已锁定的 `nabu-firmware` ref `1` **包含** `slpi_nb.mbn` 和 `hexagonfs/`；`pkgs/nabu-firmware.nix` 没有安装它们。 |
| FastRPC | fork 已显式启用 `CONFIG_QCOM_FASTRPC=m`；7.2.6 也有驱动。两者都缺少下述 sensors PD 分配修复。 |
| 用户态 | `nixos/hardware-nabu.nix` 没有 hexagonrpcd、SSC 文件服务和传感器代理配置。 |

固件的 `hexagonfs/sensors/config/sm8150_lsm6dso_0.json` 描述了 LSM6DSO，
registry 也有 `.accel` 和 `.gyro` 项。它们由 SLPI 固件管理；不能把这些
DSP 总线参数直接当成 AP 的 I²C/SPI 节点，交给 `IIO_ST_LSM6DSX`。
[libssc 的架构说明](https://codeberg.org/DylanVanAssche/libssc/src/tag/v0.4.4/README.md)
解释了这类设备的访问限制。

访问链路分为两部分：hexagonrpcd 通过 `/dev/fastrpc-sdsp` 附着 sensors PD，
为 DSP 提供 registry/config 文件；应用通过 libssc，使用 QRTR/QMI SEE 服务读取传感器。
libssc 是 GLib 用户态库，**不会自动注册 `/sys/bus/iio/devices/` 运动设备**。
iio-sensor-proxy 的 SSC 后端直接使用这个库。

## 两个内核共用的最小补丁

准备了两份可共用的补丁，合计增加 5 行 DTS、修改 1 行 C：

1. 启用 SLPI：
   在 `sm8150-xiaomi-nabu.dts` 中设置 `status = "okay"`，固件路径为
   `qcom/sm8150/xiaomi/nabu/slpi_nb.mbn`。
2. 修复 sensors PD 消息分配：

   ```diff
   - if (ctx->fl->sctx->sid)
   + if (ctx->fl->sctx->sid && ctx->fl->pd != SENSORS_PD)
   ```

第二份来自 Robin Snyders 的[上游 v2 提交](https://lists.openwall.net/linux-kernel/2026/10/03/762)，
已有 [Dmitry Baryshkov 的 Reviewed-by](https://lists.openwall.net/linux-kernel/2026/10/05/99)。
它让 sensors PD 的消息缓冲区走现有 `fastrpc_remote_heap_alloc()` 路径，
避免把带 context-bank 地址编码的缓冲区交给该 PD 后，出现
`iova=0x1fffff000`、`fsr=0x402` 和 `sensor_process` 崩溃。
[提交者报告](https://lkml.iu.edu/2610.0/05977.html)在 Redmi K20 Pro、OnePlus 7T Pro
上验证过；这支持在 nabu 上优先试验，仍不能替代 nabu 测试。这里只确认提交和评审，
不将它称作已合入主线的修复。

| 内核 | 接入位置 | 配置处理 |
| --- | --- | --- |
| `sm8150-fork` 6.17 | 已接入 [0007 SLPI](../../pkgs/kernel/sm8150-fork/patches/0007-arm64-dts-qcom-enable-nabu-slpi.patch) 和 [0008 FastRPC](../../pkgs/kernel/sm8150-fork/patches/0008-misc-fastrpc-use-remote-heap-for-sensors-pd.patch)。 | 保留 fragment 的 `QCOM_FASTRPC=m`，增加 FastRPC、QRTR transport 配置断言。 |
| `mainline-latest` 7.2.6 | 已接入 [0011 SLPI](../../pkgs/kernel/mainline-latest/patches/0011-arm64-dts-qcom-enable-nabu-slpi.patch) 和 [0012 FastRPC](../../pkgs/kernel/mainline-latest/patches/0012-misc-fastrpc-use-remote-heap-for-sensors-pd.patch)，在现有 nabu 补丁之后。 | 显式要求 FastRPC、GLINK、PD mapper、QRTR transport，并检查最终配置。 |

最终 `.config` 还应确认 `QCOM_Q6V5_PAS`、`RPMSG_QCOM_GLINK_SMEM`、`QRTR`、
`QRTR_SMD`、`QCOM_PD_MAPPER` 可用（`y` 或 `m`）。其中大部分已经由现有配置保证；
不需要新增 SoC 驱动或整个 IIO 子系统补丁。注意 remote-heap 分配路径不等于
把 `slpi_mem` 改成 DMA 池；不要将 DSP 固件保留区复用成共享分配区。

## 已接入的 NixOS 用户态

`nabu.sensors.enable` 默认为 `true`，同时适用于 ext4 和 impermanent 系统。
实现位于 [sensors.nix](../../nixos/sensors.nix)，不需要手动启动服务：

1. `xiaomi-nabu-firmware` 安装 `slpi_nb.mbn`，以及
   `share/qcom/sm8150/xiaomi/nabu/` 下的 HexagonFS 数据，保留原 source/ref/hash。
2. hexagonrpcd 使用 `StateDirectory=nabu-sensors`，权限 `0700`。首次启动时将种子
   解引用复制到临时目录、设为可写，再原子发布到
   `/var/lib/nabu-sensors/hexagonfs`。后续启动和配置切换不覆盖 registry/校准数据；
   impermanent 系统已持久化 `/var/lib/nabu-sensors`。
3. `hexagonrpcd.service` 以 root 运行：

   ```sh
   hexagonrpcd -f /dev/fastrpc-sdsp -d sdsp -s -R /var/lib/nabu-sensors/hexagonfs
   ```

   节点未出现或进程退出时，每 5 秒重试。启动后使用 libssc 自带的 `ssccli`
   分别枚举、打开 accel/light，各运行 1 秒后关闭；失败时每 2 秒重试，不立即拆掉正常的 FastRPC 连接。
   启动总超时 90 秒，超时后重启。现有种子已包含 registry，无需每次重新生成。
   [hexagonrpc 文档](https://github.com/linux-msm/hexagonrpc/tree/v0.5.0)
   说明了 `-R` 文件树和静态 sensors PD 的用途。
4. `iio-sensor-proxy.service` 等待上述启动检查完成，才允许包括 udev 请求在内的
   启动操作继续。它通过 `BindsTo` 随 hexagonrpcd 停止，通过 `Upholds` 在其恢复后
   重新启动，避免继续使用旧的 DSP 枚举结果。代理保留上游允许 `AF_QIPCRTR` 的服务配置。
5. 已注册 SSC-enabled iio-sensor-proxy 的 D-Bus、udev、systemd 包，并为
   `fastrpc-sdsp` 增加 `ssc-accel` 标记。直接注册包，避免 stock
   `hardware.sensor.iio.enable` 向 fork 的 initrd 引入不存在的 `hid-sensor-hub`。
   轴变换仍交给 SEE 的设备配置，未照搬参考系统的 mount matrix。

锁定的 nixpkgs 提供 `hexagonrpc 0.5.0`、`libssc 0.4.4` 和启用 SSC 的
`iio-sensor-proxy 3.9`。`nabu.sensors.enable = false` 只停用用户态服务；
要同时阻止内核启动 SLPI，还需设置 `nabu.sensors.slpi.enable = false`。

重建系统或镜像并启动后，可运行：

```sh
systemctl status hexagonrpcd iio-sensor-proxy
journalctl -b -u hexagonrpcd -u iio-sensor-proxy
monitor-sensor --accel
monitor-sensor --light
ssccli --sensor gyroscope --timeout 10
```

自动旋转使用加速度计；3.9 的 SSC 后端只有 accel/light/compass/proximity，
`monitor-sensor` 不是陀螺仪采样工具。已安装的 `ssccli` 使用 libssc 0.4.4
读取三轴值，上例运行 10 秒后关闭传感器，无需另外编写采样程序。
当前没有自动修改 niri 输出变换；这里先提供传感器访问及桌面代理。
如果应用硬性要求 `/dev/iio:deviceN`/`in_anglvel_*` ABI，则还需要独立的 SEE→IIO
桥接工作；本方案不声称实现了这个接口。

## 启动回归与隔离（2026-10-21）

用户同时安装新内核和用户态后报告反复重启，更新前的系统代已被删除，正在恢复旧镜像。
照片显示 7.2.6 的 `drm_crtc_wait_one_vblank()` 告警，调用来自 fbdev damage work。
该位置在 [7.2.6 源码](https://github.com/gregkh/linux/blob/v7.2.6/drivers/gpu/drm/drm_vblank.c#L1309)
中等待 1 秒后发出 WARN 并返回超时，照片未包含最终 panic 原因。
目前不能断定 DRM、SLPI 启动或 FastRPC 附着中的哪一环触发了整机重启。

[恢复模块](../../nixos/sensors-recovery.nix)增加了两个 systemd-boot 特化项：

| 菜单项后缀 | 用户态 | SLPI 节点 |
| --- | --- | --- |
| `sensors-off` | 停用 | 通过 DT overlay 禁用 |
| `sensors-userspace-off` | 停用 | 保持启用 |

两个条目复用所选内核，均加 `panic=0` 以保留普通 panic 的现场。
`sensors-off` 的 overlay 只改 SLPI 节点，保留 ADSP/CDSP/MPSS；不需要重新编译内核。
这些条目需要安装包含恢复模块的系统/ESP 才会出现，不能恢复已经删除的旧系统代。
已用 dtc/fdtoverlay 在两个内核的 DTB 上验证 SLPI 禁用，并检查 ADSP/CDSP 保持启用；
配置求值也确认恢复项复用同一个内核 derivation。恢复项本身仍待真机启动验证。

恢复后先保存 `/sys/fs/pstore/`、`/var/lib/systemd/pstore/` 和前一启动的 kernel journal。
诊断脚本现会收集二者、前一启动的内核/传感器服务日志和 panic 策略。
若重刷清除了这些记录，或复位没有留下 pstore，空日志不能排除崩溃。

后续先试 `sensors-off`，再试 `sensors-userspace-off`，最后才启用完整传感器链路。
若第二项失败而第一项可启动，优先调查 SLPI 启动；若只有完整链路失败，优先调查
FastRPC 附着/SEE 请求及其内核路径。若第一项也失败，继续调查相同内核的其他启动路径。
`panic=0` 不能阻止固件/硬件看门狗复位；临时 blacklist `qcom_q6v5_pas` 会同时停用
多个 DSP，其结果只能作为较宽的隔离测试，不能单独证明 SLPI 是原因。

## 为什么不直接搬 Kumar-Jy 的全部改动

[参考 DTS](https://github.com/Kumar-Jy/linux/blob/739161a890128f23bd1aa679d8754a9ea299269e/arch/arm64/boot/dts/qcom/sm8150-xiaomi-nabu-sensors.dtsi)
证实了固件路径；但[其 FastRPC 实现](https://github.com/Kumar-Jy/linux/blob/739161a890128f23bd1aa679d8754a9ea299269e/drivers/misc/fastrpc.c)
同时引入 high-IOVA alias、PDR 等待，还回退了较新主线的 `sid_pos`、DMA 位宽和匹配数据。
这些改动不能作为一个必要整体照搬到 7.2.6。

先测试上游的一行分配修复；只有仍有对应故障的证据，再分别评估 alias、
`dma-coherent` 和 PD 就绪竞态。alias 里的 `sid` 来自 context-bank 的 `reg=1/2/3`，
并非 SMMU stream ID `0x5a1/0x5a2/0x5a3`；不能照参考树 STATUS 文本把二者混用。
参考树的“working”矩阵也不证明已提供内核 IIO 运动设备。

## 验证边界与真机验收

本次已从两个精确版本获取相关源文件和 DTS include 闭包，应用仓库现有 DTS
改动，再验证两份候选补丁均通过 `git apply --check`。使用 GCC 14.3 预处理、
dtc 1.7.2 编译成功：fork DTB 为 106808 字节，mainline 为 106876 字节。
读取两个 DTB 均确认 SLPI `status=okay`、固件路径正确，`memory-region` 指向
`0x97b00000/0x1400000`。没有进行完整内核编译、最终 Kconfig 构建或真机测试。
接入构建后，两个内核 derivation 的求值及
`nix flake check --no-build --all-systems` 均通过。
用户态接入后重新通过上述求值检查；已执行 `sensors-state` 检查脚本，确认只读种子
可复制为可写状态、符号链接被解引用、已有校准不会覆盖、失败复制可清理并重试。
另已检查 impermanent 持久化及关闭 `nabu.sensors.enable` 时的配置。
真机按链路逐段验证，避免把“SLPI running”当成传感器已可用：

1. 对两个内核分别构建、启动；检查最终配置和 DTB，确认 SLPI 的固件路径、
   `status`、保留内存正确。
2. `/sys/class/remoteproc/*/{name,state}` 中 SLPI 为 running，存在
   `/dev/fastrpc-sdsp`；日志无固件缺失。
3. hexagonrpcd 能附着并提供 registry，QRTR 出现 SEE 服务；日志无上述 SMMU
   fault、`sensor_process` 崩溃或持续重启。
4. `monitor-sensor --accel`、`--light` 有实际变化；libssc gyro 客户端收到连续三轴样本。
   通过 SSC 工作时，没有新增 IIO sysfs 运动设备并不代表失败。
5. 再验证冷启动、代理早启动、DSP 重启和 suspend/resume；按实际姿态校正
   mount matrix，不预先复制别的系统的轴变换。

完整构建入口仍是 `nix build .#nabu-kernel-sm8150-fork` 和
`nix build .#nabu-kernel-mainline-latest`。Push 本次提交后，手动运行
`.github/workflows/build-kernel.yml`，其矩阵会分别构建并缓存两个内核。
该工作流只构建内核；新版固件包和用户态配置需要后续系统/镜像构建才会安装。
本次没有刷写设备或改变内核选择。
