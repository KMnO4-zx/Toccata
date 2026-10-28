# Toccata 开发指南

本文面向希望在本地构建、修改或二次开发 Toccata 的开发者，介绍代码结构、运行方式、数据边界和发布流程。所有命令均从仓库根目录执行，另有说明的除外。

## 架构与目录

Toccata 由 Rust 键盘采集服务和 SwiftUI / AppKit 工作台组成。任务功能由工作台独立提供，采集服务离线时仍可使用。

| 目录 | 职责 |
|---|---|
| [core/toccata-core/](core/toccata-core/) | CGEventTap 与 HID 采集、按键配对、SQLite 批量写入、Unix socket 广播 |
| [apps/toccata-studio/Sources/](apps/toccata-studio/Sources/) | 任务、日历、回顾、菜单栏面板、键盘统计与分享界面 |
| [apps/toccata-studio/Tests/](apps/toccata-studio/Tests/) | Swift 逻辑、存储与界面集成测试 |
| [shared/](shared/) | IPC 与数据库契约、键盘布局、版本信息、品牌和系统本地化资源 |
| [scripts/](scripts/) | 资源同步、App 构建、DMG 打包、发布与脚本测试 |
| [docs/releases/](docs/releases/) | 各版本发布说明 |
| [.github/workflows/release.yml](.github/workflows/release.yml) | 手动触发的构建与 GitHub Releases 发布工作流 |

后台服务将键盘原始事件写入 `toccata.db`，通过 socket 推送实时事件和落盘通知。Studio 只读键盘数据库，独立读写任务库 `tasks.sqlite` 和可重建的统计缓存。修改跨进程消息、数据库字段或统计语义前，先阅读 [shared/protocol.md](shared/protocol.md)。

## 构建与运行

### 从最新源码构建

准备好下方列出的开发环境后，在准备存放源码的目录依次执行以下命令，克隆 `main` 分支的最新代码并打包完整 App：

```bash
git clone --branch main https://github.com/KMnO4-zx/Toccata.git && cd Toccata

./scripts/build-app.sh
```

产物位于仓库的 `dist/Toccata.app`，已包含键盘采集服务。构建完成后，在同一终端运行以下命令即可打开：

```bash
open dist/Toccata.app
```

### 环境要求

- macOS 13 或更新版本。
- Git，用于克隆源码。
- Rust 工具链（`cargo`、`rustc`）。
- 支持 Swift 5.9 的 Xcode Command Line Tools。
- Python 3，用于运行打包与构建信息脚本的测试。

### 在现有源码中重新构建

```bash
./scripts/build-app.sh
open dist/Toccata.app
```

构建脚本会同步资源，编译 Rust 服务与 Swift 工作台，将服务嵌入 `Toccata.app`，最后完成代码签名。默认使用 ad-hoc 签名，无需钥匙串中的签名身份；已有签名身份时可通过 `TOCCATA_SIGN_IDENTITY` 显式指定。更换签名身份后，macOS 可能要求重新授予输入监控权限。

App 会在配置的 socket 不可连接时启动内嵌服务，已有可用服务则直接复用。关闭工作台窗口后，应用继续在菜单栏运行；选择“退出 Toccata”会保存任务修改，并等待由 App 启动的服务保存数据后退出。独立启动的服务由原启动方式管理。

### 分别运行服务与工作台

适合频繁修改代码或使用独立数据目录。以下两个终端都从仓库根目录开始，使用相同的 `TOCCATA_DATA_DIR`：

```bash
# 终端一：构建并运行采集服务
export TOCCATA_DATA_DIR="$HOME/Library/Application Support/Toccata-Dev"
cargo build --release --locked
./target/release/toccata-core
```

```bash
# 终端二：同步资源，构建并运行工作台
export TOCCATA_DATA_DIR="$HOME/Library/Application Support/Toccata-Dev"
./scripts/sync-assets.sh
swift build --package-path apps/toccata-studio -c release
./apps/toccata-studio/.build/release/toccata-studio
```

SwiftPM 可执行文件没有内嵌服务，需要另行启动采集进程。只开发任务功能时，可以仅运行工作台。`TOCCATA_DATA_DIR` 隔离任务库、键盘数据及服务配置；语言、外观等 `UserDefaults` 偏好不随它迁移。已运行的进程需要重启才能切换数据目录。

### 输入监控与登录启动

首次使用键盘采集，需要在“系统设置 → 隐私与安全性 → 输入监控”中允许对应的应用或开发启动程序。部分 macOS 版本不会主动弹出授权窗口，服务会在等待授权时定期重试。调试时可结合采集状态和日志判断原因；socket 连通不等于采集已经启用。

