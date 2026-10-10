# Toccata

macOS 键盘监控器 — 名字取自「触键曲」（toccata，词根 toccare = 触碰）。

Rust daemon 常驻后台做键盘采集与统计，Swift 侧提供两个按需启动的 App：悬浮键盘（toccata-overlay）与可视化界面（toccata-studio）。

```
┌──────────────────────────────────────────────────┐
│ toccata-core (Rust daemon, 常驻)                  │
│  CGEventTap(ListenOnly) ──→ 配对计时 / idle-gap   │
│         │                      │                 │
│    SQLite (WAL, 批量写)    Unix socket 广播       │
└──────────│─────────────────────│─────────────────┘
           │ 只读直连             │ JSON Lines 订阅
   ┌───────┴─────────┐   ┌───────┴─────────┐
   │ toccata-studio  │   │ toccata-overlay │
   │ Swift Charts    │   │ NSPanel 悬浮键盘 │
   └─────────────────┘   └─────────────────┘
```

## 模块

| 模块 | 技术 | 说明 |
|---|---|---|
| `core/toccata-core` | Rust | 常驻 daemon：CGEventTap 采集、autorepeat 过滤、keyDown/keyUp 配对算按住时长、NSWorkspace 前台 App 归属、idle-gap「真实使用时间」、SQLite 批量写入、Unix socket 实时广播、tap 超时自动重启 |
| `apps/toccata-overlay` | Swift (AppKit) | 悬浮键盘：实时点亮按住中的键 / 按累计次数的热力图模式（log 归一化）、鼠标穿透不抢焦点、透明度调节 |
| `apps/toccata-studio` | SwiftUI + Charts | 可视化：24 小时柱状图、GitHub 风格日历热力图、按键/App 排行、输入验证使用时长 |
| `shared/` | JSON | 键盘布局与主题的唯一事实来源（可替换 = 换肤），IPC 与 DB 契约见 `shared/protocol.md` |

## 构建

```bash
# daemon
cargo build --release          # 产物 target/release/toccata-core

# 两个 App（各自目录下）
cd apps/toccata-overlay && swift build -c release
cd apps/toccata-studio  && swift build -c release
```

改完 `shared/` 下的布局/主题后运行 `scripts/sync-assets.sh` 同步进两个 App 的资源。

## 运行

**首次运行需要授权「输入监控」权限**（系统设置 → 隐私与安全性 → 输入监控）。daemon 无权限时会打印引导日志并每 5 秒自动重试，授权后无需重启即开始采集。

```bash
./target/release/toccata-core                                  # 前台跑（调试用）
./apps/toccata-overlay/.build/release/toccata-overlay          # 悬浮键盘
./apps/toccata-studio/.build/release/toccata-studio            # 可视化
```

开机常驻（LaunchAgent）：

```bash
sudo cp target/release/toccata-core /usr/local/bin/
cp scripts/com.toccata.core.plist ~/Library/LaunchAgents/
# 如安装路径不同，先改 plist 里的 ProgramArguments
launchctl load ~/Library/LaunchAgents/com.toccata.core.plist
```

## 数据与配置

全部在 `~/Library/Application Support/Toccata/` 下：

- `toccata.db` — SQLite（WAL），表结构与统计查询示例见 `shared/protocol.md`
- `toccata.sock` — 实时事件广播（JSON Lines，无客户端时零开销）
- `config.json` — daemon 配置（全部可选）：`idle_gap_secs`(60)、`trailing_grace_secs`(5)、`flush_interval_secs`(10)、`flush_batch_size`(500)、`db_path`、`socket_path`
- `layouts/` `themes/` — 放同名 JSON 即可覆盖内置布局/主题，不用重新编译

## 换肤

内置 `Light` / `Dark` 两套主题（overlay 状态栏菜单切换）。自定义：复制 `shared/theme/dark.json` 改名改色，丢进 `~/Library/Application Support/Toccata/themes/`。字段说明见 `shared/README.md`。

## 资源占用（实测）

| 指标 | 数值 |
|---|---|
| daemon 物理内存（footprint） | ≈ 2.2 MB |
| daemon ps RSS（含共享页口径） | ≈ 10.9 MB |
| 空闲 CPU | 0.0% |
| 无客户端时广播开销 | 空集合遍历，零 syscall |

事件回调只做微秒级内存操作后经 channel 交给 writer 线程，绝不阻塞系统事件流；落盘为每 10s 或满 500 条一次事务批量写入。

daemon 带单实例保护（`toccata.lock` 文件 flock）：重复启动第二个实例会立即退出并提示，避免多实例双写数据库。

## License

见 [LICENSE](LICENSE)。
