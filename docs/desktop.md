# niri + Noctalia 桌面

[返回项目首页](../README_zh_CN.md) · [设备状态](device-status.md)

这是当前发布镜像的默认桌面。相机不可用、低功耗休眠未解决，且仍有偶发启动失败；
电源键被刻意忽略，锁屏不代表熄屏或低功耗休眠。其他桌面变体仍在[路线图](roadmap.md)中。

`nixos/niri.kdl` 管理布局、输入设备、窗口规则和快捷键；
`nixos/niri.nix` 管理 NixOS 软件包、服务、登录界面及 KDL 构建校验。
当前配置对应 flake.lock 中的 niri 26.04 和 Noctalia 5.0.1。

## 常用快捷键

正常登录桌面后，`Mod` 是键盘上的 Super / Windows 键。
首次进入桌面会显示快捷键帮助，也可随时按 `Mod+Shift+/` 再次打开。

| 快捷键 | 功能 |
| --- | --- |
| `Mod+Shift+/` | 显示快捷键帮助 |
| `Mod+Return` / `Mod+E` | Foot 终端 / Thunar 文件管理器 |
| `Mod+Space` / `Mod+S` / `Mod+,` | Noctalia 启动器 / 控制中心 / 设置 |
| `Alt+Tab` | Noctalia 窗口切换面板 |
| `Mod+Shift+K` | 显示或关闭 wvkbd 虚拟键盘 |
| `Super+Alt+L` | Noctalia 锁屏 |
| `Mod+←↓↑→` 或 `Mod+H/J/K/L` | 左右切换列、上下切换列内窗口 |
| 上述方向键加 `Ctrl` | 移动列或列内窗口 |
| `Mod+Home/End` | 聚焦最左 / 最右列；加 `Ctrl` 移动当前列 |
| `Mod+Shift+方向键` | 切换显示器；加 `Ctrl` 将列移到该显示器 |
| `Mod+PageUp/PageDown` 或 `Mod+I/U` | 切换上 / 下工作区 |
| 上述工作区键加 `Ctrl` / `Shift` | 移动当前列到工作区 / 调整工作区顺序 |
| `Mod+1…9` | 按序号切换动态工作区；加 `Ctrl` 移动当前列 |
| `Mod+Tab` | 返回上次使用的工作区 |
| `Mod+[` / `Mod+]` | 将窗口并入左 / 右列，或从列中拆出 |
| `Mod+Ctrl+,` / `Mod+.` | 从右侧吸入窗口 / 将底部窗口拆出 |
| `Mod+R` / `Mod+Shift+R` | 正向 / 反向循环列宽预设：1/3、1/2、2/3 |
| `Mod+-` / `Mod+=` | 列宽减少 / 增加 10% |
| `Mod+Shift+-` / `Mod+Shift+=` | 窗口高度减少 / 增加 10% |
| `Mod+Ctrl+Shift+R` / `Mod+Ctrl+R` | 循环高度预设 / 恢复自动高度 |
| `Mod+C` / `Mod+Ctrl+C` | 居中当前列 / 居中所有完整可见列 |
| `Mod+F` / `Mod+Shift+F` | 最大化列宽 / 窗口全屏 |
| `Mod+M` / `Mod+Ctrl+F` | 窗口最大化到屏幕边缘 / 列扩展到剩余可用宽度 |
| `Mod+V` / `Mod+Shift+V` | 切换浮动 / 在浮动与平铺间切换焦点 |
| `Mod+W` / `Mod+O` | 列内标签模式 / 工作区总览 |
| `Print` 或 `Mod+Shift+S` | 交互式截图 |
| `Ctrl+Print` / `Alt+Print` | 截取当前屏幕 / 当前窗口 |
| `Mod+Escape` | 切换应用快捷键抑制，便于退出虚拟机等应用的键盘捕获 |
| `Mod+Q` / `Mod+Shift+Q` | 关闭窗口 / 显示退出会话确认 |

音量、麦克风静音、亮度和媒体键由 Noctalia 处理，锁屏时也可使用。
截图保存到 `~/Pictures/Screenshots/`。`Alt+Tab` 面板打开后，可以用
Tab / Shift+Tab 或方向键选择，再按 Enter 确认、Escape 取消，也可以点击窗口。

## 鼠标、触控板与平板

- 按住 `Mod` 拖动鼠标左键移动窗口，右键调整窗口大小。
- `Mod+滚轮上下` 切换工作区，加 `Ctrl` 将当前列移到该工作区。
- `Mod+滚轮左右` 或 `Mod+Shift+滚轮上下` 切换列，加 `Ctrl` 移动列。
- 触控板启用轻触点击、自然滚动和输入时禁用；niri 原生三指滑动导航，四指上滑打开总览。
- 保留电源键不触发挂起/关机的设备规避设置。未添加自动挂起策略。

默认新窗口占半屏；单列自动居中，切换到放不下的列时居中。
Noctalia 设置窗口使用相对屏幕大小的浮动尺寸。内屏 `DSI-1` 默认旋转 270 度，
与键盘横置方向一致；分辨率、刷新率和缩放仍自动选择。
Noctalia 的概览背景层已接入 niri；具体背景效果在 Noctalia 设置中选择。

Thunar 配合 GVfs / UDisks 提供文件浏览、回收站和可移动设备访问。
X11 应用通过 niri 自动启动的 xwayland-satellite 运行。
NixOS 的 niri 模块提供 GTK 文件选择器、GNOME 屏幕共享 portal、密钥环和 XDG 自启动。

## 屏幕方向

各阶段分别设置方向，不能用一条内核参数控制整条启动流程：

