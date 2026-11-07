//! 采集策略：暂停、按应用脱敏或排除、安全输入。纯逻辑，不依赖 macOS API，可单测。
//!
//! 文件由 Studio 写入，服务只读。文件存在但无法解析时一律暂停采集：
//! 不能因为一份坏文件，把用户排除过的应用重新记录下来。

use crate::tracker::KeyKind;
use serde::Deserialize;
use std::collections::HashMap;
use std::path::PathBuf;
use std::time::SystemTime;

/// 脱敏事件写入的键码。真实键码只留在内存中用于按住配对。
pub const REDACTED_KEYCODE: i64 = -1;

const POLICY_VERSION: u32 = 1;

/// 密码管理器默认不记录。策略文件可用 "record" 覆盖。
const DEFAULT_IGNORED_APPS: [&str; 9] = [
    "com.1password.1password",
    "com.agilebits.onepassword7",
    "com.apple.Passwords",
    "com.apple.keychainaccess",
    "com.bitwarden.desktop",
    "com.dashlane.dashlanephonefinal",
    "com.lastpass.LastPass",
    "org.keepassxc.keepassxc",
    "in.sinew.Enpass-Desktop",
];

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AppMode {
    Record,
    Redact,
    Ignore,
}

#[derive(Debug, Deserialize)]
struct PolicyDocument {
    version: u32,
    #[serde(default)]
    paused_until_ms: Option<i64>,
    #[serde(default)]
    apps: HashMap<String, AppMode>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CapturePolicy {
    paused_until_ms: Option<i64>,
    apps: HashMap<String, AppMode>,
}

impl Default for CapturePolicy {
    fn default() -> Self {
        Self {
            paused_until_ms: None,
            apps: DEFAULT_IGNORED_APPS
                .iter()
                .map(|app| ((*app).to_string(), AppMode::Ignore))
                .collect(),
        }
    }
}

impl CapturePolicy {
    pub fn parse(text: &str) -> Result<Self, String> {
        let document: PolicyDocument = serde_json::from_str(text).map_err(|e| e.to_string())?;
        if document.version != POLICY_VERSION {
            return Err(format!("不支持的策略版本 {}", document.version));
        }
        let mut policy = Self::default();
        policy.paused_until_ms = document.paused_until_ms;
        policy.apps.extend(document.apps);
        Ok(policy)
    }

    fn fail_closed() -> Self {
        Self {
            paused_until_ms: Some(i64::MAX),
            ..Self::default()
        }
    }

    pub fn decide(&self, app: Option<&str>, ts_ms: i64, secure_input: bool) -> AppMode {
        if secure_input || self.paused_until_ms.is_some_and(|until| ts_ms < until) {
            return AppMode::Ignore;
        }
        app.and_then(|app| self.apps.get(app).copied()).unwrap_or(AppMode::Record)
    }
}

/// 一次按键的按下和松开必须同一处理。否则从排除应用切走后才松开的键，
/// 会留下带按住时长的松开事件，把未记录的时段带回统计。
pub struct CaptureGate {
    policy: CapturePolicy,
    presses: HashMap<i64, AppMode>,
}

impl CaptureGate {
    pub fn new(policy: CapturePolicy) -> Self {
        Self { policy, presses: HashMap::new() }
    }

    pub fn set_policy(&mut self, policy: CapturePolicy) {
        self.policy = policy;
    }

    pub fn resolve(&mut self, keycode: i64, kind: KeyKind, app: Option<&str>, ts_ms: i64,
                   secure_input: bool) -> AppMode {
        let current = self.policy.decide(app, ts_ms, secure_input);
        match kind {
            KeyKind::Down => {
                self.presses.insert(keycode, current);
                current
            }
            KeyKind::Up => self.presses.remove(&keycode).unwrap_or(current),
        }
    }
}

pub struct PolicyFile {
    path: PathBuf,
    stamp: Option<(SystemTime, u64)>,
    loaded: bool,
}

impl PolicyFile {
    pub fn new(path: PathBuf) -> Self {
        Self { path, stamp: None, loaded: false }
    }

    /// 文件变化或 `force` 时重新读取；没有变化时返回 None。
    pub fn reload(&mut self, force: bool) -> Option<CapturePolicy> {
        let metadata = std::fs::metadata(&self.path);
        let stamp = metadata.as_ref().ok().and_then(|m| Some((m.modified().ok()?, m.len())));
        if !force && self.loaded && stamp == self.stamp {
            return None;
        }
        self.stamp = stamp;
        self.loaded = true;
        Some(self.read())
    }

