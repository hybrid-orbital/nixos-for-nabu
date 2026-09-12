# 参与项目

当前技术基线为 systemd-boot、外部 DTB、原生 NixOS generations 和 niri + Noctalia。
欢迎改进构建易用性、镜像体积、其他桌面与存储方案、硬件支持、CI 和文档。
具体方向见[路线图](docs/zh_CN/roadmap.md)。

## 提交改动

尽量让一次改动解决一个可以验证的问题。说明问题、预期行为、影响范围和验证结果。
涉及原作者或其他项目的代码、固件和资源时保留来源及许可；必要时优先向对应上游反馈。
新文件须纳入 Git 跟踪后才会被 Git flake 读取。

根据改动选择验证，不必为纯文档更改重编整个镜像：

- 文档：检查相对链接、命令、输出名称、语言首页和已知问题是否一致。
- Nix 配置：求值相应输出；可用 `nix flake check --no-build --all-systems` 作初步检查。
- niri 配置：构建过程会用构建机上的 niri 校验 KDL；交互、输入映射和 IPC 仍需真机检查。
- 引导/镜像：构建配套 ESP 与 rootfs，记录平台、提交、产物 hash，并验证首次启动和后续 rebuild。
- 内核/电源：保留可启动旧代，分别记录冷启动、热重启、输入、显示与休眠恢复。

明确写出“只求值”“构建成功”“QEMU 验证”或“真机验证”，不要混用。
当前提供[手动内核和镜像 CI](docs/zh_CN/building.md#手动-github-actions-构建)，
旧 `scripts/qemu-smoke.sh` 尚未适配 systemd-boot 产物。

## 报告设备问题

按[设备状态文档](docs/zh_CN/device-status.md#如何提供有用的报告)记录固件、构建平台、
重现步骤和日志。相机、低功耗休眠和偶发启动失败已列为已知问题（重启后随机 Wi-Fi MAC 地址问题已解决），
新增证据可帮助缩小范围。

## 发布与文档同步

发布新版本时，同时更新：

1. 源码 tag/提交、lock、构建平台及变体。
2. 镜像名称、合并解压步骤、SHA256SUMS 和实际刷写分区。
3. 真机验证范围、已知问题、冷启动/热重启及回滚测试结果。
4. 中英文 README、设备状态和相应操作指南。

特别检查 ESP 刷入 `esp`，不是 `boot`。当前 alpha release 的旧说明存在这个笔误，
纠正说明见[安装文档](docs/zh_CN/installation.md#刷写到现有分区)。
GitHub Actions 已支持手动构建、校验、分卷打包和[日期版本 release 发布](docs/zh_CN/building.md#构建并发布-release)。
发布前更新 `.github/workflows/release-images.yml` 内的 changelog 及比较基准 tag；实机验证仍需独立完成和记录。
