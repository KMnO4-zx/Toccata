# Toccata IPC 协议与数据契约

本文件约定 `toccata-core` 后台服务与 `toccata-studio` 工作台的数据边界。键盘数据库由后台服务独占写入；任务数据库由 Studio 独立读写。

## 1. 路径与配置优先级

默认数据目录为 `~/Library/Application Support/Toccata/`。进程环境中的非空 `TOCCATA_DATA_DIR` 可替换此目录；后台服务与 Studio 应设置相同值，建议使用绝对路径。

以下路径均相对于最终数据目录：

| 文件 | 用途 |
|---|---|
| `config.json` | 后台服务配置，Studio 也从此处读取路径和活跃计算参数 |
| `toccata.db` | 键盘统计 SQLite 数据库，受非空 `db_path` 配置覆盖 |
| `toccata.sock` | Unix socket，受非空 `socket_path` 配置覆盖 |
| `tasks.sqlite` | Studio 任务 SQLite 数据库 |
| `toccata.lock` | 后台服务的排他实例锁 |

`db_path` / `socket_path` 建议填写非空绝对路径；省略或设为 `null` 时使用默认文件。它们不改变任务库的位置。布局标签和日历主题从 Studio 资源包读取，见 [README.md](README.md)。

## 2. Unix socket（JSON Lines）

传输为 Unix domain stream socket。每条消息是一行 UTF-8 JSON，以 `\n` 结尾。

### 客户端 → 后台服务

```json
{"cmd":"subscribe"}
```

连接后发送一次完成订阅。第一条消息必须为此命令；当前版本没有写入任务或查询统计的 socket 命令。

### 后台服务 → 客户端

订阅成功后立即回复：

```json
{"type":"hello","version":1}
```

此后每次键盘事件广播：

```json
{"type":"key","keycode":13,"kind":"down","ts":1760054400123,"app":"com.apple.Terminal"}
{"type":"key","keycode":13,"kind":"up","ts":1760054400210,"app":"com.apple.Terminal"}
```

| 字段 | 含义 |
|---|---|
| `keycode` | macOS CGKeyCode |
| `kind` | `down` 或 `up` |
| `ts` | Unix epoch 毫秒 |
| `app` | 事件发生时前台应用的 bundle ID，可能为 `null` |

采集层过滤长按产生的 autorepeat `keyDown`，将修饰键的 `FlagsChanged` 转换为按下/松开事件。实时 `key` 消息可能先于数据库事务提交到达，其中没有 `hold_ms`。

有待写数据且事务成功提交后，再广播：

```json
{"type":"updated"}
```

`updated` 表示键盘数据库已有新提交，可重新查询；空缓冲和写入失败均不发送。Studio 同时通过定时读取兜底，并在重连时重新读取。客户端应容忍未知消息类型。

## 3. 键盘数据库：toccata.db

使用 SQLite WAL 模式。`toccata-core` 是唯一写入方，Studio 通过只读连接查询。已有表和历史数据继续保留。

```sql
CREATE TABLE IF NOT EXISTS key_events (
  ts_ms     INTEGER NOT NULL, -- Unix epoch 毫秒
  keycode   INTEGER NOT NULL, -- macOS CGKeyCode
  kind      INTEGER NOT NULL, -- 0 = down, 1 = up
  hold_ms   INTEGER,          -- 配对成功的 up 行保存按住毫秒数
  app       TEXT             -- 前台应用 bundle ID，可为 NULL
);
CREATE INDEX IF NOT EXISTS idx_key_events_ts ON key_events(ts_ms);

CREATE TABLE IF NOT EXISTS app_sessions (
  app        TEXT NOT NULL,
  start_ms   INTEGER NOT NULL,
  end_ms     INTEGER NOT NULL, -- 已含 trailing grace
  key_count  INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_app_sessions_start ON app_sessions(start_ms);
```

按住时间在服务进程内以单调时钟配对计算；孤立的 `up` 没有 `hold_ms`。Fn 的键码为 `63`，重复 `down` 保留首次按下时间。左右 Command、Shift、Option、Control 分别判定，避免另一侧仍按住时将松开误记为按下。

### 活跃时间口径

Studio 的新活跃页直接从 `key_events` 与实时事件重建区间：

