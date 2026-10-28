# 贡献指南

欢迎一起完善 Toccata！代码、文档、翻译、测试和使用反馈都很有帮助。改动可以从一个小问题开始，涉及新平台或较大的功能时，先开 Issue 聊聊方向。

目前可运行的客户端为 macOS 版。Windows 版正在招募贡献者，独立入口位于 [apps/toccata-windows/](apps/toccata-windows/README.md)。

[English contribution overview](#english)

## 找到适合参与的部分

- 修复问题或提出功能：先搜索 [现有 Issues](https://github.com/KMnO4-zx/Toccata/issues)，已有讨论可以直接补充。
- 参与 Windows 客户端：在 [Windows 版本支持 #1](https://github.com/KMnO4-zx/Toccata/issues/1) 留言，说说想参与的功能和准备采用的方案。
- 修改现有 macOS 客户端：参考 [开发指南](develop.md) 定位代码、配置环境和运行验证。
- 修改数据结构、进程通信或统计规则：先阅读 [IPC 协议与数据契约](shared/protocol.md) 和 [按键次数与活跃时间计算](develop.md#按键次数与活跃时间计算)。

## 提交代码

1. Fork 仓库，将自己的 Fork 与上游 `main` 同步，然后克隆到本地。
2. 从 `main` 创建功能分支。例如，在仓库根目录执行：

   ```bash
   git switch main
   git switch -c feat/windows-client
   ```

3. 按功能拆分改动。可以尽早提交 Draft PR，写明关联的 Issue、已完成的部分和需要讨论的问题。
4. 完成相关验证，在 PR 中说明改动后的行为、验证方式和已知限制。界面改动请附截图；修复问题时说明复现步骤。
5. 将 PR 的目标分支设为本仓库的 `main`，一起 Review 和完善后合并。

分支名可按实际功能调整，例如 `fix/task-completion`、`docs/windows-setup`。

## 一起推进 Windows 版

技术栈开放讨论。请先在 [Issue #1](https://github.com/KMnO4-zx/Toccata/issues/1) 对齐方案，再逐步实现：

1. 可以在 Windows 构建、运行的客户端，以及基础任务管理与本机存储。
2. 子任务、Markdown 详情、任务日历、每周回顾和托盘入口。
3. Windows 键盘采集、热力图、活跃时间线，以及安装包和自动构建。

客户端代码、平台资源和构建说明放在 `apps/toccata-windows/`。各阶段可以独立提交 PR；共享逻辑的抽取、Rust 服务的平台适配和数据契约修改，先在 Issue 或 Draft PR 中讨论。

任务完成规则、按键计数和活跃时长计算保持一致。当前契约中的键码、应用标识和通信方式包含 macOS 约定，Windows 的映射、应用识别、进程通信及 Fn 等特殊键行为需要分别确认。

键盘活动保存在本机，采集过程不截图、不录音、不保存输入文本。「思维净活跃时长」根据键盘活动估算，不能直接测量思维，也无法覆盖阅读、思考等全部投入。

## 验证改动

- 所有改动先运行 `git diff --check`，文档改动检查链接和资源路径。
- macOS 改动按 [验证与调试](develop.md#验证与调试) 运行相关测试。构建和打包使用 macOS SDK **26.5**，与现有界面验证环境一致。
- 存储和统计改动覆盖数据迁移、去重、跨日期边界及实时与历史结果的一致性。
- Windows 改动提供实际 Windows 环境下的构建步骤和验证结果，注明系统版本、CPU 架构及使用的工具链。技术栈确定后，将命令维护到 [Windows 目录说明](apps/toccata-windows/README.md)。

文案或界面文字有变化时，请同步中英文。发现某项测试无法在当前环境运行，可以在 PR 中说明原因和已完成的验证。

## English

Contributions to code, documentation, translations, and testing are welcome. Fork the repository, create a feature branch from an up-to-date `main`, and open a pull request targeting this repository's `main` branch. Draft PRs are welcome for early discussion.

The Windows client is currently in planning and has no runnable implementation. Join [Windows support #1](https://github.com/KMnO4-zx/Toccata/issues/1) to discuss the stack and scope, and use [apps/toccata-windows/](apps/toccata-windows/README.md#english) for the client. Tasks, statistics, and privacy principles should stay consistent across platforms; key codes, app identifiers, capture, and IPC need platform-specific design.

Include the related issue, the resulting behavior, build instructions, test results, and screenshots for UI changes. Windows contributions should state the Windows version, CPU architecture, and toolchain used. Keep keyboard activity records local; capture must not take screenshots, record audio, or save typed text.

For macOS builds, use macOS SDK **26.5** and the commands in the [developer guide (Chinese)](develop.md). Run checks appropriate to the change, keep documentation links working, and update Chinese and English text together.
