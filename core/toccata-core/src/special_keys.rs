//! Physical special keys, kept separate from the OS's latched modifier state.
use crate::tracker::KeyKind;
use std::collections::{HashMap, HashSet};

pub const LOCK_KEYCODE: i64 = 127; // Power/Lock, not CG keycode 105 (F13).
const FUNCTION_CODES: [i64; 12] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111];

// Top-row actions on Apple keyboards. Consumer usages are emitted instead of
// keyboard usages on some firmware/mode combinations; never match audio devices.
const ACTIONS: &[(u32, u32, i64)] = &[
    (0x0c, 0x70, 122),
    (0x0c, 0x6f, 120), // display brightness F1/F2
    (0x0c, 0x29f, 99),
    (0x0c, 0x221, 118), // Mission Control / Spotlight
    (0x0c, 0x2a2, 118), // Launchpad on older keyboards
    (0x0c, 0xcf, 96),
    (0x01, 0x9b, 97), // dictation / Do Not Disturb
    (0x0c, 0x7a, 96),
    (0x0c, 0x79, 97), // older backlight F5/F6
    (0x0c, 0xb4, 98),
    (0x0c, 0xb6, 98),  // rewind / previous F7
    (0x0c, 0xcd, 100), // play/pause F8
    (0x0c, 0xb3, 101),
    (0x0c, 0xb5, 101), // fast-forward / next F9
    (0x0c, 0xe2, 109),
    (0x0c, 0xea, 103),
    (0x0c, 0xe9, 111), // F10–F12
    (0x07, 0x7f, 109),
    (0x07, 0x81, 103),
    (0x07, 0x80, 111),
    (0x07, 0x66, LOCK_KEYCODE),
    (0x0c, 0x30, LOCK_KEYCODE),
    (0x0c, 0x19e, LOCK_KEYCODE), // AL Terminal Lock / Screensaver
];

pub fn usages() -> Vec<(u32, u32)> {
    (0x39..=0x45)
        .map(|usage| (7, usage))
        .chain(ACTIONS.iter().map(|&(page, usage, _)| (page, usage)))
        .collect()
}

/// USB HID Usage Tables. Only keyboard devices are matched by the HID manager.
/// A physical F key keeps its identity even when macOS turns it into a media action.
pub fn keycode(page: u32, usage: u32) -> Option<i64> {
    match (page, usage) {
        (0x07, 0x39) => Some(57),
        (0x07, 0x3a..=0x45) => Some(FUNCTION_CODES[(usage - 0x3a) as usize]),
        _ => ACTIONS
            .iter()
            .find_map(|&(p, u, code)| ((page, usage) == (p, u)).then_some(code)),
    }
}

#[derive(Default)]
pub struct PhysicalKeys {
    devices: HashMap<usize, HashSet<i64>>,
    pressed: HashSet<(usize, i64)>,
}

impl PhysicalKeys {
    pub fn register(&mut self, device: usize, codes: HashSet<i64>) {
        self.devices.insert(device, codes);
    }
    pub fn covers(&self, code: i64) -> bool {
        self.devices.values().any(|keys| keys.contains(&code))
    }
    pub fn transition(&mut self, device: usize, code: i64, down: bool) -> Option<KeyKind> {
        if !self
            .devices
            .get(&device)
            .is_some_and(|keys| keys.contains(&code))
        {
            return None;
        }
        if down {
            self.pressed.insert((device, code)).then_some(KeyKind::Down)
        } else {
            self.pressed.remove(&(device, code)).then_some(KeyKind::Up)
        }
    }
    pub fn remove(&mut self, device: usize) -> Vec<i64> {
        self.devices.remove(&device);
        let released = self
            .pressed
            .iter()
            .filter_map(|(id, code)| (*id == device).then_some(*code))
            .collect();
        self.pressed.retain(|(id, _)| *id != device);
        released
    }
}