1. 相邻事件间隔小于 `idle_gap_secs` 时归为连续活跃，最后一个事件后补 `trailing_grace_secs`，最多计算至当前时刻。
2. 配对的按住区间计入活跃时间；实时连接中观察到的持续按住区间可增长。断线后遗留的孤立按下事件不持续累加。
3. 合并重叠区间，按所选日期边界裁剪，再汇总到每 15 分钟的格子；跨午夜的按住时间分配到对应日期。
4. Fn 按住区间单独合并与裁剪，得到语音输出时间估算。

默认参数为 60 秒间隔、5 秒尾部宽限。全部日期按本地日历和时区计算；本周从周一开始，最近 7 天包含今天及之前六个自然日。统计只计算当前时刻以前的活动。

键盘活跃时间无法覆盖所有电脑使用行为：阅读、看视频、只用鼠标时可能缺少记录。Fn 时长也可能包含快捷键操作，服务没有录音检测。

`app_sessions` 保留供历史应用排行使用。正在进行的会话需要等到空闲切段、应用切换或正常退出才会结算，因而可能延迟；新活跃页不依赖此表。

### 查询示例

```sql
-- 原始事件，时间为半开区间；计算跨边界区间时需另读必要的边界外事件。
SELECT ts_ms, keycode, kind, hold_ms, app
FROM key_events
WHERE ts_ms >= :start_ms AND ts_ms < :end_ms
ORDER BY ts_ms, rowid;

-- 每日按键数（日历按本地时区分组）。
SELECT date(ts_ms / 1000, 'unixepoch', 'localtime') AS day, COUNT(*) AS keys
FROM key_events WHERE kind = 0
GROUP BY day;

-- Fn 已配对按住时间，按松开时间筛选的简单合计。
-- 跨日期精确分配使用上文的区间裁剪，不能直接用此合计代替。
SELECT COALESCE(SUM(hold_ms), 0)
FROM key_events
WHERE keycode = 63 AND kind = 1 AND ts_ms >= :start_ms AND ts_ms < :end_ms;
```

## 4. 任务数据库：tasks.sqlite

Studio 以读写方式打开独立的任务数据库，启用 WAL 和外键。所有变更使用事务，提交成功后才发布界面状态。键盘后台服务不读写该库，任务功能不要求采集服务在线。

```sql
CREATE TABLE IF NOT EXISTS tasks (
  id           TEXT PRIMARY KEY NOT NULL,
  parent_id    TEXT REFERENCES tasks(id) ON DELETE CASCADE,
  title        TEXT NOT NULL CHECK(length(trim(title)) > 0),
  details      TEXT NOT NULL DEFAULT '',
  planned_at   REAL,
  created_at   REAL NOT NULL,
  updated_at   REAL NOT NULL,
  completed_at REAL,
  priority     INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS task_parent ON tasks(parent_id);
CREATE INDEX IF NOT EXISTS task_completed ON tasks(completed_at);

-- 历史过程记录仅为兼容保留，不再提供独立界面或新增入口；新笔记使用 tasks.details 保存 Markdown。
CREATE TABLE IF NOT EXISTS task_progress (
  id         TEXT PRIMARY KEY NOT NULL,
  task_id    TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  text       TEXT NOT NULL CHECK(length(trim(text)) > 0),
  created_at REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS progress_task ON task_progress(task_id, created_at);
```

任务库中全部 `*_at` 字段使用 **Unix epoch 秒（REAL）**，与键盘库的整数毫秒不同。`id` 为 UUID 字符串；`parent_id = NULL` 表示顶层任务。当前界面支持一级子任务，存储层保留递归父子关系。

`priority` 对应任务旗标：`0` 无优先级、`1` 低、`2` 中、`3` 高，新任务默认使用 `0`。旧任务库打开时会在 `BEGIN IMMEDIATE` 事务中检查表结构，仅在缺少该列时执行 `ALTER TABLE tasks ADD COLUMN priority INTEGER NOT NULL DEFAULT 0`；原有任务保留，重复打开不会重复迁移。

### 任务状态语义

