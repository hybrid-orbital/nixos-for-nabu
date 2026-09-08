# 存储方案与镜像

[返回项目首页](../README_zh_CN.md)

仓库提供两个存储配置，桌面均为 niri + Noctalia：

| 配置 | `/` | 持久化数据 | 镜像 |
| --- | --- | --- | --- |
| `ext4-nabu`（`nabu` 的默认配置） | ext4 | 常规根文件系统 | `nabu-rootfs.ext4.img` |
| `impermanent-nabu` | tmpfs，上限为内存的 25% | 同一 Btrfs 分区内的子卷 | `nabu-rootfs.btrfs.img` |

Btrfs 版本是新增的实验配置，仍需要在平板上验证冷启动、重启和日常更新。
自动测试使用通用内核，不模拟 nabu 的 UEFI、UFS 或显示硬件。

## 布局与保留的数据

两个版本都使用现有 GPT 中的 `esp` 和 `linux` 分区，不重新分区。
ESP 始终挂载在 `/boot/efi`。无状态版本的 `linux` 分区为：

```text
Btrfs top level
├── @nix        → /nix
├── @persistent → /nix/persistent
└── @home       → /home

tmpfs           → /
```

`/nix` 整体保留，包括 store、数据库、profiles 和 GC roots；`/home` 整体保留，
因此用户可编辑的 niri 配置和个人文件不会在重启后丢失。
`/nix/persistent` 虽然位于 `/nix` 下，但挂载的是独立子卷。