| 阶段 | 配置 | 当前行为 |
| --- | --- | --- |
| systemd-boot 菜单 | `EFI/systemd/drivers/GopRotate_aa64.efi` | 加载原 rEFInd 使用的旋转驱动，用户已验证菜单横屏 |
| Linux 启动日志、TTY | `fbcon=rotate:1` | 顺时针 90 度横屏，保留已有设置 |
| Noctalia 登录界面 | `settings.output.transforms = "DSI-1:270"` | 登录界面自身的合成器旋转内屏 |
| niri 桌面、桌面锁屏 | `output "DSI-1" { transform "270"; }` | 启动时直接采用横屏，无需登录后运行 IPC 命令 |

niri 的角度按逆时针计算，270 度与 fbcon 的顺时针 90 度一致。
登录界面独立于 niri，必须单独设置；这里只匹配内屏，未固定其他输出的方向。
数位笔通过 `input { tablet { map-to-output "DSI-1"; } }` 绑定内屏，
坐标自动跟随该输出的旋转。未绑定时 niri 使用不带旋转的整体桌面映射，
可能出现笔尖与光标相差四分之一圈的现象。无需额外添加固定旋转校准矩阵。
应用后用笔检查四角和中心；临时切回竖屏时，笔坐标也应随输出变换。
先验证横屏下触摸四角是否与画面对应，不预先叠加全局触摸校准矩阵。

systemd-boot 的 `console-mode` 选择固件提供的文本模式，不是旋转角度。
菜单横屏由 GopRotate 驱动提供，无需重刷 UEFI。驱动沿用旧 rEFInd 引导资源中
`BOOT/drivers_aa64/GopRotate_aa64.efi`，来源版本和哈希在 `nixos/boot.nix` 固定。
systemd-boot 会在显示菜单前加载 ESP 的 `EFI/systemd/drivers/` 中对应架构的驱动；
保留文件名的 `aa64.efi` 后缀，不需要复制 rEFInd 本体或 `refind.conf`。

`boot.loader.systemd-boot.extraFiles` 同时用于 `nixos-rebuild boot/switch` 和
`nabu-esp` 的 `esp.img` / `efi-files.zip` 打包，包含旋转驱动和 Android 启动程序。
部署后可以检查 `/boot/efi/EFI/systemd/drivers/GopRotate_aa64.efi` 是否存在，
再重启验证菜单、登录界面、桌面及显示接管。此前手动放入同一驱动若使用了不同文件名，
应移走旧副本，只保留这一份，避免同一驱动被重复加载。

应用后重启，依次检查登录界面和桌面；在桌面运行 `niri msg outputs` 检查 DSI-1。
已有用户配置应保留 `include "/etc/niri/config.kdl"`，且没有后续覆盖内屏方向的设置。
临时手持竖屏仍可运行 `niri msg output DSI-1 transform normal`；恢复横屏使用
`niri msg output DSI-1 transform 270`。默认方向由 KDL 管理。

参考：
- [niri 输出配置](https://niri-wm.github.io/niri/Configuration%3A-Outputs.html)
- [Noctalia Greeter 1.3.1 示例配置](https://github.com/noctalia-dev/noctalia-greeter/blob/v1.3.1/examples/greeter.toml)
- [Linux fbcon 旋转](https://docs.kernel.org/fb/fbcon.html)
- [systemd-boot 配置](https://github.com/systemd/systemd/blob/v261/man/loader.conf.xml)

## 应用与验证

在平板上，从仓库目录应用配置：

```sh
sudo nixos-rebuild switch --flake .#nabu
niri validate --config /etc/niri/config.kdl
niri validate
```

新加入的文件需要先纳入 Git 跟踪，Git flake 才能读取；不需要提交。
可用 `nix flake check --no-build --all-systems` 检查所有平台的配置求值。
每次构建系统配置都会使用构建机上的 niri 校验 KDL，交叉构建也不需要运行 aarch64 程序。
软件包和会话环境更新后建议重新登录，再检查截图、锁屏解锁、媒体键和文件选择器。

`~/.config/niri/config.kdl` 是归 `nabu` 所有的可编辑普通文件，通过下面一行引用系统配置
（niri 的语法是 `include`，不是 `import`）：

```kdl
include "/etc/niri/config.kdl"
```

镜像首次启动时，systemd-tmpfiles 创建归 `nabu` 所有的 `~/.config`、
`~/.config/niri`（0700），并复制初始配置为普通文件（0600）。
已有配置不会被覆盖，用户和 Noctalia 可继续在引用之后添加本地设置或主题引用。
系统配置更新仍由 NixOS 管理；已有系统若缺少这行 `include`，需手动补到用户文件开头。
也可以在部署前直接运行 `niri validate --config nixos/niri.kdl` 检查语法。
KDL 校验不验证 IPC 的运行效果，锁屏、触摸输入和屏幕共享仍需真机测试。

## 参考

- [niri 26.04 默认配置](https://github.com/niri-wm/niri/blob/v26.04/resources/default-config.kdl)
- [NixOS Wiki：niri](https://wiki.nixos.org/wiki/Niri)
- [Noctalia v5：niri 集成](https://docs.noctalia.dev/noctalia/compositor-settings/niri/)
- [Noctalia v5：IPC 命令](https://docs.noctalia.dev/noctalia/ipc/)

保留本仓库原有 `Mod+,` 设置面板与 `Mod+Shift+K` 虚拟键盘绑定，
因此 niri 默认的吸入窗口操作改到 `Mod+Ctrl+,`，显示器导航使用方向键。
