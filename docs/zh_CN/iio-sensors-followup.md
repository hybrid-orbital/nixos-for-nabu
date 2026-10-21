# 传感器启动回归：源码复查与下一轮验证

> 更新：本轮 lab 的手动 attach 已复现卡死；当前实现改用
> [context-bank alias 实验版本](iio-sensors-alias-candidate.md)。下文保留当时的分析，
> remote-heap 补丁已撤换；分阶段启动及日志采集步骤仍适用。

2026-10-21。设备已恢复到 `e7b3cc4b7b59a4b9a72adfb8bbdbd0b55927d2c9`。
本报告取代[初版调查](iio-sensors-investigation.md)的默认启用和自动重试策略。
基线仍为 `v6.17.0-sm8150`、锁定 nixpkgs 的 Linux 7.2.6、hexagonrpc 0.5.0、libssc 0.4.4。

**已确定上一版存在域表漏项和启动策略缺陷；尚不能确定哪条路径导致那次 AP panic。**
现有照片只有 DRM vblank WARN，没有最终 panic、SLPI crash reason 或 SMMU fault。
恢复期间混用 ESP 启动文件与最新 profile 所产生的 zram/输入问题，也不能作为传感器
补丁崩溃的证据。新的方案可以逐层证伪；不能在没有设备日志时宣称传感器已经修好。

## 1. 漏掉了 PD mapper 的 SM8150 域表

两个基线的 `drivers/soc/qcom/qcom_pd_mapper.c` 都定义了：

```c
slpi_root_pd   /* msm/slpi/root_pd,   instance_id = 90 */
slpi_sensor_pd /* msm/slpi/sensor_pd, instance_id = 90 */
```

但 `sm8150_domains[]` 没有引用它们，只有 ADSP/CDSP/MPSS。`qcom_pdm_start()`
根据根节点 compatible 选表，再由 `qcom_pdm_add_domain()` 注册 `tms/servreg`
到域名/实例的映射。`qcom_pdm_get_domain_list()` 只会返回已经注册的条目。
因此即使 `CONFIG_QCOM_PD_MAPPER=m` 且模块成功加载，SM8150 仍不会公告这两个 SLPI 域。
此前把“驱动已开启”当作“域发现完整”是不成立的。