/// Fallback when raw HID access is unavailable. AlphaShift is a toggle, never a
/// physical hold: both enabling and disabling it are counted as a short press.
#[derive(Default)]
pub struct CapsLockTransitions(Option<bool>);
impl CapsLockTransitions {
    pub fn changed(&mut self, enabled: bool) -> bool {
        let changed = self.0 != Some(enabled);
        self.0 = Some(enabled);
        changed
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn all_function_keys_caps_and_real_lock_are_mapped() {
        for (offset, code) in FUNCTION_CODES.into_iter().enumerate() {
            assert_eq!(keycode(7, 0x3a + offset as u32), Some(code));
        }
        assert_eq!(keycode(7, 0x39), Some(57));
        assert_eq!(keycode(12, 0x19e), Some(127));
        assert_eq!(keycode(12, 0x30), Some(127));
        assert_eq!(keycode(7, 0x66), Some(127));
        assert_eq!(keycode(7, 0x68), None); // F13 must not light up Lock.
        assert_eq!(keycode(8, 0x39), None); // Ignore LEDs/output reports.
        assert_eq!(keycode(7, 4), None); // Ordinary text keys stay on CGEventTap.
    }
    #[test]
    fn repeats_and_duplicate_reports_do_not_count_twice() {
        let mut keys = PhysicalKeys::default();
        keys.register(1, [122, 57, 127].into());
        for code in [122, 57, 127] {
            assert_eq!(keys.transition(1, code, true), Some(KeyKind::Down));
            assert_eq!(keys.transition(1, code, true), None);
            assert_eq!(keys.transition(1, code, false), Some(KeyKind::Up));
            assert_eq!(keys.transition(1, code, false), None);
            assert_eq!(keys.transition(1, code, true), Some(KeyKind::Down));
            assert_eq!(keys.transition(1, code, false), Some(KeyKind::Up));
        }
    }
    #[test]
    fn media_actions_and_standard_function_keys_share_one_physical_identity() {
        for (usage, code) in [
            (0xb6, 98),
            (0xb4, 98),
            (0xcd, 100),
            (0xb5, 101),
            (0xb3, 101),
            (0xe2, 109),
            (0xea, 103),
            (0xe9, 111),
        ] {
            assert_eq!(keycode(12, usage), Some(code));
        }
        let mut keys = PhysicalKeys::default();
        keys.register(1, [98].into());
        assert_eq!(
            keys.transition(1, keycode(7, 0x40).unwrap(), true),
            Some(KeyKind::Down)
        );
        assert_eq!(keys.transition(1, keycode(12, 0xb6).unwrap(), true), None);
        assert_eq!(
            keys.transition(1, keycode(12, 0xb6).unwrap(), false),
            Some(KeyKind::Up)
        );
        assert_eq!(keys.transition(1, keycode(7, 0x40).unwrap(), false), None);
        assert!(usages()
            .iter()
            .all(|&(page, usage)| keycode(page, usage).is_some()));
    }
    #[test]
    fn device_removal_releases_held_keys_and_restores_cg_fallback() {
        let mut keys = PhysicalKeys::default();
        assert!(!keys.covers(57));
        keys.register(1, [57].into());
        keys.register(2, [122].into());
        assert!(keys.covers(57));
        assert_eq!(keys.transition(2, 57, true), None);
        keys.transition(1, 57, true);
        assert_eq!(keys.remove(1), vec![57]);
        assert!(!keys.covers(57));
        assert!(keys.covers(122));
        keys.register(1, [57].into());
        assert_eq!(keys.transition(1, 57, true), Some(KeyKind::Down));
    }
    #[test]
    fn caps_fallback_counts_both_toggle_directions_once() {
        let mut caps = CapsLockTransitions::default();
        assert!(caps.changed(true));
        assert!(!caps.changed(true));
        assert!(caps.changed(false));
        assert!(!caps.changed(false));
        assert!(caps.changed(true));
        assert!(CapsLockTransitions::default().changed(false));
    }
}
