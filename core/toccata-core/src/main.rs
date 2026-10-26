//! toccata-core：键盘统计 daemon。
//!
//! 线程模型（无 tokio）：
//! - 主线程：CFRunLoop，CGEventTap 回调 + 1s timer（退出检查 & tap 看门狗）
//! - writer 线程：配对计时 / 会话状态机 / SQLite 批量落盘 / 广播（统一在此保证顺序）
//! - ipc-accept 线程 + 每客户端一个读线程：Unix socket 客户端管理
//! - 信号：signal-hook 置原子标志，主线程 timer 发现后优雅退出（退出前保证落盘）

mod config;
mod hid;
mod special_keys;
mod ipc;
mod session;
mod store;
mod tap;
mod tracker;

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};

use core_foundation::date::CFAbsoluteTimeGetCurrent;
use core_foundation::runloop::{kCFRunLoopCommonModes, CFRunLoop, CFRunLoopTimer, CFRunLoopTimerRef};

use config::Config;
use ipc::Broadcaster;
use session::SessionTracker;
use store::{KeyEventRow, SessionRow, Store};
use tap::RawKeyEvent;
use tracker::{KeyKind, Tracker};

enum WriterMsg {
    Event(RawKeyEvent),
    Capture(bool),
    Shutdown,
}

/// 独立于事件到达频率的周期时钟，持续输入也不能推迟落盘。
struct FlushSchedule {
    interval: Duration,
    next: Instant,
}

impl FlushSchedule {
    fn new(now: Instant, interval: Duration) -> Self {
        // 配置为 0 时仍保持有限等待，避免空闲时忙循环。
        let interval = interval.max(Duration::from_secs(1));
        Self { interval, next: now + interval }
    }

    fn remaining(&self, now: Instant) -> Duration {
        self.next.saturating_duration_since(now)
    }

    fn take_due(&mut self, now: Instant) -> bool {
        if now < self.next {
            return false;
        }
        // 保留原始周期锚点；唤醒延迟或机器休眠后跳过已错过的周期。
        while self.next <= now {
            self.next += self.interval;
        }
        true
    }
}

static SHUTDOWN: OnceLock<Arc<AtomicBool>> = OnceLock::new();
static TIMER_TICKS: AtomicU64 = AtomicU64::new(0);
static WRITER_READY: AtomicBool = AtomicBool::new(false);
static WRITER_SENDER: OnceLock<Sender<WriterMsg>> = OnceLock::new();

pub(crate) fn writer_ready() -> bool {
    WRITER_READY.load(Ordering::SeqCst)
}

fn is_shutdown() -> bool {
    SHUTDOWN
        .get()
        .map(|f| f.load(Ordering::SeqCst))
        .unwrap_or(false)
}

/// Studio suppresses system permission prompts during login/background startup.
/// Standalone CLI launches keep their existing prompt behavior unless opted out.
fn should_request_input_permission(value: Option<&str>) -> bool {
    value != Some("0")
}

/// 主线程 CFRunLoop 1s 周期 timer：检查退出标志；每 10s 检查 tap 并上报采集状态。
extern "C" fn runloop_tick(_timer: CFRunLoopTimerRef, _info: *mut std::ffi::c_void) {
    if is_shutdown() {
        CFRunLoop::get_current().stop();
        return;
    }
    let tick = TIMER_TICKS.fetch_add(1, Ordering::Relaxed) + 1;
    if tick % 10 == 0 {
        tap::watchdog_check();
        if let Some(sender) = WRITER_SENDER.get() {
            let _ = sender.send(WriterMsg::Capture(tap::capture_enabled()));
        }
    }
}

