//! CGEventTap 全局键盘采集。
//!
//! - autorepeat 的 keyDown 直接丢弃（不计数、不计时、不广播）
//! - TapDisabledByTimeout / TapDisabledByUser 时在回调里立即重新 enable
//! - 回调只做微秒级内存操作 + mpsc send，任何阻塞都会导致系统超时禁用 tap

use std::cell::RefCell;
use std::sync::mpsc::Sender;
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use core_foundation::base::TCFType;
use core_foundation::mach_port::CFMachPortRef;
use core_foundation::runloop::{kCFRunLoopCommonModes, CFRunLoop, CFRunLoopSource};
use core_graphics::event::{
    CGEvent, CGEventTap, CGEventTapLocation, CGEventTapOptions, CGEventTapPlacement, CGEventType,
    CallbackResult, EventField,
};
use objc2_app_kit::NSWorkspace;

use crate::tracker::KeyKind;
use crate::WriterMsg;

// core-graphics 0.25 未封装这三个函数，自行声明（同属 CoreGraphics framework）。
#[link(name = "CoreGraphics", kind = "framework")]
extern "C" {
    fn CGPreflightListenEventAccess() -> bool;
    fn CGRequestListenEventAccess() -> bool;
    fn CGEventTapIsEnabled(tap: CFMachPortRef) -> bool;
}

thread_local! {
    // 回调需要访问 tap 本身以便在被系统禁用后重新 enable；
    // tap 只在主线程（runloop 线程）创建与访问，thread_local 足够。
    static TAP: RefCell<Option<CGEventTap<'static>>> = const { RefCell::new(None) };
    static SOURCE: RefCell<Option<CFRunLoopSource>> = const { RefCell::new(None) };
}

/// 采集层产出、发往 writer 线程的原始按键事件。
#[derive(Debug)]
pub struct RawKeyEvent {
    pub ts_ms: i64,
    pub keycode: i64,
    pub kind: KeyKind,
    pub at: Instant,
    pub app: Option<String>,
}

pub fn preflight() -> bool {
    unsafe { CGPreflightListenEventAccess() }
}

pub fn request_access() -> bool {
    unsafe { CGRequestListenEventAccess() }
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn frontmost_app() -> Option<String> {
    NSWorkspace::sharedWorkspace()
        .frontmostApplication()
        .and_then(|app| app.bundleIdentifier())
        .map(|s| s.to_string())
}

/// FlagsChanged 的修饰键 → down/up 判定。未知修饰键返回 None（忽略该事件）。
/// 55/54=cmd, 56/60=shift, 58/61=option, 59/62=ctrl, 63=fn, 57=caps
fn modifier_kind(keycode: i64, flags: core_graphics::event::CGEventFlags) -> Option<KeyKind> {
    use core_graphics::event::CGEventFlags as F;
    let mask = match keycode {
        55 | 54 => F::CGEventFlagCommand,   // 0x100000
        56 | 60 => F::CGEventFlagShift,     // 0x20000
        58 | 61 => F::CGEventFlagAlternate, // 0x80000
        59 | 62 => F::CGEventFlagControl,   // 0x40000
        63 => F::CGEventFlagSecondaryFn,    // 0x800000
        57 => F::CGEventFlagAlphaShift,     // 0x10000
        _ => return None,
    };
    Some(if flags.contains(mask) { KeyKind::Down } else { KeyKind::Up })
}

fn callback(
    _proxy: core_graphics::event::CGEventTapProxy,
    ty: CGEventType,
    event: &CGEvent,
    sender: &Sender<WriterMsg>,
) -> CallbackResult {
    match ty {
        CGEventType::KeyDown => {
            // autorepeat 过滤：直接丢弃
            if event.get_integer_value_field(EventField::KEYBOARD_EVENT_AUTOREPEAT) == 1 {
                return CallbackResult::Drop;
            }
            let keycode = event.get_integer_value_field(EventField::KEYBOARD_EVENT_KEYCODE);
            send(sender, keycode, KeyKind::Down);
        }
        CGEventType::KeyUp => {
            let keycode = event.get_integer_value_field(EventField::KEYBOARD_EVENT_KEYCODE);
            send(sender, keycode, KeyKind::Up);
        }
        CGEventType::FlagsChanged => {
            let keycode = event.get_integer_value_field(EventField::KEYBOARD_EVENT_KEYCODE);
            if let Some(kind) = modifier_kind(keycode, event.get_flags()) {
                send(sender, keycode, kind);
            }
        }
        CGEventType::TapDisabledByTimeout | CGEventType::TapDisabledByUserInput => {
            // tap 被系统禁用（回调过慢超时 / 用户撤销）：立即重新启用
            TAP.with(|t| {
                if let Some(tap) = t.borrow().as_ref() {
                    tap.enable();
                    eprintln!("[toccata-core] 事件监听被系统禁用（{ty:?}），已自动重新启用");
                }
            });
        }
        _ => {}
    }
    CallbackResult::Drop // ListenOnly：返回值被系统忽略
}

fn send(sender: &Sender<WriterMsg>, keycode: i64, kind: KeyKind) {
    let _ = sender.send(WriterMsg::Event(RawKeyEvent {
        ts_ms: now_ms(),
        keycode,
        kind,
        at: Instant::now(),
        app: frontmost_app(),
    }));
}

/// 创建 tap 并挂到当前线程（必须是主线程）的 CFRunLoop 上。
pub fn create_tap(sender: Sender<WriterMsg>) -> Result<(), ()> {
    let tap = CGEventTap::new(
        CGEventTapLocation::HID,
        CGEventTapPlacement::HeadInsertEventTap,
        CGEventTapOptions::ListenOnly,
        vec![
            CGEventType::KeyDown,
            CGEventType::KeyUp,
            CGEventType::FlagsChanged,
            CGEventType::TapDisabledByTimeout,
            CGEventType::TapDisabledByUserInput,
        ],
        move |proxy, ty, event| callback(proxy, ty, event, &sender),
    )?;
    let source = tap.mach_port().create_runloop_source(0)?;
    CFRunLoop::get_current().add_source(&source, unsafe { kCFRunLoopCommonModes });
    tap.enable();
    SOURCE.with(|s| *s.borrow_mut() = Some(source));
    TAP.with(|t| *t.borrow_mut() = Some(tap));
    Ok(())
}

/// 看门狗：回调内 enable 之外的第二道保险。
/// 由主线程 CFRunLoop 上的周期 timer 调用（与 tap 同线程，可直接访问 thread_local）。
pub fn watchdog_check() {
    TAP.with(|t| {
        if let Some(tap) = t.borrow().as_ref() {
            let enabled = unsafe { CGEventTapIsEnabled(tap.mach_port().as_concrete_TypeRef()) };
            if !enabled {
                tap.enable();
                eprintln!("[toccata-core] 看门狗检测到 tap 被禁用，已重新启用");
            }
        }
    });
}
