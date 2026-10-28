# Toccata for Windows

Windows 客户端的独立开发目录。**当前处于方案讨论与贡献者招募阶段，尚无可构建的客户端或 Windows 安装包。**

想参与的话，先到 [Windows 版本支持 #1](https://github.com/KMnO4-zx/Toccata/issues/1) 留言，说明想做的部分和准备采用的技术方案，再按 [贡献指南](../../CONTRIBUTING.md) 提交 Draft PR。

## 从一个可运行的版本开始

1. 搭建 Windows 客户端，完成基础任务增删改、完成状态和本机存储。
2. 逐步补齐子任务、Markdown 详情、任务日历、每周回顾和托盘交互。
3. 接入 Windows 键盘采集，展示按键次数、热力图与活跃时间线。
4. 补充安装包、构建步骤和 Windows 自动构建流程。

技术栈、最低 Windows 版本和首批支持的 CPU 架构在 Issue 中讨论确定。欢迎认领某一个阶段，也欢迎提交文档、测试或界面方案。

## 代码与平台适配

Windows 客户端代码、平台资源及构建说明放在本目录，具体子目录随技术方案确定。

现有 macOS 界面使用 SwiftUI / AppKit，Rust 采集服务依赖 macOS API。Windows 端需要实现自己的界面、键盘采集、前台应用识别和进程通信。公共逻辑的抽取及 `core/`、`shared/` 的修改，先通过 Issue 或 Draft PR 交流。

- 任务完成、恢复、子任务和每周回顾遵循现有功能语义。
- 按键次数与活跃时长采用 [开发指南中的计算规则](../../develop.md#按键次数与活跃时间计算)。
- [现有数据契约](../../shared/protocol.md) 中的键码为 macOS CGKeyCode，应用标识为 bundle ID；Windows 键码映射和应用标识需要另外约定。
- Fn 等特殊键、长按、组合键和断开重连行为需要在实际 Windows 设备上验证。
- 键盘活动保存在本机，采集过程不截图、不录音、不保存输入文本。

首个可运行版本的 PR 请包含环境要求、构建与运行命令、运行截图、测试结果和已知限制，后续将对应说明维护到本文件。

## English

This directory is reserved for the Windows client. The port is in planning; there is currently no runnable Windows implementation or installer.

Join [Windows support #1](https://github.com/KMnO4-zx/Toccata/issues/1) to discuss the stack, Windows version, architecture, and initial scope. Start with a runnable client and basic local task management, then add further task features, keyboard statistics, packaging, and CI in small PRs.

See the [contribution guide](../../CONTRIBUTING.md#english). The current macOS UI and collector need Windows-specific implementations. Keep task behavior, statistics, and privacy principles consistent, and agree on Windows key codes, app identifiers, special-key behavior, and IPC before changing shared contracts.

Include the Windows version, architecture, toolchain, build and run commands, screenshots, test results, and known limitations with the first runnable implementation.
