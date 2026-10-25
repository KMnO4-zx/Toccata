//! CGEventTap 全局键盘采集。
//!
//! - autorepeat 的 keyDown 直接丢弃（不计数、不计时、不广播）
//! - TapDisabledByTimeout / TapDisabledByUser 时在回调里立即重新 enable
//! - 回调只做微秒级内存操作 + mpsc send，任何阻塞都会导致系统超时禁用 tap

use std::cell::RefCell;
use std::sync::atomic::{AtomicBool, Ordering};
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

static CAPTURE_ACTIVE: AtomicBool = AtomicBool::new(false);

thread_local! {
    // 回调需要访问 tap 本身以便在被系统禁用后重新 enable；
    // tap 只在主线程（runloop 线程）创建与访问，thread_local 足够。
    static TAP: RefCell<Option<CGEventTap<'static>>> = const { RefCell::new(None) };
    static SOURCE: RefCell<Option<CFRunLoopSource>> = const { RefCell::new(None) };
}

pub fn capture_enabled() -> bool {
    CAPTURE_ACTIVE.load(Ordering::SeqCst)
}

pub fn permission_required() -> bool {
    !preflight()
}

fn set_capture_active(active: bool, sender: Option<&Sender<WriterMsg>>) {
    if CAPTURE_ACTIVE.swap(active, Ordering::SeqCst) != active {
        if let Some(sender) = sender {
            let _ = sender.send(WriterMsg::Capture(active));
        }
    }
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
    // IOKit/hidsystem/IOLLEvent.h 中的 NX_DEVICE*KEYMASK 区分左右键。
    // 仅判断 Command / Shift 等聚合位时，松开左键而右键仍按住会被误判为 down。
    let mask = match keycode {
        55 => 0x00000008, // left command
        54 => 0x00000010, // right command
        56 => 0x00000002, // left shift
        60 => 0x00000004, // right shift
        58 => 0x00000020, // left option
        61 => 0x00000040, // right option
        59 => 0x00000001, // left control
        62 => 0x00002000, // right control
        63 => F::CGEventFlagSecondaryFn.bits(),
        57 => F::CGEventFlagAlphaShift.bits(),
        _ => return None,
    };
    Some(if flags.bits() & mask != 0 { KeyKind::Down } else { KeyKind::Up })
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
            set_capture_active(false, Some(sender));
            TAP.with(|t| {
                if let Some(tap) = t.borrow().as_ref() {
                    tap.enable();
                    set_capture_active(true, Some(sender));
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

fn key_event_types() -> [CGEventType; 3] {
    [CGEventType::KeyDown, CGEventType::KeyUp, CGEventType::FlagsChanged]
}

/// 创建 tap 并挂到当前线程（必须是主线程）的 CFRunLoop 上。
pub fn create_tap(sender: Sender<WriterMsg>) -> Result<(), ()> {
    let capture_sender = sender.clone();
    // Disabled-tap notifications are delivered by CoreGraphics, not valid event-mask bits.
    let tap = CGEventTap::new(
        CGEventTapLocation::HID,
        CGEventTapPlacement::HeadInsertEventTap,
        CGEventTapOptions::ListenOnly,
        key_event_types().to_vec(),
        move |proxy, ty, event| callback(proxy, ty, event, &sender),
    )?;
    let source = tap.mach_port().create_runloop_source(0)?;
    CFRunLoop::get_current().add_source(&source, unsafe { kCFRunLoopCommonModes });
    tap.enable();
    set_capture_active(true, Some(&capture_sender));
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
            set_capture_active(enabled, None);
            if !enabled {
                tap.enable();
                set_capture_active(true, None);
                eprintln!("[toccata-core] 看门狗检测到 tap 被禁用，已重新启用");
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use core_graphics::event::CGEventFlags as F;

    #[test]
    fn event_mask_only_contains_keyboard_events() {
        let types = key_event_types();
        assert!(types.iter().all(|kind| (*kind as u32) < 32));
        let mask = types.iter().fold(0_u64, |mask, kind| mask | (1_u64 << (*kind as u32)));
        assert_eq!(mask, (1 << 10) | (1 << 11) | (1 << 12));
    }

    #[test]
    fn releasing_one_modifier_side_does_not_use_other_sides_flag() {
        for (left, right, left_mask, right_mask, aggregate) in [
            (55, 54, 0x08, 0x10, F::CGEventFlagCommand),
            (56, 60, 0x02, 0x04, F::CGEventFlagShift),
            (58, 61, 0x20, 0x40, F::CGEventFlagAlternate),
            (59, 62, 0x01, 0x2000, F::CGEventFlagControl),
        ] {
            let right_only = F::from_bits_retain(aggregate.bits() | right_mask);
            assert_eq!(modifier_kind(left, right_only), Some(KeyKind::Up));
            assert_eq!(modifier_kind(right, right_only), Some(KeyKind::Down));
            let left_only = F::from_bits_retain(aggregate.bits() | left_mask);
            assert_eq!(modifier_kind(right, left_only), Some(KeyKind::Up));
            assert_eq!(modifier_kind(left, left_only), Some(KeyKind::Down));
        }
    }

    #[test]
    fn fn_uses_its_own_flag() {
        assert_eq!(modifier_kind(63, F::CGEventFlagSecondaryFn), Some(KeyKind::Down));
        assert_eq!(modifier_kind(63, F::CGEventFlagCommand), Some(KeyKind::Up));
        assert_eq!(modifier_kind(13, F::CGEventFlagSecondaryFn), None);
    }
}
