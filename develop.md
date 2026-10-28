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

### 生成 README 演示图

```bash
./scripts/render-demo.sh
```

脚本单独编译带 `TOCCATA_DEMO` 标记的演示版本，复用工作台、菜单栏任务列表、键盘热力图与活跃时间线的真实界面组件，生成两张 2 倍分辨率 PNG：

- `images/todo-management.png`：左侧工作台展示任务、子任务和 Markdown 详情，右侧展示菜单栏小窗。
- `images/keyboard-activity.png`：展示最近 7 天的统计概览、逐键热力图与完整活跃时间线。

演示数据使用虚构任务及按当前日期生成的键盘事件，放在每次运行新建的临时目录中，导出后删除。演示版本使用独立的应用标识 `com.toccata.demo`，不启动采集服务，不读取或修改日常任务、键盘记录和偏好，也不申请输入监控或屏幕录制权限。图片由原生视图离屏导出；侧栏使用相同内容的不透明容器，以兼容导出。正常构建不包含演示入口及示例数据。可给脚本传入其他输出目录，已有同名图片会被覆盖。

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

## 按键次数与活跃时间计算

统计基于 `key_events` 中的原始键盘事件。`kind = 0` 表示按下（`down`），`kind = 1` 表示松开（`up`）；`ts_ms` 为 Unix epoch 毫秒时间，配对成功的松开事件还保存按住毫秒数 `hold_ms`。按住时长由服务使用单调时钟计算，当前统计不依赖旧的 `app_sessions` 会话表。

### 按键次数

- 每次有效按下计 **1 次**，松开不增加次数。系统因长按产生的 autorepeat 事件在采集层过滤，所以按住一个键连续输出多个字符，仍只计一次按下。
- 字母、数字、空格、修饰键及 Fn 都参与计数，左右修饰键分别记录。从全部松开的状态按一次 `Command + C`，Command 与 C 各计一次，共 **2 次**。按键次数不等于输入字符数。
- F1–F12、Caps Lock 和 Lock 通过 HID 补充采集；HID 可用时抑制普通监听中的重复事件。亮度、媒体等顶部功能归一化到对应 F 键；Caps Lock 开启与关闭各计一次物理点击。Lock 归一化为键码 `127`，按下即生成一对 down/up，不把锁屏时间计作长按。
- Fn 已处于按住状态时，重复 `down` 被忽略，不重复计数，也不重置首次按下时间。
- 次数按 **按下时刻** 归属日期和时间格。键盘概览及应用排行仅计入选定区间内的按下事件，采用左闭右开的时间边界 `[开始时间, 结束时间)`，上限不超过当前时刻。跨午夜长按的次数归按下当天，时长则按实际覆盖区间拆分。

不同视图的去重范围如下，二次开发时需注意这些区别：

| 视图 | 计数与去重方式 |
|---|---|
| 键盘概览、逐键热度、15 分钟时间线 | 合并已落盘事件与当前有效连接中的实时事件，以 `(ts_ms, keycode, kind)` 去重；同一次按下在落盘后不会再计一次 |
| 应用排行 | 只读取已落盘且 `app` 非空的事件，按 `(app, ts_ms, keycode, kind, hold_ms)` 去重，再按应用统计范围内的按下次数 |
| 活跃日历 | 按本地日期统计原始 `kind = 0` 行数，保留历史计数方式，不对数据库中的重复行去重 |

采集层已过滤正常的长按重复输入；如果历史库或导入数据本身包含重复行，活跃日历与键盘概览的次数可能不同。实时键帽动画和 `+1` 气泡只负责展示，不额外写入事件或增加次数。

### 活跃时长

活跃时长采用**短窗口与实际按住区间求并集**的方式，默认短窗口为 **5 秒**，可通过 `config.json` 中的 `activity_window_secs` 调整。

1. 每个有效按下在时刻 `t` 生成区间 `[t, t + 5 秒)`。
2. 配对的松开事件在时刻 `u` 提供实际按住区间 `[u - hold_ms, u)`。松开本身不再追加一个 5 秒窗口；没有配对时长的孤立松开事件不贡献时长。
3. 合并所有重叠或首尾相接的区间。多个键同时按住、组合键及连续输入的重叠时间只计算一次，未被任何区间覆盖的停顿不计入。
4. 将区间裁剪到所选日期范围和当前时刻，再汇总到自然日与 15 分钟时间格。刚按下 2 秒时最多先计 2 秒，不提前计入未来的 3 秒。

