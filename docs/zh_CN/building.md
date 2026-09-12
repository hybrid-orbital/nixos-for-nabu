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
CI 构建可使用下面的手动工作流。

## 手动 GitHub Actions 构建

工作流文件进入默认分支后，Actions 页面会出现两个 `workflow_dispatch` 工作流。
两次运行请选择相同分支/tag，并确保对应提交没有变化：

1. **Build kernel and push to Cachix** 构建
   `.#nixosConfigurations.nabu.config.system.build.kernel`，并显式上传内核闭包至
   `nix-nabu`。首次运行前，在仓库 Actions secrets 中设置 `CACHIX_AUTH_TOKEN`，
   token 需要该缓存的写权限。缺少凭据或上传失败会使任务失败，即使内核已经命中缓存。
2. **Build and package images** 按 ext4、impermanent 两个独立任务构建
   `.#ext4-nabu-esp`、`.#ext4-nabu-rootfs`、`.#impermanent-nabu-esp`、
   `.#impermanent-nabu-rootfs`。读取公开缓存无需 Cachix secret；每个方案上传一个
   Actions artifact，保留 14 天。

两者都使用 `ubuntu-24.04-arm` 原生 ARM64 构建，并为现有 `nix-nabu` 缓存显式设置
`extra-substituters` 和 `extra-trusted-public-keys`。镜像内的 NixOS 设置不会自动配置
CI runner。建议先成功运行内核工作流以预热缓存；镜像流程仍可构建缓存缺失的依赖。
命中缓存要求 derivation 相同，包括内核配置及锁定的输入。两个工作流均不更新
`flake.lock`。如需更换缓存，应同步修改两个工作流中的 URL/公钥、内核工作流的缓存
名称及对应 token。

每个 artifact 包含 `esp.img.zst`、`efi-files.zip`、rootfs 的 `.img.zst.part-0000`
分卷、`SHA256SUMS`、`SHA256SUMS.images`、`RESTORE.txt` 和 `BUILD-INFO.txt`。
后者记录提交、存储方案、平台、输出 store 路径、Nix 版本和 lock 文件 hash。
下载并解开 artifact 后，按 `RESTORE.txt` 操作：校验下载文件、按顺序连接分卷并直接
解压，最后校验原始镜像再刷写。小镜像同样使用 `.part-0000` 命名；单个分卷不能独立
解压或刷写。

本地也可复用打包脚本：

```sh
bash scripts/package-images.sh /path/to/esp-output /path/to/rootfs-output ./dist
# 可选：SPLIT_SIZE=1000M 覆盖默认的 1900 MiB 分卷大小。
```

输出目录必须尚不存在。脚本支持原始或已压缩的 rootfs，直接将 zstd 输出流传给
`split`，并校验压缩流，无需额外复制完整 rootfs 或生成合并压缩文件。
各分卷打包在同一方案的 Actions artifact 内；分卷不能绕过仓库 artifact 总存储配额。
上传时关闭 ZIP 再压缩，避免重复压缩镜像。

托管 runner 磁盘空间有限，单个任务超时为六小时。镜像任务会清理闲置 SDK 目录并限制
Nix 并行构建数，但较大的闭包或冷构建仍可能需要更大的 ARM64 runner。后处理节省的是
导出空间，不能降低 Nix store 和镜像构建临时目录本身的空间需求。impermanent 任务会在
临时 VM 中允许非特权 user namespace，以支持 Btrfs 镜像所有权设置，适配
[Ubuntu 24.04 的 AppArmor 限制](https://documentation.ubuntu.com/release-notes/24.04/)。这两个流程生成构建
产物；发布 release 可使用下面的发布流程，真机启动验证仍需单独完成。平台及 artifact 行为参见上游
[runner 说明](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
和 [artifact action](https://github.com/actions/upload-artifact)。

## 构建并发布 Release

在 Actions 中手动运行 **Build images and publish release**
（[release-images.yml](../../.github/workflows/release-images.yml)）。它复用镜像工作流，
以 ARM64 原生构建两套配套镜像并读取 `nix-nabu` 缓存；两套构建都成功后才执行发布。
无需额外 PAT 或 Cachix 写 token，发布 job 使用仓库自带 `GITHUB_TOKEN` 的
`contents: write` 权限。仓库规则必须允许该 token 创建对应的 release/tag。

版本格式为 `vYYYY.MM.DD.RUN.ATTEMPT`，例如 `v2026.09.12.3.1`。日期取发布 job
执行时的上海时区，后两段是此工作流的运行编号和重跑次数，允许同日多次发布。
tag 指向本次运行的确切提交。附件先上传到草稿，全部成功后自动公开为最新 release；
上传失败会保留草稿，重跑会使用新版本号，不覆盖旧版本或附件。仅重跑失败任务时，
允许复用同一次运行中已经成功的另一套镜像。失败草稿可在 Releases 页面手动清理。

Release 不上传整套 artifact ZIP；每个文件都是独立下载项：

| 文件（以 ext4 为例） | 内容 |
| --- | --- |
| `ext4-nabu-esp.zip` | ESP 内的 EFI、loader、nixos 文件目录 |
| `ext4-nabu-esp.image` | 可直接刷写的未压缩 ESP 镜像 |
| `ext4-nabu-rootfs.image.zst.part-0000` 等 | rootfs 压缩分卷，每卷最多 1900 MiB |
| `ext4-nabu-SHA256SUMS` / `ext4-nabu-SHA256SUMS.images` | 下载文件 / 原始镜像校验 |
| `ext4-nabu-RESTORE.txt` / `ext4-nabu-BUILD-INFO.txt` | 还原说明 / 构建来源 |

impermanent 使用 `impermanent-nabu-` 前缀，文件名互不冲突。ESP 随存储方案变化，
必须下载同一版本、同一方案的配套文件。`.image` 与原 flake 的 `.img` 内容相同。
rootfs 即使只有一卷也使用 `.part-0000`，按附件中的说明连接解压后再刷写。

changelog 直接保存在发布工作流的 **Write release notes** 步骤，随发布提交进入 Git
历史；每次发布前更新正文和比较链接中的基准 tag。本次正文依据
`v0.1.0-alpha..73840aa` 的提交与当前设备状态整理。发布流程本身也列入了本次更新。
只有版本、提交及链接由运行环境填充，不使用自动生成的 changelog。

本地验证打包流程（含两套 release 附件的还原校验）：

```sh
bash tests/package-images.sh
# 单独生成 ext4 release 附件，输出目录必须尚不存在：
RELEASE_VARIANT=ext4 bash scripts/package-images.sh /path/to/esp-output /path/to/rootfs-output ./release-dist
```

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
上述手动工作流使用 ARM64 原生 runner 和对应缓存，避免这类差异。

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
