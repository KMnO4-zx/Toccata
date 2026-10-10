//! idle-gap 真实使用时间会话状态机。纯逻辑，可单测。
//!
//! 规则：相邻有效输入事件间隔 < idle_gap 属同一会话；≥ gap 结算旧会话。
//! 会话内前台 app 变化时按切换点切成两段。结算时 end_ms = 最后事件时间 + trailing_grace。

pub const UNKNOWN_APP: &str = "(unknown)";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SettledSession {
    pub app: String,
    pub start_ms: i64,
    pub end_ms: i64,
    pub key_count: u64,
}

#[derive(Debug, Clone)]
struct Segment {
    app: String,
    start_ms: i64,
    last_ms: i64,
    key_count: u64,
}

impl Segment {
    fn settle(&self, grace_ms: i64) -> SettledSession {
        SettledSession {
            app: self.app.clone(),
            start_ms: self.start_ms,
            end_ms: self.last_ms + grace_ms,
            key_count: self.key_count,
        }
    }
}

pub struct SessionTracker {
    idle_gap_ms: i64,
    grace_ms: i64,
    current: Option<Segment>,
}

impl SessionTracker {
    pub fn new(idle_gap_secs: u64, trailing_grace_secs: u64) -> Self {
        Self {
            idle_gap_ms: (idle_gap_secs * 1000) as i64,
            grace_ms: (trailing_grace_secs * 1000) as i64,
            current: None,
        }
    }

    /// 每个有效输入事件调用一次。`counted` 表示该事件是否计为一次击键（keyDown）。
    /// 若该事件触发了旧会话/旧段的结算，返回结算结果。
    pub fn on_event(&mut self, ts_ms: i64, app: Option<&str>, counted: bool) -> Option<SettledSession> {
        let app = app.unwrap_or(UNKNOWN_APP).to_string();
        let add = u64::from(counted);

        match &mut self.current {
            None => {
                self.current = Some(Segment {
                    app,
                    start_ms: ts_ms,
                    last_ms: ts_ms,
                    key_count: add,
                });
                None
            }
            Some(seg) => {
                let gap = ts_ms - seg.last_ms;
                if gap >= self.idle_gap_ms {
                    // 空闲超时：结算旧会话，开启全新会话
                    let settled = seg.settle(self.grace_ms);
                    self.current = Some(Segment {
                        app,
                        start_ms: ts_ms,
                        last_ms: ts_ms,
                        key_count: add,
                    });
                    Some(settled)
                } else if seg.app != app {
                    // 同一会话内 app 切换：按切换点切段。
                    // 旧段结束于自身最后事件 + grace，新段从切换事件开始。
                    let settled = seg.settle(self.grace_ms);
                    self.current = Some(Segment {
                        app,
                        start_ms: ts_ms,
                        last_ms: ts_ms,
                        key_count: add,
                    });
                    Some(settled)
                } else {
                    seg.last_ms = ts_ms;
                    seg.key_count += add;
                    None
                }
            }
        }
    }

    /// 退出前结算未关闭的会话。
    pub fn flush(&mut self) -> Option<SettledSession> {
        self.current.take().map(|seg| seg.settle(self.grace_ms))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tracker() -> SessionTracker {
        SessionTracker::new(60, 5) // gap=60s, grace=5s
    }

    #[test]
    fn events_within_gap_stay_in_one_session() {
        let mut s = tracker();
        assert_eq!(s.on_event(0, Some("a"), true), None);
        assert_eq!(s.on_event(10_000, Some("a"), true), None);
        assert_eq!(s.on_event(20_000, Some("a"), false), None);
        let settled = s.flush().expect("open session");
        assert_eq!(settled.app, "a");
        assert_eq!(settled.start_ms, 0);
        assert_eq!(settled.end_ms, 20_000 + 5_000); // 最后事件 + grace
        assert_eq!(settled.key_count, 2); // 只有 down 计数
    }

    #[test]
    fn idle_gap_settles_previous_session() {
        let mut s = tracker();
        s.on_event(0, Some("a"), true);
        s.on_event(10_000, Some("a"), true);
        // 距上次 70s >= 60s：结算旧会话
        let settled = s.on_event(80_000, Some("a"), true).expect("settled");
        assert_eq!(
            settled,
            SettledSession { app: "a".into(), start_ms: 0, end_ms: 15_000, key_count: 2 }
        );
        // 边界：恰好等于 gap 也算新会话
        let settled2 = s.on_event(140_000, Some("a"), true).expect("settled at exact gap");
        assert_eq!(settled2.start_ms, 80_000);
        assert_eq!(settled2.key_count, 1);
    }

    #[test]
    fn app_switch_splits_segment_at_switch_point() {
        let mut s = tracker();
        s.on_event(0, Some("com.a", ), true);
        s.on_event(10_000, Some("com.a"), true);
        // 切到 com.b：旧段立即结算，end = 旧段最后事件 10s + grace 5s
        let settled = s.on_event(20_000, Some("com.b"), true).expect("split");
        assert_eq!(
            settled,
            SettledSession { app: "com.a".into(), start_ms: 0, end_ms: 15_000, key_count: 2 }
        );
        s.on_event(30_000, Some("com.b"), true);
        let tail = s.flush().expect("open");
        assert_eq!(tail.app, "com.b");
        assert_eq!(tail.start_ms, 20_000); // 新段从切换点开始
        assert_eq!(tail.end_ms, 35_000);
        assert_eq!(tail.key_count, 2);
    }

    #[test]
    fn none_app_maps_to_unknown() {
        let mut s = tracker();
        s.on_event(0, None, true);
        // None -> "(unknown)"，与显式 "(unknown)" 视为同一 app，不切段
        assert_eq!(s.on_event(1_000, Some(UNKNOWN_APP), true), None);
        let settled = s.flush().expect("open");
        assert_eq!(settled.app, UNKNOWN_APP);
        assert_eq!(settled.key_count, 2);
    }

    #[test]
    fn flush_on_empty_is_none() {
        let mut s = tracker();
        assert_eq!(s.flush(), None);
    }

    #[test]
    fn grace_is_appended_to_last_event_time() {
        let mut s = SessionTracker::new(60, 7);
        s.on_event(1_000, Some("a"), true);
        s.on_event(2_500, Some("a"), true);
        let settled = s.flush().expect("open");
        assert_eq!(settled.end_ms, 2_500 + 7_000);
    }
}