[6.17 fork 源码](https://gitlab.com/sm8150-mainline/linux/-/blob/v6.17.0-sm8150/drivers/soc/qcom/qcom_pd_mapper.c)、
[7.2.6 源码](https://github.com/gregkh/linux/blob/v7.2.6/drivers/soc/qcom/qcom_pd_mapper.c)、
[Kumar 固定版本](https://github.com/Kumar-Jy/linux/blob/739161a890128f23bd1aa679d8754a9ea299269e/drivers/soc/qcom/qcom_pd_mapper.c)
可以直接对照：参考树正好补上了这两项。

本次对两个内核接入同一份[两行补丁](../../pkgs/kernel/patches/0001-soc-qcom-pd-mapper-add-sm8150-slpi-domains.patch)。
这是有依据的协议配置修复，但“公告域存在”不等于“该 PD 已经 UP”，更不证明固件
一定在崩溃前查询过这个域。后者需要日志。现有配置使用内核 mapper；不要再并行启动
另一个用户态 pd-mapper 服务来掩盖漏项。仓库中有该包定义不代表服务正在运行。

## 2. FastRPC 的一行修复覆盖范围有限

调用顺序是：`hexagonrpcd -s` → `FASTRPC_IOCTL_INIT_ATTACH_SNS` →
`fastrpc_init_attach()` 设置 `fl->pd = SENSORS_PD` → `fastrpc_internal_invoke()` →
`fastrpc_get_args()`。附着成功后，daemon 才注册 reverse listener，提供 HexagonFS。
[hexagonrpcd 0.5.0 源码](https://github.com/linux-msm/hexagonrpc/blob/v0.5.0/hexagonrpcd/rpcd.c)。

原始消息分配路径通过 context-bank device 分配 DMA 地址，再把 session selector
加到高 32 位。例如 `reg = <1>` 与低地址 `0xfffff000` 合成 `0x1fffff000`。
`reg=1` 是 FastRPC session selector；SMMU stream ID `0x5a1` 是另一个值。
DSP 若没有按该 ABI 拆分地址，就可能访问未映射的高 IOVA。

保留的[一行修复](https://lists.openwall.net/linux-kernel/2026/10/03/762)
让 sensors PD 的 **RPC 消息缓冲区** 经 `fastrpc_remote_heap_alloc()` 分配。
该函数实际选择 RPMsg 父设备，而非 context-bank device；“remote heap”这个函数名
不保证已有一个独立、正确配置的 reserved-memory 池。nabu 的 FastRPC 子节点没有
`memory-region`；SLPI 固件自己的 `slpi_mem` 不能拿来充当 RPC 分配池。

还存在另一条真实调用路径：hexagonrpcd 的 `apps_mem_request_map64()` 支持
`ADSP_MMAP_ADD_PAGES`，会调用 `FASTRPC_IOCTL_MMAP`；内核对此仍调用
`fastrpc_buf_alloc()`，没有被 `fastrpc_get_args()` 的改动覆盖。
所以“attach 已成功”也不能证明后续固件内存请求正确。
[apps_mem.c](https://github.com/linux-msm/hexagonrpc/blob/v0.5.0/hexagonrpcd/apps_mem.c)、
[fastrpc.c](https://github.com/gregkh/linux/blob/v7.2.6/drivers/misc/fastrpc.c)。

Kumar 的替代方案在 context-bank 的 IOMMU domain 中建立高 IOVA alias，保留低地址
DMA 分配，释放时先撤销 alias；它覆盖的范围不同于上述消息分配修复。其版本同时
撤回了上游 SoC-specific SID/DMA 位宽处理，不能整份替换主线驱动。
另有 PDR UP 等待和 `dma-coherent` DT 属性。前者需要先补域表，后者属于硬件一致性
声明，不能用作一般性的“修复缓存”开关。

下一轮先测试 PD 表 + 已评审消息分配修复。若在正确模块下仍复现高 IOVA fault：

1. 记录 fault 的 IOVA、stream ID、context bank 和紧邻的 attach/mmap 操作。
2. 区分首个 attach 消息与 `ADSP_MMAP_ADD_PAGES` 数据页，确认失败路径。
3. 若证据支持 alias ABI，再制作仅限 nabu/SDSP 的替代补丁，保留上游
   `fastrpc_sid_offset()`、DMA mask 和原始 DMA handle；校验 domain aperture、
   alias 地址占用，处理失败回滚及 unmap/free 生命周期。不要同时叠加两套分配策略，
   也不要对所有 DSP 全局改回 32 位地址。

## 3. 旧启动检查会在正常初始化完成前拆掉文件服务

旧配置在 `ExecStartPost` 循环执行 accel/light 两次 `ssccli --timeout 1`，
同时设置 `TimeoutStartSec=90s`、`Restart=always`、无限启动重试。

但 `ssccli` 的计时器在 `new_sync()` 和 `open_sync()` **返回成功之后**才注册。
`--timeout 1` 不是覆盖整个进程的一秒截止时间。libssc 的 registry discovery
代码允许 100 次约一秒的重试，外加请求时间；即使正常等待也可能超过 90 秒。
systemd 此时会终止整项服务，包括已工作的 hexagonrpcd，再重新附着。
此外，成功退出只说明执行了采样窗口，并不保证 measurement 回调收到过一帧。
[libssc 0.4.4 CLI](https://codeberg.org/DylanVanAssche/libssc/src/tag/v0.4.4/src/libssc-cli.c)、
[传感器初始化](https://codeberg.org/DylanVanAssche/libssc/src/tag/v0.4.4/src/libssc-sensor.c)。

本次删除 `ExecStartPost` 采样循环、`Upholds` 和自动重启。`Type=exec` 只表示进程
成功 exec，不再把它描述成 SEE readiness。光线传感器也不再作为陀螺仪支持的前置条件。
HexagonFS 的目录映射本身正确：`-R` 下的 `sensors/registry` 被映射到 DSP 的
`/persist/sensors/registry/registry`；`-d sdsp` 只影响 DSP library 搜索目录。
继续保留可写状态种子和校准数据，不在失败时清空 registry。

## 4. 可执行的验证顺序

默认启动关闭用户态和 SLPI，保留三个显式菜单项；它们复用同一个内核：

| 条目 | SLPI | 用户态 |
| --- | --- | --- |
| 默认 / `sensors-off` | DT overlay 禁用 | 无 |
| `sensors-userspace-off` | 启用 | 无 |
| `sensors-lab` | 启用 | 工具和手动 hexagonrpcd；不注册 proxy 的 D-Bus/udev 激活 |

先保留设备上可启动的 e7b3cc4 generation，安装 CI 产物时使用 `nixos-rebuild boot`，
不要删除旧代或把旧 ESP 的 `init` 指向最新 profile。所选内核种类保持与对照组相同。

1. 启动默认项确认基础系统；再启动 `sensors-userspace-off`。如果后者已经崩溃，
   故障发生在用户态 attach 之前，优先查 PAS 固件加载、SLPI fatal、共享资源和 remoteproc
   恢复路径；不要继续改 hexagonrpcd 参数。
2. 启动 `sensors-lab`，首先确认 `hexagonrpcd` 没有运行，读取所有 remoteproc 的
   name/state/firmware。不要假定 SLPI 永远是 `remoteproc0`。
3. 手动启动一次文件服务，然后查看日志和 QRTR 服务。service 400 只证明 SEE endpoint
   已公告，不代表 registry 和 gyro 已准备好。
4. 分别读取 accel、gyro、light，并确认输出中确实有随设备运动变化的 measurement。
   `timeout` 是外层进程时间限制；内核若陷入不可中断等待，它不能保证杀死进程。

```sh
uname -r
ls /run/booted-system/kernel-modules/lib/modules/
modinfo -n fastrpc
modinfo -n qcom_pd_mapper
for r in /sys/class/remoteproc/remoteproc*; do
  printf '%s\n' "$r"
  cat "$r/name" "$r/state" "$r/firmware"
done
systemctl status hexagonrpcd
sudo systemctl start hexagonrpcd
sudo journalctl -b -u hexagonrpcd --no-pager
timeout 10s qrtr-lookup
sudo timeout -k 5s 150s ssccli --sensor accelerometer --timeout 10
sudo timeout -k 5s 150s ssccli --sensor gyroscope --timeout 10
sudo timeout -k 5s 150s ssccli --sensor light --timeout 10
```

同时从另一终端保存 `sudo journalctl -kf -o short-monotonic`，每步后采集
`sudo bash scripts/nabu-diagnostics.sh /var/tmp`。遇到错误停止下一步，保留
`/sys/fs/pstore/`、`/var/lib/systemd/pstore/` 和本次启动 journal。
多次冷启动、采样和 suspend/resume 都通过后，才在普通配置中显式设置：

```nix
nabu.sensors = {
  enable = true;
  autoStart = true;
  proxy.enable = true;
};
```

proxy 的依赖只保证进程顺序，不保证 SEE 数据就绪。若代理先启动后未枚举到设备，
先验证 `ssccli` 有数据，再手动重启一次代理；自动 readiness/recovery 要在真机的
服务时序明确后补充。陀螺仪仍通过 libssc 读取，不会自动成为 `/dev/iio:deviceN`。

## 5. 无 ARM64 本机构建机的迭代方式

本次本地仅做补丁应用、源码审查、DTB/overlay 检查、shell 语法和 Nix 配置求值；
不构建内核或系统镜像。正式的完整内核由现有 GitHub CI 构建。

若只迭代 FastRPC/PD mapper，可在 CI 的 ARM64 runner 或有相应交叉工具链的机器上，
调用[局部构建脚本](../../scripts/build-sensor-modules.sh)：

```sh
bash scripts/build-sensor-modules.sh mainline-latest \
  /path/to/matching-linux-source \
  /path/to/existing-kernel-dev/lib/modules/7.2.6/build \
  /path/to/new-output-directory
```

fork 用 `sm8150-fork`，其 module release 是 `6.17.0`。脚本只复制两个 C 文件及
`pdr_internal.h`，应用两个 C 补丁，用外部 Kbuild 编译两个 `.ko`，不会构建 Image、
DTB、其他模块或执行 `modules_prepare`。已打补丁的源码也可使用。
必须提供**目标内核原来构建生成的** `.config`、生成头文件和 `Module.symvers`；
保留其编译器配置，x86 机器显式设置 `CROSS_COMPILE` 或 `LLVM`。
单有相同的 `uname -r` 不足以保证 ABI 一致。

可以使用 e7b3cc4 的匹配构建产物做这一局部迭代；不要为了取得 `kernel.dev` 而
对含新内核补丁的 derivation 执行 `nix build`，那会隐式触发完整内核构建。
`kernel.dev` 未缓存时，先从原 CI 产物/cache 获取，或安排 CI 生成，不能假称这一步免费。
局部脚本只产出模块和校验信息，不会安装/热卸载共享的 PD mapper；部署时需生成独立
模块树和匹配的 generation，在重启后验证，不能把实验模块覆盖进已恢复的稳定代。

## 验证边界

静态证据支持补齐域表及修正启动策略。两种内核的硬件启动、FastRPC attach、SSC
测量以及休眠恢复仍待设备验证；没有把未编译的 ARM64 模块或未执行的硬件测试记作通过。
