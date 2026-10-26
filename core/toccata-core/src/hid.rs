//! Non-exclusive, process-owned raw HID supplement for physical special keys.
//! The manager never changes key mappings, seizes devices, or requests permission.
use crate::{
    special_keys::{self, PhysicalKeys},
    tap,
    tracker::KeyKind,
    WriterMsg,
};
use core_foundation::{
    array::{CFArray, CFArrayRef},
    base::{CFRelease, CFType, TCFType},
    dictionary::{CFDictionary, CFDictionaryRef},
    number::CFNumber,
    runloop::{kCFRunLoopCommonModes, CFRunLoop, CFRunLoopRef},
    string::{CFString, CFStringRef},
};
use std::{cell::RefCell, collections::HashSet, ffi::c_void, ptr, sync::mpsc::Sender};

type Ref = *mut c_void;
type DeviceCallback = extern "C" fn(Ref, i32, Ref, Ref);
#[link(name = "IOKit", kind = "framework")]
extern "C" {
    fn IOHIDManagerCreate(allocator: *const c_void, options: u32) -> Ref;
    fn IOHIDManagerSetDeviceMatching(manager: Ref, matching: CFDictionaryRef);
    fn IOHIDManagerSetInputValueMatchingMultiple(manager: Ref, matching: CFArrayRef);
    fn IOHIDManagerRegisterDeviceMatchingCallback(
        manager: Ref,
        callback: DeviceCallback,
        context: Ref,
    );
    fn IOHIDManagerRegisterDeviceRemovalCallback(
        manager: Ref,
        callback: DeviceCallback,
        context: Ref,
    );
    fn IOHIDManagerRegisterInputValueCallback(manager: Ref, callback: DeviceCallback, context: Ref);
    fn IOHIDManagerScheduleWithRunLoop(manager: Ref, runloop: CFRunLoopRef, mode: CFStringRef);
    fn IOHIDManagerUnscheduleFromRunLoop(manager: Ref, runloop: CFRunLoopRef, mode: CFStringRef);
    fn IOHIDManagerOpen(manager: Ref, options: u32) -> i32;
    fn IOHIDManagerClose(manager: Ref, options: u32) -> i32;
    fn IOHIDDeviceOpen(device: Ref, options: u32) -> i32;
    fn IOHIDDeviceCopyMatchingElements(
        device: Ref,
        matching: CFDictionaryRef,
        options: u32,
    ) -> CFArrayRef;
    fn IOHIDElementGetUsagePage(element: Ref) -> u32;
    fn IOHIDElementGetUsage(element: Ref) -> u32;
    fn IOHIDElementGetType(element: Ref) -> u32;
    fn IOHIDElementGetDevice(element: Ref) -> Ref;
    fn IOHIDValueGetElement(value: Ref) -> Ref;
    fn IOHIDValueGetIntegerValue(value: Ref) -> isize;
}

struct Context {
    sender: Sender<WriterMsg>,
    keys: RefCell<PhysicalKeys>,
}
struct Capture {
    manager: Ref,
    context: Box<Context>,
}
thread_local! { static CAPTURE: RefCell<Option<Capture>> = const { RefCell::new(None) }; }

fn matching(pairs: &[(&str, i32)]) -> CFDictionary<CFString, CFType> {
    CFDictionary::from_CFType_pairs(
        &pairs
            .iter()
            .map(|(key, value)| (CFString::new(key), CFNumber::from(*value).as_CFType()))
            .collect::<Vec<_>>(),
    )
}

pub fn start(sender: Sender<WriterMsg>) {
    // Permission is shared with CGEventTap; leave the existing prompt flow in charge.
    if !tap::preflight() {
        return;
    }
    let manager = unsafe { IOHIDManagerCreate(ptr::null(), 0) };
    if manager.is_null() {
        return;
    }
    let mut capture = Capture {
        manager,
        context: Box::new(Context {
            sender,
            keys: RefCell::default(),
        }),
    };
    let context = capture.context.as_mut() as *mut Context as Ref;
    let devices = matching(&[("DeviceUsagePage", 1), ("DeviceUsage", 6)]);
    let filters: Vec<_> = special_keys::usages()
        .into_iter()
        .map(|(page, usage)| matching(&[("UsagePage", page as i32), ("Usage", usage as i32)]))
        .collect();
    let filters = CFArray::from_CFTypes(&filters);
    unsafe {
        IOHIDManagerSetDeviceMatching(manager, devices.as_concrete_TypeRef());
        IOHIDManagerSetInputValueMatchingMultiple(manager, filters.as_concrete_TypeRef());
        IOHIDManagerRegisterDeviceMatchingCallback(manager, added, context);
        IOHIDManagerRegisterDeviceRemovalCallback(manager, removed, context);
        IOHIDManagerRegisterInputValueCallback(manager, value_changed, context);
        IOHIDManagerScheduleWithRunLoop(
            manager,
            CFRunLoop::get_current().as_concrete_TypeRef(),
            kCFRunLoopCommonModes,
        );
    }
    let result = unsafe { IOHIDManagerOpen(manager, 0) }; // 0 = shared, never SeizeDevice.
    if result != 0 {
        eprintln!("[toccata-core] 原始功能键监听不可用 ({result:#x})，保留普通键盘监听");
        // Drop unschedules/closes the manager before its callback context is freed.
        return;
    }
    CAPTURE.with(|slot| *slot.borrow_mut() = Some(capture));
}

