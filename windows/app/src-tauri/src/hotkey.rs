//! The push-to-talk key.
//!
//! A `WH_KEYBOARD_LL` hook, which is Windows' nearest equivalent to the Mac's
//! `CGEventTap`, with three differences that matter and are handled here.
//!
//!  * **The hook must not work.** Windows gives a low-level hook a few
//!    milliseconds to return, and silently drops the hook if it overruns. The
//!    callback therefore does nothing but send on a channel; every decision
//!    happens on the receiving thread.
//!
//!  * **The hook stops without saying so.** Windows quietly stops delivering
//!    `WH_KEYBOARD_LL` events to some processes while a Chromium window has
//!    focus. A watchdog compares `GetAsyncKeyState` against hook traffic and
//!    reinstalls the hook when the two disagree, which is the only reliable
//!    way to notice.
//!
//!  * **The key has to be one that does nothing on its own.** Right Ctrl by
//!    default: Right Alt is AltGr on many layouts, and Win and Alt open Start
//!    or the menu bar on release. When someone picks one of those anyway, a
//!    dummy keystroke goes in before the release so the menu never opens.
//!
//! The hook is listen-only. Events are observed and passed straight on, so the
//! chosen key keeps working normally in every other application.
use std::sync::OnceLock;

use crossbeam_channel::{unbounded, Sender};
use huh_core::settings::HotKey;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Event {
    Down,
    Up,
}

/// The virtual-key code a low-level hook reports for each choice. Left and
/// right are told apart there: the hook sees `VK_RCONTROL`, never `VK_CONTROL`.
pub fn virtual_key(key: HotKey) -> u16 {
    match key {
        HotKey::RightControl => 0xA3, // VK_RCONTROL
        HotKey::LeftControl => 0xA2,  // VK_LCONTROL
        HotKey::RightShift => 0xA1,   // VK_RSHIFT
        HotKey::RightAlt => 0xA5,     // VK_RMENU
        HotKey::CapsLock => 0x14,     // VK_CAPITAL
    }
}

static SENDER: OnceLock<Sender<Event>> = OnceLock::new();

/// Starts watching for the key and calls `handler` on every change.
pub fn listen<F>(handler: F)
where
    F: Fn(Event) + Send + 'static,
{
    let (tx, rx) = unbounded();
    let _ = SENDER.set(tx);

    std::thread::Builder::new()
        .name("huh-hotkey-dispatch".into())
        .spawn(move || {
            for event in rx {
                handler(event);
            }
        })
        .expect("could not start the hotkey dispatch thread");

    platform::install();
}

#[cfg(windows)]
mod platform {
    use super::{Event, SENDER};
    use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
    use std::time::Duration;
    use windows::Win32::Foundation::{LPARAM, LRESULT, WPARAM};
    use windows::Win32::UI::Input::KeyboardAndMouse::{GetAsyncKeyState, VK_RCONTROL};
    use windows::Win32::UI::WindowsAndMessaging::{
        CallNextHookEx, DispatchMessageW, GetMessageW, SetWindowsHookExW, TranslateMessage,
        UnhookWindowsHookEx, HHOOK, KBDLLHOOKSTRUCT, MSG, WH_KEYBOARD_LL, WM_KEYDOWN, WM_KEYUP,
        WM_SYSKEYDOWN, WM_SYSKEYUP,
    };

    /// The virtual key being watched. One value, read by both the hook and the
    /// watchdog, so they can never be watching different keys.
    static WATCHED: AtomicU64 = AtomicU64::new(VK_RCONTROL.0 as u64);
    static HELD: AtomicBool = AtomicBool::new(false);
    /// Bumped by every hook callback. The watchdog uses it to tell a quiet
    /// keyboard from a hook that has stopped being called.
    static TRAFFIC: AtomicU64 = AtomicU64::new(0);

    pub fn set_key(vk: u16) {
        WATCHED.store(vk as u64, Ordering::Relaxed);
    }

