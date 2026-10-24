//! keyDown/keyUp 配对与按住时长计算。纯逻辑，不依赖任何 macOS API，可单测。

use std::time::Instant;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeyKind {
    Down,
    Up,
}

impl KeyKind {
    pub fn as_int(self) -> i64 {
        match self {
            KeyKind::Down => 0,
            KeyKind::Up => 1,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            KeyKind::Down => "down",
            KeyKind::Up => "up",
        }
    }
}

/// 一次有效按键事件经过配对后的结果。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TrackedKey {
    pub kind: KeyKind,
    /// 重复 Fn down 不应落盘、广播或影响会话统计。
    pub accepted: bool,
    /// 仅 Up 且存在配对 Down 时有值。
    pub hold_ms: Option<u64>,
}

pub struct Tracker {
    down_at: [Option<Instant>; 256],
    /// 有效 keyDown 总数（autorepeat 已在采集层过滤）。
    pub key_count: u64,
}

impl Default for Tracker {
    fn default() -> Self {
        Self::new()
    }
}

impl Tracker {
    pub fn new() -> Self {
        Self {
            down_at: [None; 256],
            key_count: 0,
        }
    }

    /// down：计数 +1、记录 Instant；Fn 重复 down 保留首次时间，避免缩短语音时长。
    /// 其他按键槽位已有值则覆盖，防止丢 up 后计时错乱。
    /// up：有配对则算出 hold_ms 并清槽；孤儿 up 不影响任何状态。
    pub fn on_key(&mut self, keycode: i64, kind: KeyKind, at: Instant) -> TrackedKey {
        let slot = (0..256).contains(&keycode).then_some(keycode as usize);
        match kind {
            KeyKind::Down => {
                let duplicate_fn = keycode == 63 && self.down_at[63].is_some();
                if !duplicate_fn {
                    self.key_count += 1;
                    if let Some(i) = slot {
                        self.down_at[i] = Some(at);
                    }
                }
                TrackedKey {
                    kind,
                    accepted: !duplicate_fn,
                    hold_ms: None,
                }
            }
            KeyKind::Up => {
                let hold_ms = slot.and_then(|i| self.down_at[i].take()).map(|down| {
                    at.saturating_duration_since(down).as_millis() as u64
                });
                TrackedKey { kind, accepted: true, hold_ms }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn down_up_pair_computes_hold() {
        let mut t = Tracker::new();
        let t0 = Instant::now();
        let down = t.on_key(13, KeyKind::Down, t0);
        assert_eq!(down, TrackedKey { kind: KeyKind::Down, accepted: true, hold_ms: None });
        assert_eq!(t.key_count, 1);

        let up = t.on_key(13, KeyKind::Up, t0 + Duration::from_millis(120));
        assert_eq!(up, TrackedKey { kind: KeyKind::Up, accepted: true, hold_ms: Some(120) });
        assert_eq!(t.key_count, 1);
    }

    #[test]
    fn orphan_up_is_ignored() {
        let mut t = Tracker::new();
        let up = t.on_key(13, KeyKind::Up, Instant::now());
        assert_eq!(up, TrackedKey { kind: KeyKind::Up, accepted: true, hold_ms: None });
        assert_eq!(t.key_count, 0);
        // 孤儿 up 不清别人的槽位
        let t0 = Instant::now();
        t.on_key(1, KeyKind::Down, t0);
        let up1 = t.on_key(1, KeyKind::Up, t0 + Duration::from_millis(50));
        assert_eq!(up1.hold_ms, Some(50));
    }

    #[test]
    fn repeated_down_overwrites_slot() {
        let mut t = Tracker::new();
        let t0 = Instant::now();
        t.on_key(13, KeyKind::Down, t0);
        t.on_key(13, KeyKind::Down, t0 + Duration::from_millis(30));
        assert_eq!(t.key_count, 2);
        let up = t.on_key(13, KeyKind::Up, t0 + Duration::from_millis(80));
        // 以第二次 down 为准：80 - 30 = 50
        assert_eq!(up.hold_ms, Some(50));
        // 槽位已清，再 up 是孤儿
        let up2 = t.on_key(13, KeyKind::Up, t0 + Duration::from_millis(90));
        assert_eq!(up2.hold_ms, None);
    }

    #[test]
    fn repeated_fn_down_keeps_original_hold_start() {
        let mut t = Tracker::new();
        let t0 = Instant::now();
        assert!(t.on_key(63, KeyKind::Down, t0).accepted);
        assert!(!t.on_key(63, KeyKind::Down, t0 + Duration::from_millis(600)).accepted);
        assert_eq!(t.key_count, 1);
        let up = t.on_key(63, KeyKind::Up, t0 + Duration::from_millis(1_000));
        assert_eq!(up.hold_ms, Some(1_000));
        assert_eq!(t.on_key(63, KeyKind::Up, t0 + Duration::from_millis(1_100)).hold_ms, None);

        assert!(t.on_key(63, KeyKind::Down, t0 + Duration::from_millis(1_200)).accepted);
        assert_eq!(t.on_key(63, KeyKind::Up, t0 + Duration::from_millis(1_500)).hold_ms, Some(300));
        assert_eq!(t.key_count, 2);
    }

    #[test]
    fn out_of_range_keycode_still_counts_but_never_pairs() {
        let mut t = Tracker::new();
        let t0 = Instant::now();
        let d = t.on_key(300, KeyKind::Down, t0);
        assert_eq!(d.hold_ms, None);
        assert_eq!(t.key_count, 1);
        let u = t.on_key(300, KeyKind::Up, t0 + Duration::from_millis(10));
        assert_eq!(u.hold_ms, None);
        let neg = t.on_key(-1, KeyKind::Down, t0);
        assert_eq!(neg.hold_ms, None);
        assert_eq!(t.key_count, 2);
    }
}