fn main() {
    let cfg = Config::load();
    let data_dir = Config::data_dir();
    if let Err(e) = std::fs::create_dir_all(&data_dir) {
        eprintln!("[toccata-core] 无法创建数据目录 {data_dir:?}: {e}");
        std::process::exit(1);
    }

    // 单实例锁：第二个实例直接退出，避免双写数据库（flock 在进程退出时自动释放）
    let _instance_lock = acquire_instance_lock(&data_dir);

    // IPC listener（失败不致命：daemon 仍能采集落盘，只是没有实时广播）
    let broadcaster = match ipc::start_listener(cfg.socket_path()) {
        Ok(b) => b,
        Err(e) => {
            eprintln!("[toccata-core] socket 监听失败（{:?}）: {e}，继续运行但不提供 IPC", cfg.socket_path());
            Broadcaster::empty()
        }
    };

    let (tx, rx) = mpsc::channel::<WriterMsg>();
    let _ = WRITER_SENDER.set(tx.clone());
    let writer_cfg = cfg.clone();
    let writer_broadcaster = broadcaster.clone();
    let writer = std::thread::Builder::new()
        .name("writer".into())
        .spawn(move || writer_main(rx, writer_cfg, writer_broadcaster))
        .expect("spawn writer thread");

    // 信号：SIGTERM/SIGINT 只置标志，由主线程 timer 统一处理退出
    let flag = Arc::new(AtomicBool::new(false));
    for sig in [signal_hook::consts::SIGTERM, signal_hook::consts::SIGINT] {
        if let Err(e) = signal_hook::flag::register(sig, Arc::clone(&flag)) {
            eprintln!("[toccata-core] 注册信号 {sig} 失败: {e}");
        }
    }
    let _ = SHUTDOWN.set(flag);

    // 权限检测 + tap 创建。无权限时每 5s 重试，进程保持存活，授权后自动开始采集。
    let request_permission = should_request_input_permission(
        std::env::var("TOCCATA_REQUEST_INPUT_PERMISSION").ok().as_deref(),
    );
    let mut reported_missing_permission = false;
    loop {
        if is_shutdown() {
            shutdown(tx, writer);
            return;
        }
        if tap::preflight() {
            match tap::create_tap(tx.clone()) {
                Ok(()) => {
                    eprintln!("[toccata-core] 键盘事件监听已启动");
                    break;
                }
                Err(()) => {
                    eprintln!("[toccata-core] 事件监听创建失败，5 秒后重试…");
                }
            }
        } else {
            if !reported_missing_permission {
                reported_missing_permission = true;
                if request_permission {
                    tap::request_access();
                }
                eprintln!("[toccata-core] 缺少「输入监控」权限，无法监听键盘。");
                eprintln!("[toccata-core] 请前往 系统设置 → 隐私与安全性 → 输入监控，勾选本程序（或运行它的终端）。");
                eprintln!("[toccata-core] 授权后无需重启，程序会自动开始采集；正在每 5 秒重试…");
            } else {
                eprintln!("[toccata-core] 等待「输入监控」权限授予中，5 秒后重试…");
            }
        }
        std::thread::sleep(Duration::from_secs(5));
    }

    // 1s 周期 timer：退出检查 + tap 看门狗（10s 间隔，回调内 enable 之外的第二道保险）
    let timer = CFRunLoopTimer::new(
        unsafe { CFAbsoluteTimeGetCurrent() } + 1.0,
        1.0,
        0,
        0,
        runloop_tick,
        std::ptr::null_mut(),
    );
    CFRunLoop::get_current().add_timer(&timer, unsafe { kCFRunLoopCommonModes });
    CFRunLoop::run_current();

    eprintln!("[toccata-core] 收到退出信号，正在落盘并退出…");
    shutdown(tx, writer);
}

fn shutdown(tx: Sender<WriterMsg>, writer: std::thread::JoinHandle<()>) {
    hid::stop();
    let _ = tx.send(WriterMsg::Shutdown);
    if writer.join().is_err() {
        eprintln!("[toccata-core] writer 线程异常退出");
    }
    eprintln!("[toccata-core] 已退出");
}