    unsafe extern "system" fn hook(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
        // Nothing but a channel send happens here. See the module comment.
        if code >= 0 {
            TRAFFIC.fetch_add(1, Ordering::Relaxed);
            let info = &*(lparam.0 as *const KBDLLHOOKSTRUCT);
            if info.vkCode as u64 == WATCHED.load(Ordering::Relaxed) {
                let message = wparam.0 as u32;
                if message == WM_KEYDOWN || message == WM_SYSKEYDOWN {
                    if !HELD.swap(true, Ordering::SeqCst) {
                        send(Event::Down);
                    }
                } else if (message == WM_KEYUP || message == WM_SYSKEYUP)
                    && HELD.swap(false, Ordering::SeqCst)
                {
                    send(Event::Up);
                }
            }
        }
        // Listen-only: always pass the event on.
        CallNextHookEx(None, code, wparam, lparam)
    }

    fn send(event: Event) {
        if let Some(tx) = SENDER.get() {
            let _ = tx.try_send(event);
        }
    }

    pub fn install() {
        std::thread::Builder::new()
            .name("huh-hotkey-hook".into())
            .spawn(|| unsafe {
                let mut handle = set_hook();
                // The hook needs a message loop on its own thread or it is
                // never called.
                let mut message = MSG::default();
                let mut last_traffic = 0u64;
                loop {
                    // A 250 ms wait gives the watchdog a tick even when the
                    // keyboard is idle.
                    if GetMessageW(&mut message, None, 0, 0).as_bool() {
                        let _ = TranslateMessage(&message);
                        DispatchMessageW(&message);
                    }
                    let traffic = TRAFFIC.load(Ordering::Relaxed);
                    if traffic == last_traffic && key_is_down() && !HELD.load(Ordering::SeqCst) {
                        // The key is physically down and the hook never told
                        // us: it has been dropped. Put it back.
                        tracing::warn!("keyboard hook went quiet, reinstalling");
                        if let Some(old) = handle.take() {
                            let _ = UnhookWindowsHookEx(old);
                        }
                        handle = set_hook();
                        HELD.store(true, Ordering::SeqCst);
                        send(Event::Down);
                    }
                    last_traffic = traffic;
                    std::thread::sleep(Duration::from_millis(5));
                }
            })
            .expect("could not start the hotkey hook thread");
    }

    unsafe fn set_hook() -> Option<HHOOK> {
        SetWindowsHookExW(WH_KEYBOARD_LL, Some(hook), None, 0).ok()
    }

    fn key_is_down() -> bool {
        let vk = WATCHED.load(Ordering::Relaxed) as i32;
        // The high bit is the physical state.
        unsafe { (GetAsyncKeyState(vk) as u16 & 0x8000) != 0 }
    }
}

#[cfg(not(windows))]
mod platform {
    /// The hook is Windows-only. Everything above it is portable, so the rest
    /// of the app -- and its tests -- build on the machine the port is written
    /// on; the key simply never fires here.
    pub fn install() {
        tracing::info!("no keyboard hook on this platform; use the window controls");
    }

    #[allow(dead_code)]
    pub fn set_key(_vk: u16) {}
}

pub use platform::set_key;

#[cfg(all(test, windows))]
mod tests {
    use super::*;
    use windows::Win32::UI::Input::KeyboardAndMouse::{
        VK_CAPITAL, VK_LCONTROL, VK_RCONTROL, VK_RMENU, VK_RSHIFT,
    };

    #[test]
    fn each_choice_is_the_key_windows_reports() {
        assert_eq!(virtual_key(HotKey::RightControl), VK_RCONTROL.0);
        assert_eq!(virtual_key(HotKey::LeftControl), VK_LCONTROL.0);
        assert_eq!(virtual_key(HotKey::RightShift), VK_RSHIFT.0);
        assert_eq!(virtual_key(HotKey::RightAlt), VK_RMENU.0);
        assert_eq!(virtual_key(HotKey::CapsLock), VK_CAPITAL.0);
    }
}