    fn read(&self) -> CapturePolicy {
        match std::fs::read_to_string(&self.path) {
            Ok(text) => CapturePolicy::parse(&text).unwrap_or_else(|e| {
                eprintln!("[toccata-core] 采集策略 {:?} 无效（{e}），已暂停采集", self.path);
                CapturePolicy::fail_closed()
            }),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => CapturePolicy::default(),
            Err(e) => {
                eprintln!("[toccata-core] 无法读取采集策略 {:?}（{e}），已暂停采集", self.path);
                CapturePolicy::fail_closed()
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    fn policy(text: &str) -> CapturePolicy {
        CapturePolicy::parse(text).unwrap()
    }

    fn temporary_path() -> PathBuf {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        std::env::temp_dir().join(format!(
            "toccata-policy-{}-{}.json",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ))
    }

    #[test]
    fn password_managers_are_ignored_by_default_and_can_be_overridden() {
        assert_eq!(CapturePolicy::default().decide(Some("com.bitwarden.desktop"), 1, false), AppMode::Ignore);
        assert_eq!(CapturePolicy::default().decide(Some("com.apple.Terminal"), 1, false), AppMode::Record);
        assert_eq!(CapturePolicy::default().decide(None, 1, false), AppMode::Record);
        let custom = policy(r#"{"version":1,"apps":{"com.bitwarden.desktop":"record","com.apple.Terminal":"redact"}}"#);
        assert_eq!(custom.decide(Some("com.bitwarden.desktop"), 1, false), AppMode::Record);
        assert_eq!(custom.decide(Some("com.apple.Terminal"), 1, false), AppMode::Redact);
        assert_eq!(custom.decide(Some("com.apple.keychainaccess"), 1, false), AppMode::Ignore,
                   "a custom rule must not drop the remaining defaults");
    }

    #[test]
    fn pause_ends_at_its_deadline() {
        let paused = policy(r#"{"version":1,"paused_until_ms":1000}"#);
        assert_eq!(paused.decide(Some("a"), 999, false), AppMode::Ignore);
        assert_eq!(paused.decide(Some("a"), 1000, false), AppMode::Record);
    }

    #[test]
    fn secure_input_overrides_every_rule() {
        let custom = policy(r#"{"version":1,"apps":{"a":"record"}}"#);
        assert_eq!(custom.decide(Some("a"), 1, true), AppMode::Ignore);
    }

    #[test]
    fn unknown_modes_and_versions_are_rejected() {
        assert!(CapturePolicy::parse(r#"{"version":1,"apps":{"a":"maybe"}}"#).is_err());
        assert!(CapturePolicy::parse(r#"{"version":2}"#).is_err());
        assert!(CapturePolicy::parse("not json").is_err());
    }

    #[test]
    fn release_follows_the_decision_made_at_press() {
        let mut gate = CaptureGate::new(policy(r#"{"version":1,"apps":{"secret":"ignore","term":"redact"}}"#));
        assert_eq!(gate.resolve(13, KeyKind::Down, Some("secret"), 1, false), AppMode::Ignore);
        assert_eq!(gate.resolve(13, KeyKind::Up, Some("other"), 2, false), AppMode::Ignore);
        assert_eq!(gate.resolve(13, KeyKind::Down, Some("other"), 3, false), AppMode::Record);
        assert_eq!(gate.resolve(13, KeyKind::Up, Some("term"), 4, false), AppMode::Record);
        assert_eq!(gate.resolve(13, KeyKind::Down, Some("term"), 5, false), AppMode::Redact);
        assert_eq!(gate.resolve(13, KeyKind::Up, Some("other"), 6, false), AppMode::Redact);
    }

    #[test]
    fn orphan_release_uses_the_current_decision() {
        let mut gate = CaptureGate::new(policy(r#"{"version":1,"apps":{"secret":"ignore"}}"#));
        assert_eq!(gate.resolve(13, KeyKind::Up, Some("secret"), 1, false), AppMode::Ignore);
        assert_eq!(gate.resolve(13, KeyKind::Up, Some("other"), 2, false), AppMode::Record);
    }

    #[test]
    fn missing_file_uses_defaults_and_invalid_file_pauses_capture() {
        let path = temporary_path();
        let mut file = PolicyFile::new(path.clone());
        assert_eq!(file.reload(false), Some(CapturePolicy::default()));
        assert_eq!(file.reload(false), None, "an unchanged state must not be reloaded");

        std::fs::write(&path, "{broken").unwrap();
        let invalid = file.reload(false).unwrap();
        assert_eq!(invalid.decide(Some("a"), i64::MAX - 1, false), AppMode::Ignore);

        std::fs::write(&path, r#"{"version":1,"apps":{"a":"redact"}}"#).unwrap();
        let restored = file.reload(true).unwrap();
        assert_eq!(restored.decide(Some("a"), 1, false), AppMode::Redact);
        std::fs::remove_file(&path).unwrap();
    }
}