/// 对数据目录下的 toccata.lock 加排他 flock；已被持锁说明有实例在跑，直接退出。
/// 返回的 File 必须活到进程结束（fd 关闭即释放锁）。
fn acquire_instance_lock(data_dir: &std::path::Path) -> std::fs::File {
    use std::os::unix::io::AsRawFd;
    let path = data_dir.join("toccata.lock");
    let file = match std::fs::File::options().read(true).write(true).create(true).open(&path) {
        Ok(f) => f,
        Err(e) => {
            eprintln!("[toccata-core] 无法打开实例锁文件 {path:?}: {e}");
            std::process::exit(1);
        }
    };
    let rc = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
    if rc != 0 {
        eprintln!("[toccata-core] 已有另一个 toccata-core 实例在运行，本实例退出。");
        std::process::exit(1);
    }
    file
}

/// writer 线程主循环：所有事件在此统一处理（配对计时、会话、落盘缓冲、广播），保证顺序。
fn writer_main(rx: Receiver<WriterMsg>, cfg: Config, broadcaster: Broadcaster) {
    WRITER_READY.store(false, Ordering::SeqCst);
    let mut store = match Store::open(&cfg.db_path(), cfg.flush_batch_size) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("[toccata-core] 打开数据库 {:?} 失败: {e}", cfg.db_path());
            return;
        }
    };
    WRITER_READY.store(true, Ordering::SeqCst);
    let mut tracker = Tracker::new();
    let mut sessions = SessionTracker::new(cfg.idle_gap_secs, cfg.trailing_grace_secs);
    let mut flush_schedule = FlushSchedule::new(
        Instant::now(),
        Duration::from_secs(cfg.flush_interval_secs),
    );

    loop {
        match rx.recv_timeout(flush_schedule.remaining(Instant::now())) {
            Ok(WriterMsg::Event(ev)) => {
                handle_event(&ev, &mut tracker, &mut sessions, &mut store, &broadcaster);
                if store.pending() >= cfg.flush_batch_size {
                    flush_store(&mut store, &broadcaster);
                }
            }
            Ok(WriterMsg::Capture(active)) => {
                let line = capture_json(active, writer_ready(), tap::permission_required());
                broadcaster.broadcast(&line);
            }
            Ok(WriterMsg::Shutdown) => {
                settle_open_session(&mut sessions, &mut store);
                flush_store(&mut store, &broadcaster);
                return;
            }
            Err(RecvTimeoutError::Timeout) => {},
            Err(RecvTimeoutError::Disconnected) => {
                settle_open_session(&mut sessions, &mut store);
                flush_store(&mut store, &broadcaster);
                return;
            }
        }
        if flush_schedule.take_due(Instant::now()) {
            flush_store(&mut store, &broadcaster);
        }
    }
}

fn capture_json(capture_active: bool, ready: bool, permission_required: bool) -> String {
    serde_json::json!({
        "type": "capture",
        "enabled": capture_active && ready,
        "permission_required": permission_required,
    })
    .to_string()
}

fn handle_event(
    ev: &RawKeyEvent,
    tracker: &mut Tracker,
    sessions: &mut SessionTracker,
    store: &mut Store,
    broadcaster: &Broadcaster,
) {
    let tracked = tracker.on_key(ev.keycode, ev.kind, ev.at);
    if !tracked.accepted {
        return;
    }
    store.push_key_event(KeyEventRow {
        ts_ms: ev.ts_ms,
        keycode: ev.keycode,
        kind: ev.kind.as_int(),
        hold_ms: tracked.hold_ms.map(|v| v as i64),
        app: ev.app.clone(),
    });
    let line = serde_json::json!({
        "type": "key",
        "keycode": ev.keycode,
        "kind": ev.kind.as_str(),
        "ts": ev.ts_ms,
        "app": ev.app,
    });
    broadcaster.broadcast(&line.to_string());
    if let Some(settled) = sessions.on_event(ev.ts_ms, ev.app.as_deref(), ev.kind == KeyKind::Down) {
        store.push_session(SessionRow {
            app: settled.app,
            start_ms: settled.start_ms,
            end_ms: settled.end_ms,
            key_count: settled.key_count as i64,
        });
    }
}