因此，短按一次在窗口结束后计入 5 秒；长按 12 秒计入 12 秒，松开后不会变成 17 秒。

以下例子均使用默认 5 秒窗口，在全部按键松开且短窗口结束后查看，所选范围覆盖完整活动：

| 输入情况 | 按键次数 | 活跃时长 |
|---|---|---|
| 短按一次 | 1 次 | 5 秒 |
| 第 0 秒、第 3 秒各短按一次 | 2 次 | 8 秒，两个窗口合并为 `[0, 8)` |
| 第 0 秒、第 40 秒各短按一次 | 2 次 | 10 秒，中间 35 秒停顿不计入 |
| 第 0～20 秒每秒短按一次，包含首尾 | 21 次 | 25 秒，窗口连续覆盖 `[0, 25)` |
| 持续按住一个普通键 12 秒 | 1 次 | 12 秒，系统重复输入不增加次数 |
| 同时按住两个键 12 秒后同时松开 | 2 次 | 12 秒，重叠时长只计算一次 |
| 只按住 Fn 2 秒后松开 | 1 次 | 5 秒；单独显示的 Fn 按住时长为 2 秒 |

日期按本机日历和时区计算，“本周”从周一零点开始，“最近 7 天”包含今天和之前六个自然日，自定义范围包含首尾日期。跨日区间按实际覆盖时间分配：例如 23:59:58 短按一次，5 秒窗口会给前一天分配 2 秒、后一天分配 3 秒，按键次数只记在前一天。夏令时切换按实际经过时长处理，不假定每天固定为 24 小时。

### Fn 按住时长

Fn（键码 `63`）的实际按住区间单独合并、裁剪和汇总，**不添加 5 秒窗口**。Fn 同时参与总按键次数和全局活跃时长，因此不能把 Fn 时长再加到全局活跃时长上。

界面用 Fn 累计按住时长估算语音输出时间，其中也可能包含 Fn 快捷键操作；Toccata 不检测麦克风录音。全局活跃时长也是基于键盘事件的估算，阅读、看视频和仅使用鼠标的时间可能没有覆盖。

### 实时、历史与应用统计

- **实时长按**：当前连接中实际观察到的按下，可在尚未松开时持续累计到当前时刻。断开连接后停止使用该连接的实时事件；历史库里没有配对松开记录的孤立按下只保留短窗口，不无限累加。
- **跨范围读取**：查询会考虑范围开始前一个窗口内的按下，以及范围结束后、当前时刻以前补到的松开事件，恢复跨边界的按住区间，再裁剪到选定范围。不能只读取范围内的行后直接累加 `hold_ms`。
- **应用排行**：使用同样的短窗口与按住区间规则，按事件记录的 `app` 分别求并集。尚未松开的长按在配对落盘后补全；不同应用的窗口可能重叠，各应用时长之和可能超过全局活跃时长。
- **缓存与分享**：历史日缓存保留相同计算规则，新增跨日松开事件会使相关日期重新计算；当天及受实时事件影响的日期继续现算。分享图的各区块统一使用一份已提交的数据库快照，不包含尚未落盘的实时事件。

计算实现见 [ActivityModels.swift](apps/toccata-studio/Sources/ActivityModels.swift)、[StatsRepository.swift](apps/toccata-studio/Sources/StatsRepository.swift) 与 [DailyStatisticsCache.swift](apps/toccata-studio/Sources/DailyStatisticsCache.swift)；协议与数据库字段见 [shared/protocol.md](shared/protocol.md)。现有边界用例位于 `ActivityTests.swift`、`StatsRepositoryTests.swift` 和 `DailyStatisticsCacheTests.swift`。

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

修改统计规则时，参照上文“按键次数与活跃时间计算”，同步检查历史查询、实时事件、应用排行、按天缓存与分享快照，并补充相应边界用例。

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