- 新任务默认 `planned_at = NULL`、`completed_at = NULL`。未指定日期的任务继续保留在收集箱；创建时间不产生“今天到期”的含义。
- `created_at` 在创建任务时写入，后续编辑、完成或恢复任务不改变它。菜单栏任务行不常驻显示创建时间副行，数据仍完整记录，时间视图使用此字段筛选；子任务有各自的创建时间。
- `planned_at` 是可选计划日期。任务进入完成回顾的依据是 `completed_at`，与创建时间、计划日期无关。
- 设置优先级只更新 `priority` 和 `updated_at`；普通标题、Markdown 详情及计划日期编辑不会覆盖优先级，也不会改变任务所属时间视图。
- 完成任务时写入当前真实时间。完成父任务会在同一事务中完成尚未完成的所有后代；已完成后代原有的完成时间保持不变。
- 恢复任务会清除该任务及其已完成祖先的完成时间，已完成后代保持原状态。新增未完成子任务也会恢复其已完成祖先。完成全部子任务不会自动完成父任务。
- 已完成任务继续保留，仍可查看与编辑 Markdown 详情；恢复后移出完成回顾。
- 删除任务会级联删除其后代。历史过程表中的关联记录沿用原有外键行为，但不再提供独立的过程记录界面或新增入口。

### 任务视图

工作台任务列表和菜单栏默认使用“本周任务”。三个选项是同一任务库上的视图，切换视图不会修改任务的日期或状态：

| 视图 | 包含的任务 |
|---|---|
| 收集箱 | 全部顶层任务，包含未完成和已完成任务；菜单栏可展开父任务下的子任务树 |
| 最近 7 天 | `created_at` 在本地日历六天前零点至当前时刻之间的任务，包含未完成和已完成任务 |
| 本周任务 | 本周创建的任务、周一以前创建且仍未完成的任务，以及本周完成的任务 |

本周从本地日历周一零点开始，区间包含起点和当前时刻；最近 7 天包含今天及之前六个自然日。视图排除 `created_at` 晚于当前时刻的任务。本周任务各条件取并集，同一任务只出现一次。最近 7 天和本周任务也独立列出符合条件的子任务，因此父任务创建得较早时仍能看到新子任务或本周完成的子任务。

菜单栏使用原生状态项（`NSStatusItem`）和 312 × 554 pt 的任务列表面板（`NSPanel`）。列表采用白底紧凑单行布局，不常驻显示创建时间副行。子任务缩进挂在父任务下，可折叠展开；已完成任务也保留父子层级。点击任务会在列表左侧打开独立的 400 × 300 pt 编辑浮窗，支持标题、以所见即所得方式编辑 Markdown 描述、计划日期及子任务；旗标可设置优先级，浮窗首次出现时轻快浮现，原任务列表不会变宽或消失。选中任务行后，Tab 将焦点移至浮窗的描述编辑；Enter 将焦点移至添加子任务。描述中的 Enter 保留换行含义。右键菜单或“更多操作”提供删除操作，删除前须确认，并提示子任务会联动删除。

列表底部提供任务、日历、设置三个图标。日历入口在面板内展开月历，可翻月、回到今天并查看或编辑当天任务；设置菜单包含打开工作台和退出应用。工作台仍提供完整任务详情。

### 任务月历

工作台提供月历，可按创建、计划、完成或全部事件查看。事件日期分别使用 `created_at`、非空 `planned_at`、非空 `completed_at`，按本地时区归入自然日；选择日期后显示对应任务并可编辑。同一任务在同一天符合多个事件时只显示一次，未设置计划日期的任务另列。

选择日期本身不会给新任务安排日期。常规新增继续写入 `planned_at = NULL`；只有用户明确按所选日期新建时，才写入该日期的计划时间。

### 完成回顾

回顾包含顶层任务和子任务，按真实完成日期分组，支持：

| 范围 | 起点 | 终点 |
|---|---|---|
| 本周 | 本地日历本周周一零点 | 当前时刻 |
| 最近7天 | 本地日历六天前零点 | 当前时刻 |

时间筛选包含起点和当前时刻，排除将来的完成时间。复制回顾包含当前筛选结果的任务名称、父任务名称、完成时间、详情与过程文本，可作为周报素材。

## 5. 后台服务配置

`config.json` 全部字段可省略：

```json
{
  "idle_gap_secs": 60,
  "trailing_grace_secs": 5,
  "flush_interval_secs": 2,
  "flush_batch_size": 500,
  "db_path": null,
  "socket_path": null
}
```

写入线程使用独立于键盘事件频率的固定周期截止时间：默认每 2 秒尝试落盘，缓冲条数达到 500 时也会落盘。`flush_interval_secs = 0` 按至少 1 秒处理，避免空闲忙循环。一次事务同时插入事件与已结算会话，提交成功后才清空缓冲；失败时保留整批数据供后续重试。正常退出前也会尝试结算与落盘。
