# Toccata IPC 协议与数据契约

本文档是 toccata-core / toccata-overlay / toccata-studio 三个模块之间的唯一契约。

## 1. 路径约定（macOS）

| 用途 | 路径 |
|---|---|
| 数据目录 | `~/Library/Application Support/Toccata/` |
| SQLite 数据库 | `~/Library/Application Support/Toccata/toccata.db` |
| Unix socket | `~/Library/Application Support/Toccata/toccata.sock` |
| daemon 配置 | `~/Library/Application Support/Toccata/config.json` |
| 布局覆盖目录 | `~/Library/Application Support/Toccata/layouts/*.json` |
| 主题覆盖目录 | `~/Library/Application Support/Toccata/themes/*.json` |

## 2. Unix socket 实时协议（JSON Lines）

传输：Unix domain stream socket，每条消息为一行 JSON（`\n` 结尾，UTF-8）。

### 客户端 → daemon

```json
{"cmd":"subscribe"}
```

连接后发送一次即完成订阅。当前版本无其他指令。

### daemon → 客户端

订阅成功立即回复：

```json
{"type":"hello","version":1}
```

之后每次有效键盘事件广播（autorepeat 已被 daemon 过滤，客户端收到的 down 一定是真实按下）：

```json
{"type":"key","keycode":13,"kind":"down","ts":1760054400123,"app":"com.apple.Terminal"}
{"type":"key","keycode":13,"kind":"up","ts":1760054400210,"app":"com.apple.Terminal"}
```

字段：`keycode` = CGKeyCode (u16)；`kind` = `down`/`up`；`ts` = Unix epoch 毫秒；`app` = 事件发生时前台 App 的 bundle id（可能为 `null`）。

无客户端连接时 daemon 广播路径零开销（空集合遍历）。

## 3. SQLite schema

WAL 模式。toccata-core 是唯一写方；overlay / studio 以**只读**方式直连（WAL 下读写并发安全）。

```sql
CREATE TABLE IF NOT EXISTS key_events (
  ts_ms     INTEGER NOT NULL,   -- Unix epoch 毫秒
  keycode   INTEGER NOT NULL,   -- CGKeyCode
  kind      INTEGER NOT NULL,   -- 0 = down, 1 = up
  hold_ms   INTEGER,            -- 仅 up 行：本次按住时长（毫秒）
  app       TEXT                -- 前台 app bundle id，可为 NULL
);
CREATE INDEX IF NOT EXISTS idx_key_events_ts ON key_events(ts_ms);

CREATE TABLE IF NOT EXISTS app_sessions (
  app        TEXT NOT NULL,     -- bundle id
  start_ms   INTEGER NOT NULL,
  end_ms     INTEGER NOT NULL,  -- 已含 trailing grace
  key_count  INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_app_sessions_start ON app_sessions(start_ms);
```

### 常用查询（studio / overlay 可直接复用）

```sql
-- 24 小时分布（本地时区）
SELECT CAST(strftime('%H', ts_ms/1000, 'unixepoch', 'localtime') AS INTEGER) AS hour,
       COUNT(*)
FROM key_events
WHERE kind = 0 AND ts_ms >= :start_ms AND ts_ms < :end_ms
GROUP BY hour;

-- 每日总按键（日历热力图）
SELECT date(ts_ms/1000, 'unixepoch', 'localtime') AS day, COUNT(*)
FROM key_events
WHERE kind = 0
GROUP BY day;

-- 按键排行
SELECT keycode, COUNT(*) AS n
FROM key_events
WHERE kind = 0
GROUP BY keycode
ORDER BY n DESC
LIMIT :limit;

-- 累计按住时长
SELECT SUM(hold_ms) FROM key_events
WHERE kind = 1 AND ts_ms >= :start_ms AND ts_ms < :end_ms;

-- 输入验证的每 App 使用时长
SELECT app, SUM(end_ms - start_ms) AS used_ms, SUM(key_count) AS keys
FROM app_sessions
WHERE start_ms >= :start_ms
GROUP BY app
ORDER BY used_ms DESC;

-- overlay 热力图：每键累计次数
SELECT keycode, COUNT(*) FROM key_events WHERE kind = 0 GROUP BY keycode;
```

## 4. daemon 配置（config.json）

全部字段可选，缺省用默认值：

```json
{
  "idle_gap_secs": 60,
  "trailing_grace_secs": 5,
  "flush_interval_secs": 10,
  "flush_batch_size": 500,
  "db_path": null,
  "socket_path": null
}
```

`db_path` / `socket_path` 为 null 时用上文默认路径。
