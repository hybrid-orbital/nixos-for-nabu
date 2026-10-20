# nabu 传感器调查与两个内核的最小补丁方案

调查日期：2026-10-21。基线是 `v6.17.0-sm8150`，以及 `flake.lock` 中
`nixpkgs/20b1ddd1aa5ace70c9468305030aa4f9ef79671b` 的 `linux_latest = 7.2.6`。
Kumar-Jy 参考树固定到 `739161a890128f23bd1aa679d8754a9ea299269e`，避免跟随分支变化。

**结论：缺的是 SLPI/SSC 的完整访问链路，不能通过多开几个 IIO 芯片驱动解决。**
优先测试“启用 SLPI + 一行 FastRPC 修复”，配套安装已有固件和用户态服务。
本次提交已将补丁接入两个内核构建，并安装固件与 HexagonFS 数据种子；
用户态运行服务尚未启用，没有 nabu 真机验证。内核完整编译由 GitHub CI 完成。

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

## 必须配套的 NixOS 改动

**只应用内核补丁，还不会得到可用传感器。** 固件安装已完成，用户态步骤仍待配置：

1. 已在 `pkgs/nabu-firmware.nix` 现有安装逻辑中增加：

   ```sh
   cp -a slpi_nb.mbn "$fw/qcom/sm8150/xiaomi/nabu/"
   mkdir -p "$out/share/qcom/sm8150/xiaomi/nabu"
   cp -a hexagonfs/. "$out/share/qcom/sm8150/xiaomi/nabu/"
   ```

   原 source/ref/hash 保持不变。已修正 `pkgs/linux-firmware-nabu.nix` 中把传感器
   固件说成 `adsp.mbn` 的注释：nabu 这里需要单独的 SLPI 镜像。
2. 首次启动时把该 HexagonFS 树复制到可写的 `/var/lib/nabu-sensors/`，
   解引用 store 符号链接并设置目录/文件可写；后续保留 registry 和校准数据，
   不要每次开机用种子覆盖。现有源已经有 registry，可先使用，无需盲目重新生成。
   impermanence 配置也应持久化这个目录。
3. 新增 root systemd 服务，使用 `StateDirectory=nabu-sensors`，运行：

   ```sh
   hexagonrpcd -f /dev/fastrpc-sdsp -d sdsp -s -R /var/lib/nabu-sensors
   ```

   使用 nixpkgs 的 `pkgs.hexagonrpc`；为设备节点尚未出现、PD 尚未就绪和 DSP
   重启安排重试。`ConditionPathExists=` 单独使用会跳过服务且不会自动重试。
   代理也应在 SSC 能枚举传感器后启动/重新探测，不能仅靠固定延迟。
   [hexagonrpc 文档](https://github.com/linux-msm/hexagonrpc/tree/v0.5.0)
   说明了文件树和 `-R`；不需要为这个静态 PD 另行创建 `fastrpc_shell_2`。
4. 锁定的 nixpkgs 已有 `hexagonrpc 0.5.0`、`libssc 0.4.4` 和
   `iio-sensor-proxy 3.9`，后者已显式 `-Dssc-support=enabled`，无需另找 patched 版本。
   把代理包注册到 `environment.systemPackages`、`services.dbus.packages`、
   `services.udev.packages`、`systemd.packages`。通常可用
   `hardware.sensor.iio.enable = true`；但该 NixOS 模块还会向 initrd 加入
   `hid-sensor-hub`，fork 必须先确认有这个模块，否则直接做上述四项注册，
   避免无关 HID 模块破坏 initrd 构建。

自动旋转使用加速度计；3.9 的 SSC 后端只有 accel/light/compass/proximity，
`monitor-sensor` 不是陀螺仪采样工具。读取 gyro 应使用已打包的 libssc 0.4.4：
`ssc_sensor_gyroscope_new_sync()`、连接 `measurement(x,y,z)` 信号、
`ssc_sensor_gyroscope_open_sync()` 并运行 GLib 主循环。
如果应用硬性要求 `/dev/iio:deviceN`/`in_anglvel_*` ABI，则还需要独立的 SEE→IIO
桥接工作；本方案不声称实现了这个接口。

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
该工作流只构建内核；新版固件包将在后续系统/镜像构建时安装。
本次没有刷写设备或改变内核选择。