“登录时启动”默认关闭，由用户在应用设置中开启。登录自动启动时只显示菜单栏图标，不主动打开工作台或请求输入监控权限。构建和打包不会修改登录项。

如果自定义部署需要独立服务随登录运行，可使用 [scripts/com.toccata.core.plist](scripts/com.toccata.core.plist)。先将其中 `ProgramArguments` 改为实际服务可执行文件的绝对路径，再执行：

```bash
mkdir -p "$HOME/Library/LaunchAgents"
cp scripts/com.toccata.core.plist "$HOME/Library/LaunchAgents/"
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.toccata.core.plist"
```

使用自定义数据目录时，还需在 plist 的 `EnvironmentVariables` 中配置同一个 `TOCCATA_DATA_DIR`。标准 App 使用内嵌服务，无需安装 LaunchAgent。

## 数据与配置

默认数据目录为 `~/Library/Application Support/Toccata/`，可由进程环境中的非空 `TOCCATA_DATA_DIR` 覆盖，建议使用绝对路径。

| 文件 | 用途与写入方 |
|---|---|
| `tasks.sqlite` | 任务、子任务、日期、优先级和 Markdown 详情，由 Studio 独立读写；历史过程表为兼容保留 |
| `toccata.db` | 原始键盘事件与历史应用会话，后台服务独占写入，Studio 只读 |
| `toccata.statistics-cache.sqlite` | Studio 维护的按天统计缓存，可由原始事件重建 |
| `toccata.sock` | 后台服务的实时 JSON Lines 订阅接口 |
| `config.json` | 服务配置；Studio 也读取其中的路径及活跃估算参数 |
| `toccata.lock` | 后台服务的单实例锁 |
| `core.log` | App 启动的服务日志，包含启动、权限与写入错误，不记录键名或文本 |
| `studio-preflight.log` | App 启动内嵌服务时记录的输入监控权限预检查结果 |

SQLite 使用 WAL 模式。任务库与键盘库相互独立，统计缓存不会清理或压缩原始记录。缓存随时区、统计策略或源数据库身份变化重建；缓存不可用时回退原始查询。

`config.json` 的字段均可省略，默认值如下：

```json
{
  "activity_window_secs": 5,
  "idle_gap_secs": 60,
  "trailing_grace_secs": 5,
  "flush_interval_secs": 2,
  "flush_batch_size": 500,
  "db_path": null,
  "socket_path": null
}
```

- `activity_window_secs`：Studio 活跃估算的短窗口长度，修改后重启工作台生效。
- `idle_gap_secs`、`trailing_grace_secs`：仅用于兼容保留的 `app_sessions` 会话记录，当前活跃统计从原始事件计算。
- `flush_interval_secs`、`flush_batch_size`：服务按固定周期或达到批量阈值时落盘；持续输入不会推迟周期写入。提交成功后广播 `updated`，写入失败时保留缓冲重试。
- `db_path`、`socket_path`：可分别指定键盘库和 socket 的非空绝对路径；省略或设为 `null` 使用默认值。Studio 跟随这些配置，任务库仍位于数据目录下。

统计缓存跟随键盘数据库的位置，文件名为源数据库去掉扩展名后加 `.statistics-cache.sqlite`。修改服务配置后需重启服务。

## 二次开发入口

### 按功能定位代码

下表中的 Swift 文件均位于 `apps/toccata-studio/Sources/`，Rust 文件均位于 `core/toccata-core/src/`。

| 想修改的功能 | 主要入口 |
|---|---|
| 任务字段、存储和完成规则 | `TaskModels.swift`、`TaskStore.swift` |
| 工作台任务列表与详情 | `TasksView.swift`、`WorkspaceTaskRow.swift`、`TaskDetailView.swift` |
| 子任务顺序和拖拽 | `SubtaskOrder.swift`、`SubtaskReorder.swift` |
| 菜单栏任务面板与编辑浮窗 | `TaskMenuController.swift`、`MenuTaskPresentation.swift`、`QuickCaptureView.swift`、`FloatingTaskEditor.swift` |
| 任务日期、日历与回顾 | `TaskCalendarModel.swift`、`TaskCalendarView.swift`、`TaskReviewRange.swift`、`TaskReviewSnapshot.swift` |
| Markdown 详情编辑 | `TaskMarkdown.swift`、`MarkdownTextEditor.swift` |
| 活跃统计、排行与缓存 | `ActivityModels.swift`、`ActivityRepository.swift`、`StatsRepository.swift`、`DailyStatisticsCache.swift` |
| 键盘热力图与实时反馈 | `KeyboardLayout.swift`、`KeyboardHeatmapView.swift`、`LiveKeyboardHeatmapView.swift`、`LiveKeyboardFeedback.swift` |
| 分享图片 | `ActivityShareSnapshot.swift`、`ActivityShareCard.swift`、`ActivitySharePopover.swift` |
| 语言、外观与动画 | `LanguageSettings.swift`、`AppearanceSettings.swift`、`WorkspaceMotion.swift` |
| 应用生命周期、服务启动与登录项 | `ToccataStudioApp.swift`、`ApplicationLifecycle.swift`、`CoreProcessController.swift`、`LoginItemController.swift` |
| 关于页、版本与更新检查 | `AboutView.swift`、`AppVersion.swift`、`UpdateChecker.swift` |
| 键盘事件、特殊键与按住配对 | `tap.rs`、`hid.rs`、`special_keys.rs`、`tracker.rs` |
| 服务配置、数据库与 IPC | `config.rs`、`store.rs`、`ipc.rs`、`main.rs` |