fn settle_open_session(sessions: &mut SessionTracker, store: &mut Store) {
    if let Some(settled) = sessions.flush() {
        store.push_session(SessionRow {
            app: settled.app,
            start_ms: settled.start_ms,
            end_ms: settled.end_ms,
            key_count: settled.key_count as i64,
        });
    }
}

fn flush_store(store: &mut Store, broadcaster: &Broadcaster) {
    if store.pending() > 0 {
        match store.flush() {
            Ok(()) => broadcaster.broadcast(r#"{"type":"updated"}"#),
            Err(e) => eprintln!("[toccata-core] 数据库写入失败: {e}"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn background_permission_policy_preserves_standalone_cli_behavior() {
        assert!(!should_request_input_permission(Some("0")),
                "a background Studio launch must not request system permission");
        assert!(should_request_input_permission(Some("1")));
        assert!(should_request_input_permission(None),
                "standalone CLI launches must keep requesting permission by default");
    }

    #[test]
    fn capture_json_reports_permission_and_writer_readiness() {
        let waiting: serde_json::Value =
            serde_json::from_str(&capture_json(true, false, true)).unwrap();
        assert_eq!(waiting["type"], "capture");
        assert_eq!(waiting["enabled"], false);
        assert_eq!(waiting["permission_required"], true);

        let active: serde_json::Value =
            serde_json::from_str(&capture_json(true, true, false)).unwrap();
        assert_eq!(active["type"], "capture");
        assert_eq!(active["enabled"], true);
        assert_eq!(active["permission_required"], false);
    }

    #[test]
    fn duplicate_fn_down_does_not_persist_or_extend_the_session() {
        let mut tracker = Tracker::new();
        let mut sessions = SessionTracker::new(60, 5);
        let mut store = Store::open(std::path::Path::new(":memory:"), 500).unwrap();
        let broadcaster = Broadcaster::empty();
        let start = Instant::now();
        for ts_ms in [1_000, 1_600] {
            let event = RawKeyEvent {
                ts_ms,
                keycode: 63,
                kind: KeyKind::Down,
                at: start + Duration::from_millis(ts_ms as u64),
                app: Some("test.app".into()),
            };
            handle_event(&event, &mut tracker, &mut sessions, &mut store, &broadcaster);
        }
        assert_eq!(store.pending(), 1, "only the first down may be persisted");
        let settled = sessions.flush().unwrap();
        assert_eq!(settled.key_count, 1);
        assert_eq!(settled.end_ms, 6_000, "a duplicate down must not extend activity");
    }

    #[test]
    fn frequent_events_do_not_extend_flush_deadline() {
        let start = Instant::now();
        let mut schedule = FlushSchedule::new(start, Duration::from_secs(2));
        for millis in [100, 500, 1_000, 1_999] {
            let now = start + Duration::from_millis(millis);
            assert!(!schedule.take_due(now));
            assert_eq!(schedule.remaining(now), Duration::from_millis(2_000 - millis));
        }
        assert!(schedule.take_due(start + Duration::from_secs(2)));
        assert!(!schedule.take_due(start + Duration::from_secs(2)));
        assert_eq!(schedule.remaining(start + Duration::from_secs(2)), Duration::from_secs(2));
    }

    #[test]
    fn late_flush_keeps_the_original_schedule() {
        let start = Instant::now();
        let mut schedule = FlushSchedule::new(start, Duration::from_secs(2));
        assert!(schedule.take_due(start + Duration::from_millis(7_500)));
        assert_eq!(schedule.remaining(start + Duration::from_millis(7_500)), Duration::from_millis(500));
        assert!(schedule.take_due(start + Duration::from_secs(8)));
    }

    #[test]
    fn zero_flush_interval_cannot_busy_loop() {
        let start = Instant::now();
        let mut schedule = FlushSchedule::new(start, Duration::ZERO);
        assert_eq!(schedule.remaining(start), Duration::from_secs(1));
        assert!(schedule.take_due(start + Duration::from_secs(1)));
        assert!(!schedule.take_due(start + Duration::from_secs(1)));
    }
}