/// Use exactly one source for each special key. Only successfully opened,
/// connected keyboard devices with matching input elements suppress CG duplicates.
pub fn covers(code: i64) -> bool {
    CAPTURE.with(|slot| {
        slot.borrow()
            .as_ref()
            .is_some_and(|capture| capture.context.keys.borrow().covers(code))
    })
}
pub fn stop() {
    CAPTURE.with(|slot| {
        slot.borrow_mut().take();
    });
}

extern "C" fn added(context: Ref, result: i32, _: Ref, device: Ref) {
    if context.is_null() || device.is_null() || result != 0 {
        return;
    }
    let context = unsafe { &*(context as *const Context) };
    if unsafe { IOHIDDeviceOpen(device, 0) } != 0 {
        return;
    }
    let elements = unsafe { IOHIDDeviceCopyMatchingElements(device, ptr::null(), 0) };
    if elements.is_null() {
        return;
    }
    let elements = unsafe { CFArray::<*const c_void>::wrap_under_create_rule(elements) };
    let codes: HashSet<_> = elements
        .get_all_values()
        .iter()
        .filter_map(|&element| unsafe {
            let element = element as Ref;
            let kind = IOHIDElementGetType(element);
            if !(1..=4).contains(&kind) {
                return None;
            } // Input only; never Caps Lock LED.
            special_keys::keycode(
                IOHIDElementGetUsagePage(element),
                IOHIDElementGetUsage(element),
            )
        })
        .collect();
    context.keys.borrow_mut().register(device as usize, codes);
}
extern "C" fn removed(context: Ref, _: i32, _: Ref, device: Ref) {
    if context.is_null() {
        return;
    }
    let context = unsafe { &*(context as *const Context) };
    let released = context.keys.borrow_mut().remove(device as usize);
    for code in released {
        emit(&context.sender, code, KeyKind::Up);
    }
}
extern "C" fn value_changed(context: Ref, result: i32, _: Ref, value: Ref) {
    if context.is_null() || value.is_null() || result != 0 {
        return;
    }
    let context = unsafe { &*(context as *const Context) };
    let element = unsafe { IOHIDValueGetElement(value) };
    let code = unsafe {
        special_keys::keycode(
            IOHIDElementGetUsagePage(element),
            IOHIDElementGetUsage(element),
        )
    };
    if let Some(code) = code {
        let device = unsafe { IOHIDElementGetDevice(element) } as usize;
        let down = unsafe { IOHIDValueGetIntegerValue(value) } != 0;
        let kind = context.keys.borrow_mut().transition(device, code, down);
        if let Some(kind) = kind {
            emit(&context.sender, code, kind);
        }
    }
}
fn emit(sender: &Sender<WriterMsg>, code: i64, kind: KeyKind) {
    if code == special_keys::LOCK_KEYCODE {
        // Lock can take away the session before a key-up is delivered. Count the
        // click, but never interpret time spent on the lock screen as a key hold.
        if kind == KeyKind::Down {
            tap::send(sender, code, KeyKind::Down);
            tap::send(sender, code, KeyKind::Up);
        }
    } else {
        tap::send(sender, code, kind);
    }
}
impl Drop for Capture {
    fn drop(&mut self) {
        unsafe {
            IOHIDManagerUnscheduleFromRunLoop(
                self.manager,
                CFRunLoop::get_current().as_concrete_TypeRef(),
                kCFRunLoopCommonModes,
            );
            IOHIDManagerClose(self.manager, 0);
            CFRelease(self.manager);
        }
    }
}