### 修改任务与统计逻辑

新增任务字段时，同步调整模型、数据库迁移、编辑界面及相关测试，并更新 [数据契约](shared/protocol.md)。现有任务库需要兼容升级；存储事务成功后才发布界面状态。当前任务语义包括：

- 新任务默认不设置计划日期；创建、计划和完成时间分别保存。完成回顾按 `completed_at` 筛选，并同时保留当前未完成任务。
- 完成父任务会完成尚未完成的后代，已完成后代保留原完成时间。恢复子任务或给已完成父任务新增未完成子任务，会恢复已完成的祖先。
- 删除父任务会级联删除子任务。子任务排序限定在同一父任务、同一完成状态内，并保留筛选隐藏项的相对顺序。
- 任务时间字段使用 Unix epoch **秒**，键盘事件使用 Unix epoch **毫秒**。

活跃时长由有效按下后的短窗口与实际按住区间合并计算，默认窗口为 5 秒。重叠部分只计算一次，按本地日期边界裁剪，并汇总到 15 分钟时间格。Fn 按住时间单独合并，不添加短窗口；它只是语音输出时间的估算，服务不检测录音。

修改统计规则时，需要同时考虑历史查询、实时事件、应用排行、按天缓存与分享快照。应用排行分别按应用合并区间，各应用窗口可能重叠，时长不能直接相加作为全局活跃时间。实时动画只消费已有事件，不额外增加统计次数。完整规则与边界示例见 [shared/protocol.md](shared/protocol.md)。

### 修改键盘布局、品牌与界面文案

- 键盘布局源文件为 [shared/layout/magic-keyboard-ansi.json](shared/layout/magic-keyboard-ansi.json)。修改后运行 `./scripts/sync-assets.sh` 并重新构建；应用从资源包读取布局，没有数据目录中的运行时覆盖机制。字段定义见 [shared/README.md](shared/README.md)。
- 品牌图像由 `swift scripts/generate-branding.swift` 生成，输出到 `shared/branding/` 及 Studio 的 `AppIcon.icns`。修改图标后重新打包 App。
- 界面文案通过 `L10n.tr` 与 [English.json](apps/toccata-studio/Resources/Localization/English.json) 配对维护。新增文案需补充英文翻译，验证占位符、英文排版和即时切换；任务标题、详情等用户内容保持原文，持久化枚举值不随语言变化。
- 系统权限说明等 App 资源位于 [shared/macos-localization/](shared/macos-localization/)。日期展示跟随所选语言，数据库日期键和统计边界保持一致；界面动画需遵循系统“减少动态效果”设置。

### 维护自己的发行版

Fork 后如需独立分发，应检查以下位置：

- `UpdateChecker.swift` 中的 `ToccataReleaseSource.repository`：更新源、仓库链接及发布页面地址由此生成，按自己的仓库修改。更新检查由用户手动触发，只查询版本并打开发布页，不自动下载安装，也不上传任务或键盘记录。
- `scripts/build-app.sh` 中的 App 名称、Bundle ID 和签名要求，以及 `AppVersion.swift` 对 Bundle ID 的判断：改名或更换身份时保持一致。
- `AppPaths.swift` 与 Rust `config.rs`：独立发行版如需默认使用自己的数据目录，应同步修改两端；开发调试可先使用 `TOCCATA_DATA_DIR`。
- 品牌资源、系统本地化资源、`scripts/package-dmg.sh`、`scripts/create-github-release.sh` 与发布工作流中的产物命名；使用独立 LaunchAgent 时也需检查其标签与路径。

## 验证与调试

