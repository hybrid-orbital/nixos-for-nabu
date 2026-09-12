[English](../building.md) | **简体中文**

# 构建、交叉编译与缓存

[返回项目首页](../../README_zh_CN.md)

构建入口以当前 [`flake.nix`](../../flake.nix) 为准。复现发布镜像应检出对应 tag，
保留 `flake.lock`，并记录本地配置修改；不要在构建配套镜像之间更新输入。

## 当前输出

| 输出 | 内容 |
| --- | --- |
| `nixosConfigurations.nabu` / `ext4-nabu` | ARM64 原生 ext4 配置，包含 niri + Noctalia |
| `nixosConfigurations.impermanent-nabu` | tmpfs root + Btrfs 持久化配置 |
| `packages.<system>.ext4-nabu-{esp,rootfs}` | ext4 配置的配套镜像 |
| `packages.<system>.impermanent-nabu-{esp,rootfs}` | 无状态配置的配套 ESP 和 Btrfs 镜像 |
| `packages.<system>.nabu-esp` | `esp.img` 和 `efi-files.zip` |
| `packages.<system>.nabu-rootfs` | 默认不压缩的 `nabu-rootfs.ext4.img` |
| `packages.<system>.nabu-kernel` | sm8150 内核 |
| `packages.<system>.default` | `nabu-esp` |

`<system>` 支持 `x86_64-linux` 和 `aarch64-linux`。当前没有 `nabu-uki`、
`nabu-kde`、`nabu-tty` 等输出，后两者属于路线图。

ext4 系统的主机名是 `nabu`（`ext4-nabu` 的别名），impermanent 系统是
`impermanent-nabu`；两者都是 flake 的键或别名，因此 `sudo nixos-rebuild switch
--flake .` 会按已安装的存储方案自动选中对应配置，无需手写 `#hostname`。

## 构建配套镜像

需要 Linux、支持 flakes 的 Nix、网络或完整的本地依赖缓存，以及足够的磁盘和内存。
桌面和内核构建的资源需求会随配置变化；不要把历史最小系统的磁盘估算当作当前上限。

```sh
git clone https://github.com/hybrid-orbital/nixos-for-nabu.git
cd nixos-for-nabu
# 复现当前 alpha；开发新配置时使用自己的分支
git checkout v0.1.0-alpha
nix build .#nabu-esp .#nabu-rootfs
```

更方便的导出入口：

```sh
bash scripts/build-image.sh
# 或只导出一种镜像
bash scripts/build-image.sh esp
bash scripts/build-image.sh rootfs
# 无状态配置的配套镜像
bash scripts/build-image.sh all impermanent
```

脚本在新的 `result-images/build-*` 目录保存镜像与 `SHA256SUMS`，也可通过 `OUT_DIR`
指定新目录。它拒绝覆盖同名产物。脚本按顺序构建两个输出，期间应保持工作树不变。
这是本地构建流程；目前没有已经落地的 GitHub Actions 镜像流水线。

存储布局、自定义持久化目录和无状态版本的使用说明见[存储方案](storage.md)。

## 原生构建与交叉构建

Nix 的平台命名与日常“宿主机/目标机”的说法容易混淆：

| 模式 | `buildPlatform`（运行构建工具） | `hostPlatform`（运行产物） |
| --- | --- | --- |
| 平板或 ARM64 Linux 构建机原生构建 | aarch64-linux | aarch64-linux |
| x86_64 Linux 交叉构建 | x86_64-linux | aarch64-linux |

当前 flake 的 x86_64 输出会设置交叉构建平台；它的设计不要求通过 QEMU 运行 ARM64
构建工具。`--system aarch64-linux` 只是选择 ARM64 输出，不会自动配置交叉工具链或
ARM64 构建机。要用原生 ARM64 输出，需要原生机器、已配置的远程 ARM64 builder，
或另外配置的模拟执行环境。

**交叉编译是可尝试的构建路径，不是所有软件包都能通过的保证。** 软件包可能在构建时
运行目标程序，依赖未适配的工具链，或在更新 nixpkgs 后出现交叉专有问题。
`nix flake check --no-build --all-systems` 通过只证明相应检查的求值成功，
不代表镜像能构建、更不代表能在平板启动。

## 为什么刷入交叉镜像后还要编译

即使目标都是 ARM64，交叉和原生构建的 `buildPlatform`、编译器及依赖图不同，
通常对应不同的 derivation 和 `/nix/store` 路径。差异来自构建输入，不是换了一台机器
或主机名就必然改变 hash；相同平台和相同输入的另一台原生 builder 仍可共享结果。

交叉构建镜像可以正常运行。但在平板上用 `nixosConfigurations.nabu` 原生 rebuild 时，
Nix 需要的是原生求值所得闭包，可能重新构建内核和大量包。已有交叉闭包不会自动被当成
原生闭包使用。这也可能增加首次 rebuild 的时间和磁盘占用。

并非所有包都一定重编：原生二进制缓存命中或已有匹配产物时会复用。交叉缓存只帮助
匹配的交叉 derivation；在 PC 上预热交叉镜像不能承诺加速平板的原生 rebuild。
长期维护可考虑 ARM64 原生构建机及对应缓存，相关设施仍待建设。

参见 [Nix 官方交叉编译教程](https://nix.dev/tutorials/cross-compilation.html)
和 [Nixpkgs 跨平台参数](https://nixos.org/manual/nixpkgs/unstable/#ssec-cross-platform-parameters)。

## 镜像体积与压缩

ext4 镜像按系统闭包大小加 `nabu.image.rootFsExtraSize` 余量分配空间，默认余量为 512 MiB。
Btrfs 则先压缩预装闭包并缩小文件系统，再附加同样的余量，详见[存储说明](storage.md)。
当前配置设置 `nabu.image.compress = false`，便于直接刷写。release 的 zstd 压缩和分卷
是发布包装，与 flake 默认输出不同。

外层 zstd 打包只降低下载体积；Btrfs 内部压缩也会减少预装文件在设备上的占用。
缩减 rootfs 应先测量大依赖、固件、桌面组件和构建工具的闭包，再决定如何拆分变体。
构建机上可先查看默认原生配置闭包（x86_64 上运行此命令不会自动改为交叉配置）：

```sh
nix build .#nixosConfigurations.nabu.config.system.build.toplevel --out-link result-system
nix path-info -Sh ./result-system
```

这一步需要可用的 ARM64 构建能力或匹配缓存；不要为了测量体积在不合适的机器上盲目
触发完整构建。已有运行系统可用 `nix path-info -Sh /run/current-system` 记录闭包大小。
体积优化和各变体的目标见[路线图](roadmap.md)。

## 故障报告

记录提交、lock 文件、构建平台、完整命令、失败 derivation 和构建日志；区分求值失败、
构建失败、镜像生成失败和真机启动失败。不要把某个平台的一次成功推广到所有变体。
当前旧 `scripts/qemu-smoke.sh` 仍需要 UKI，**不适用于本版本产物**；它的更新是待办，
本指南不将其列为当前镜像的验证手段。
