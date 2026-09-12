[English](../usage-on-device.md) | **简体中文**

# 设备上更新、回滚与清理

[返回项目首页](../../README_zh_CN.md)

当前由 NixOS 原生 systemd-boot 安装器管理启动文件和 generation 菜单。
不再运行 UKI 部署 hook，也没有 `nabu-previous.efi` 备份机制。

## 准备配置

在平板上保存仓库副本，从你要使用的提交或 release 开始修改：

```sh
git clone https://github.com/hybrid-orbital/nixos-for-nabu.git
cd nixos-for-nabu
git checkout v0.1.0-alpha
# 需要继续修改时可创建自己的分支
git switch -c my-nabu
```

当前关闭了自动设置 flake registry 和 NIX_PATH，应显式使用 `--flake`。
新文件需要先纳入 Git 跟踪，Git flake 才能读取；不必先提交。
从交叉镜像开始的首次原生 rebuild 可能重建大量依赖，见[构建指南](building.md)。

## 日常更新

ext4 系统的主机名是 `nabu`（`ext4-nabu` 的别名），impermanent 系统是
`impermanent-nabu`，所以下面的命令会按已安装的存储方案自动选中对应配置，
无需手写 `#hostname`：

```sh
sudo nixos-rebuild switch --flake .
```

它构建系统闭包、更新系统 profile、安装启动条目并激活运行中的配置。
内核和 initrd 的变更在下一次启动生效。只准备下次启动而不切换当前服务时：

```sh
sudo nixos-rebuild boot --flake .
```

只临时测试用户态配置可用 `nixos-rebuild test --flake .`；它不把测试结果设成
下一次默认启动系统，也不能临时更换当前运行内核。桌面配置更新与可写用户配置的关系见
[桌面说明](desktop.md#应用与验证)。

需要更新 nixpkgs 时先有意识地执行 `nix flake update`，再构建验证。普通 rebuild
不会自动把已锁定输入更新到最新版本。保存可启动的旧 generation，尤其是在修改内核、
initrd、图形或电源设置前。

## 回滚

系统还能使用时：

```sh
sudo nixos-rebuild switch --rollback
```

如果只想安排下次启动旧代而暂不切换当前服务，可用 `sudo nixos-rebuild boot --rollback`。
重启后核对实际启动条目和内核。不要以单独修改 Nix profile 代替启动器部署。

新配置不能正常启动时，在 systemd-boot 菜单选择仍保留的旧 generation。该条目选择
对应内核、initrd、DTB 和具体系统闭包，而不是“旧内核加当前 profile”。
手动从菜单启动旧代不等于已经永久改变系统 profile；进入系统后检查 generations，
再执行相应回滚或修复配置并 rebuild。不要假定 `--rollback` 总会指向刚才手动选择的条目。

```sh
sudo nix-env -p /nix/var/nix/profiles/system --list-generations
readlink -f /run/current-system
readlink -f /run/booted-system
readlink -f /nix/var/nix/profiles/system
bootctl list
```

`/run/current-system`、`/run/booted-system` 与默认 system profile 在 `switch` 或手动
选择旧代后可能不同，这本身不代表错误。generation 不恢复用户文件、数据库内容或磁盘分区。

## ESP 空间和历史清理

相同启动文件可以共享，但不同内核、initrd、DTB 仍需要空间。
当前仓库没有显式设置 generation 数量上限，可在自己的配置中加入：

```nix
boot.loader.systemd-boot.configurationLimit = 10;
```

这个选项限制启动菜单保留的代数，不等价于删除 Nix store 中的历史系统。
删除旧 generations 和 GC 会减少可回滚范围；先确认要保留的版本。

```sh
# 示例：明确不再需要 30 天前的 generations 后执行
sudo nix-collect-garbage --delete-older-than 30d
# 重新部署菜单，使其与保留的系统 generations 一致
sudo nixos-rebuild boot --flake .
df -h / /boot/efi
```

初始镜像的 `/nixos/*` 和 `nixos-nabu.conf`，以及旧 rEFInd/UKI 文件，不一定属于
后续 nixpkgs 安装器的清理范围。不要先删文件再看能否启动；先检查所有保留菜单中的引用。

## 电源与故障

当前 logind 忽略电源键，niri 也禁用了内建电源键处理。系统已可进入 s2idle
（蓝牙 UART 秒醒问题已修复），但按键无响应时不会自动休眠：不要将按键无响应误认为
正常休眠，也不要将锁屏等同于熄屏或 suspend。
偶发启动失败仍是已知问题。报告方法见[设备状态](device-status.md)和[启动日志](boot-logging.md)。