```bash
# 打包与构建信息脚本测试
python3 scripts/tests/test_release.py
python3 scripts/tests/test_build_info.py

# Rust 测试；依赖已缓存时可额外添加 --offline
cargo test --locked

# Swift 测试
./scripts/sync-assets.sh
swift test --package-path apps/toccata-studio

# 改动格式检查
git diff --check
```

`MarkdownWebEditorTests` 需要本机可交互桌面的 WebKit 环境。发布工作流使用 `swift test --package-path apps/toccata-studio --skip MarkdownWebEditorTests`；修改 Markdown 编辑器时仍需在本机补齐这部分验证。

界面改动还应在实际 App 中检查相关交互、浅色与深色外观、中英文排版和减少动态效果。存储改动应覆盖已有数据库迁移；采集改动应检查权限缺失、断开重连、长按与特殊键。自动化测试无法替代实际键盘设备和窗口交互验证。

采集异常时先查看界面采集状态、数据目录中的 `core.log` 和 `studio-preflight.log`；独立启动的服务将日志输出到终端。关于页可复制版本、构建号和源码提交信息，便于定位运行中的构建。

## 打包与发布

### 版本与构建信息

应用版本和构建号以 [shared/app-version.json](shared/app-version.json) 为准。`scripts/sync-assets.sh` 将它复制到 SwiftPM 资源目录，打包脚本写入 App 的 `Info.plist`；界面和 DMG 文件名读取同一版本。

升级版本时：

1. 更新 `shared/app-version.json` 中的版本和构建号。
2. 同步修改 `core/toccata-core/Cargo.toml` 的包版本并更新 `Cargo.lock`，Rust 包版本与应用版本不一致时构建会停止。
3. 运行 `./scripts/sync-assets.sh`，提交同步后的版本资源。
4. 添加 `docs/releases/v<version>.md`，更新受影响的文档并完成验证。

构建号独立递增，不参与公开版本比较。资源同步时还会调用 `scripts/write-build-info.sh`，生成包含源码提交和工作区修改状态的 `Resources/build-info.json`；该文件已被 Git 忽略，无需手动维护或提交。

### 生成 DMG

```bash
# 构建 App 并生成压缩只读磁盘映像
./scripts/package-dmg.sh

# 复用已构建的 dist/Toccata.app，验证后打包
./scripts/package-dmg.sh --skip-build
```

产物为 `dist/Toccata-<version>-<arch>.dmg` 及同名 `.sha256` 文件。版本取自 App 的 `CFBundleShortVersionString`，架构由工作台与内嵌服务的实际二进制判定，可为 `arm64`、`x86_64` 或 `universal`。脚本验证两者的签名与架构一致性，使用 `hdiutil` 生成 UDZO 映像并验证 SHA-256；同版本、同架构的旧产物在新包验证成功后替换。

DMG 包含 App、“应用程序”快捷方式和安装说明。脚本只生成文件，不安装或启动 App，也不修改登录项或系统权限。

默认 ad-hoc 包用于开发与验证，打包脚本不执行 Apple 公证。`TOCCATA_SIGN_IDENTITY` 仅用于选择签名身份；正式分发还需自行配置 Developer ID、Hardened Runtime、公证与票据装订。

### 手动发布到 GitHub Releases

[Release Toccata](.github/workflows/release.yml) 工作流仅支持手动触发，推送提交或标签不会自动发布。工作流文件进入默认分支后，在 GitHub 的 **Actions → Release Toccata → Run workflow** 中操作：

1. 选择 `main`，填写与版本文件一致的标签，例如版本为 `0.0.11` 时填写 `v0.0.11`。其他分支不执行发布构建。
2. 默认 `draft` 模式运行测试、构建并验证 DMG，然后创建带安装包和 SHA-256 文件的 Release 草稿；审核后可直接在 GitHub 发布。
3. `publish` 模式先创建草稿并上传附件，全部成功后发布正式版本并标记为 Latest。

工作流使用 macOS ARM runner 构建 Apple Silicon 安装包，按触发时的确切提交构建，说明来自 `docs/releases/<tag>.md`。构建任务仅有读取权限；发布任务单独使用仓库的 `GITHUB_TOKEN` 写入 Releases，应用内无需令牌。

已有同名 Release 或标签时工作流会停止，不覆盖附件或移动标签。上传失败可能留下草稿，应先检查现有状态再决定重试。正常草稿审核后直接发布，无需以相同标签重跑。工作流沿用 ad-hoc 签名，不包含 Apple 公证；本地打包不会创建标签、发布 Release 或修改仓库可见性。

## 许可证

二次开发与分发请遵循仓库的 [LICENSE](LICENSE)。