系统状态由 [impermanence](https://github.com/nix-community/impermanence) 映射：
machine-id、SSH 主机密钥、NetworkManager/iwd 配置、蓝牙配对、系统日志、必要的
NixOS/systemd 状态和 `/root`。准确清单见
[`storage/impermanent.nix`](../nixos/storage/impermanent.nix)。
账户通过 `users.mutableUsers = false` 声明式重建；密码设置方式见下文。

其余根目录内容在重启后丢弃。软件包和用户数据不装进 tmpfs，但写入根目录的临时数据
会占用内存。无状态配置通过 `nix.settings.build-dir` 把 Nix 构建临时目录放到
`/nix/var/nix/builds`，避免大型 rebuild 填满 tmpfs。

无状态根目录不提供用户数据备份，也不会自动创建 Btrfs 快照。
NixOS generation 回滚只回滚系统配置和闭包，不回滚持久化数据。

## 自定义持久化目录

在无状态配置所导入的模块中设置：

```nix
nabu.storage.persistentDirectory = "/persist";
```

这会同步改变子卷挂载点、impermanence 的路径和注册清单位置。
默认清单路径是 `${config.nabu.storage.persistentDirectory}/nix-path-registration`。
也可以单独设置 `nabu.image.registrationPath`，但必须位于镜像覆盖的持久化挂载中，
且不能放进 `/nix/store`。构建器按最长匹配挂载点计算镜像内的位置，所以嵌套的
`/nix/persistent` 不会被误放进 `@nix`。

镜像配置中的改动适用于新安装。已有系统改变持久化路径时，需要同步处理现有挂载、
引用和数据，不能把 `nixos-rebuild switch` 当作自动迁移工具。

## 无状态版本的密码

初始用户名和密码仍为 `nabu`。这个版本不会保留 `passwd` 对 `/etc/shadow` 的修改，
重启或重新激活配置会恢复声明的密码。传统 ext4 版本继续使用 `passwd`。

要设置私人密码，先在平板上把哈希写入持久化目录（若自定义了路径，请相应替换）：

```sh
sudo install -d -m 0700 /nix/persistent/passwords
nix shell nixpkgs#mkpasswd -c mkpasswd -m yescrypt | sudo sh -c 'umask 077; cat > /nix/persistent/passwords/nabu'
```

然后在系统配置的模块中声明，并执行 `nixos-rebuild switch --flake .#impermanent-nabu`：

```nix
{ config, ... }: {
  users.users.nabu.hashedPasswordFile =
    "${config.nabu.storage.persistentDirectory}/passwords/nabu";
}
```

哈希文件由 activation 读取，不复制进 Nix store。必须先创建文件再启用该设置；
文件缺失时不会回退到公开的默认密码。之后修改密码只需更新该文件并重新激活配置。

## 构建与安装

```sh
# Default ext4 pair
bash scripts/build-image.sh all ext4

# Matching ESP and Btrfs pair
bash scripts/build-image.sh all impermanent
```

也可直接构建 `.#impermanent-nabu-esp` 和 `.#impermanent-nabu-rootfs`。
所有配置统一提供 `config.system.build.esp-image` 和 `config.system.build.rootfs-image`。
ESP 内的 initrd 和系统路径随配置变化，必须和 rootfs 配套。

确认已有分区容量足够、备份完成后，Btrfs 版本的刷写目标仍是：

```sh
fastboot flash linux nabu-rootfs.btrfs.img
fastboot flash esp esp.img
```

从 ext4 切换到 Btrfs 是重新安装，会覆盖 `linux` 分区，包括其中的用户数据。
新版本镜像也不是保留已有持久化数据的更新包；日常更新使用
`sudo nixos-rebuild boot --flake .#impermanent-nabu`。这个版本不要使用默认的 `.#nabu`，
否则会选择 ext4 挂载配置。

## 启动、注册与扩容

initrd 根据 `fileSystems` 挂载 tmpfs 根目录、`/nix`、持久化子卷和 `/home`，再进入
系统初始化。内核配置检查要求 Btrfs 和 tmpfs 内建。镜像预先创建持久化绑定挂载的
源目录，避免首次启动时在 activation 之前挂载失败。

镜像包含系统闭包和初始 profile 链接。首次启动的 `register-nix-paths.service`
从配置指定的位置读取清单，在 nix-daemon 启动前执行 `nix-store --load-db`，
设置 system profile；两步都成功后才删除清单。后续启动直接使用持久化的数据库。
清单由镜像构建器写入，不放进系统闭包自身，以免形成循环依赖。

两个版本都使用 `x-systemd.growfs` 将文件系统扩展到已有分区大小。
Btrfs 仅在 `/nix` 上安排扩容，同一文件系统的其他子卷共享扩展后的空间。
initrd 显式包含 growfs 单元和程序。没有使用 `boot.growPartition`、`sgdisk` 或
启动时重新分区；过小的 `linux` 分区仍需用户在安装前另行处理。

首次启动和一次重启后检查：

```sh
findmnt -t tmpfs,btrfs
df -h /nix
sudo btrfs filesystem usage /nix
systemctl --failed
journalctl -b -u register-nix-paths.service --no-pager
nix-store --query --requisites /run/current-system
```

确认根目录临时文件被清除，而用户文件、声明的密码、machine-id 和网络配置保留。

## 构建器与检查

构建器复制系统闭包后，使用 `mke2fs -d` 或 `mkfs.btrfs --rootdir --subvol`
生成独立文件系统镜像，不需要挂载镜像或运行 VM。Btrfs 使用用户命名空间保证镜像内
属主为 root，因此构建环境需要允许非特权用户命名空间。它使用 4 KiB 文件系统扇区，
当前 mkfs 默认启用的特性适用于仓库的 Linux 6.17 内核。

```sh
nix flake check --no-build --all-systems
nix build .#checks.x86_64-linux.filesystem-images
nix build .#checks.x86_64-linux.storage-boot
```

第一个构建检查使用小闭包，验证镜像元数据、子卷、自定义路径和 Nix DB 内容。
第二个启动通用 NixOS 测试机，覆盖首次启动注册、扩容、重启后的临时文件清理和状态保留。
启动测试允许 QEMU 软件模拟，无 KVM 时会较慢。
