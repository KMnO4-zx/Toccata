//! SQLite 批量落盘。daemon 是唯一写方，WAL 模式供其他进程并发读。

use rusqlite::Connection;
use std::path::Path;

const SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS key_events (
  ts_ms INTEGER NOT NULL, keycode INTEGER NOT NULL, kind INTEGER NOT NULL,
  hold_ms INTEGER, app TEXT);
CREATE INDEX IF NOT EXISTS idx_key_events_ts ON key_events(ts_ms);
CREATE TABLE IF NOT EXISTS app_sessions (
  app TEXT NOT NULL, start_ms INTEGER NOT NULL, end_ms INTEGER NOT NULL, key_count INTEGER NOT NULL);
CREATE INDEX IF NOT EXISTS idx_app_sessions_start ON app_sessions(start_ms);
";

#[derive(Debug)]
pub struct KeyEventRow {
    pub ts_ms: i64,
    pub keycode: i64,
    pub kind: i64,
    pub hold_ms: Option<i64>,
    pub app: Option<String>,
}

#[derive(Debug)]
pub struct SessionRow {
    pub app: String,
    pub start_ms: i64,
    pub end_ms: i64,
    pub key_count: i64,
}

pub struct Store {
    conn: Connection,
    key_events: Vec<KeyEventRow>,
    sessions: Vec<SessionRow>,
    batch_size: usize,
}

impl Store {
    pub fn open(path: &Path, batch_size: usize) -> rusqlite::Result<Self> {
        let conn = Connection::open(path)?;
        conn.pragma_update(None, "journal_mode", "WAL")?;
        conn.pragma_update(None, "busy_timeout", 5000_i64)?;
        conn.pragma_update(None, "synchronous", "NORMAL")?;
        conn.execute_batch(SCHEMA)?;
        Ok(Self {
            conn,
            key_events: Vec::with_capacity(batch_size),
            sessions: Vec::new(),
            batch_size,
        })
    }

    /// 缓冲满 batch_size 时返回 true，调用方应立即 flush。
    pub fn push_key_event(&mut self, row: KeyEventRow) -> bool {
        self.key_events.push(row);
        self.key_events.len() >= self.batch_size
    }

    pub fn push_session(&mut self, row: SessionRow) -> bool {
        self.sessions.push(row);
        self.key_events.len() >= self.batch_size
    }

    pub fn pending(&self) -> usize {
        self.key_events.len() + self.sessions.len()
    }

    /// 一个事务批量插入 key_events + app_sessions。
    pub fn flush(&mut self) -> rusqlite::Result<()> {
        if self.key_events.is_empty() && self.sessions.is_empty() {
            return Ok(());
        }
        let tx = self.conn.transaction()?;
        {
            let mut stmt = tx.prepare_cached(
                "INSERT INTO key_events (ts_ms, keycode, kind, hold_ms, app) VALUES (?1, ?2, ?3, ?4, ?5)",
            )?;
            for row in &self.key_events {
                stmt.execute((row.ts_ms, row.keycode, row.kind, row.hold_ms, &row.app))?;
            }
        }
        {
            let mut stmt = tx.prepare_cached(
                "INSERT INTO app_sessions (app, start_ms, end_ms, key_count) VALUES (?1, ?2, ?3, ?4)",
            )?;
            for row in &self.sessions {
                stmt.execute((&row.app, row.start_ms, row.end_ms, row.key_count))?;
            }
        }
        tx.commit()?;
        // 只有提交成功才释放缓冲；任一插入或提交失败时，整个批次可原样重试。
        self.key_events.clear();
        self.sessions.clear();
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn failed_transaction_keeps_entire_batch_for_retry() {
        let mut store = Store::open(Path::new(":memory:"), 10).unwrap();
        store.push_key_event(KeyEventRow {
            ts_ms: 1_000,
            keycode: 63,
            kind: 1,
            hold_ms: Some(700),
            app: Some("test.app".into()),
        });
        store.push_session(SessionRow {
            app: "test.app".into(),
            start_ms: 300,
            end_ms: 1_000,
            key_count: 1,
        });
        // 在 key_events 插入之后使同一事务的 session 插入失败。
        store.conn.execute_batch(
            "CREATE TEMP TRIGGER fail_session BEFORE INSERT ON app_sessions
             BEGIN SELECT RAISE(ABORT, 'retry test'); END;",
        ).unwrap();

        assert!(store.flush().is_err());
        assert_eq!(store.pending(), 2);
        let count: i64 = store.conn.query_row("SELECT COUNT(*) FROM key_events", [], |r| r.get(0)).unwrap();
        assert_eq!(count, 0, "failed transaction must roll back key events too");

        store.conn.execute_batch("DROP TRIGGER fail_session;").unwrap();
        store.flush().unwrap();
        assert_eq!(store.pending(), 0);
        let counts: (i64, i64) = store.conn.query_row(
            "SELECT (SELECT COUNT(*) FROM key_events), (SELECT COUNT(*) FROM app_sessions)",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        ).unwrap();
        assert_eq!(counts, (1, 1));
        let hold_ms: i64 = store.conn.query_row("SELECT hold_ms FROM key_events", [], |r| r.get(0)).unwrap();
        assert_eq!(hold_ms, 700);
        store.flush().unwrap();
        let count: i64 = store.conn.query_row("SELECT COUNT(*) FROM key_events", [], |r| r.get(0)).unwrap();
        assert_eq!(count, 1, "retry must not duplicate committed events");
    }
}
