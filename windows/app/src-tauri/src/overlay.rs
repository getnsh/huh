//! The overlay window: shown without taking focus, at the bottom centre of the
//! screen being worked on, and hidden again.
//!
//! It is a fixed, oversized, transparent canvas, the Mac's 760 x 340, anchored
//! 36 px above the bottom of the work area. Everything that moves happens in
//! the page inside it, so the window itself is only ever placed, shown and
//! hidden, and never resized frame by frame.
//!
//! Focus is the whole difficulty. The text has to land in the application that
//! was in front when the key went down, so the overlay must never become the
//! foreground window: not when it appears, not when it is clicked. It is made
//! unfocusable and click-through with Tauri's own flags, because the windowing
//! layer rewrites a window's styles from those flags whenever it restyles it,
//! and anything set behind its back is lost the first time it does. And it is
//! shown with `SWP_SHOWWINDOW | SWP_NOACTIVATE` rather than `show()`, which
//! activates what it shows.
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use tauri::{AppHandle, Emitter, Manager};

const LABEL: &str = "hud";

/// The canvas, in logical pixels.
const WIDTH: f64 = 760.0;
const HEIGHT: f64 = 340.0;
/// Between the canvas and the bottom of the work area.
const LIFT: f64 = 36.0;
/// The page fades for this long before the window goes, the Mac's 0.2 s.
const FADE_OUT: Duration = Duration::from_millis(200);

/// Bumped by every show. A hide names the generation it was meant for, so a
/// hide scheduled at the end of one utterance cannot close the overlay of the
/// next.
static GENERATION: AtomicU64 = AtomicU64::new(0);

/// Makes the overlay what it has to be before it is ever shown.
pub fn prepare(app: &AppHandle) {
    let Some(hud) = app.get_webview_window(LABEL) else {
        return;
    };
    let _ = hud.set_focusable(false);
    let _ = hud.set_ignore_cursor_events(true);
    platform::settle(&hud);
}

/// Shows the overlay and returns its generation.
pub fn show(app: &AppHandle) -> u64 {
    let generation = GENERATION.fetch_add(1, Ordering::SeqCst) + 1;
    let _ = app.emit_to(LABEL, "overlay", true);
    let handle = app.clone();
    let _ = app.run_on_main_thread(move || {
        if let Some(hud) = handle.get_webview_window(LABEL) {
            platform::present(&hud);
        }
    });
    generation
}

/// The generation now showing, for a hide decided later.
pub fn current() -> u64 {
    GENERATION.load(Ordering::SeqCst)
}

/// Fades the overlay out and hides it, unless it has been shown again since
/// `generation`.
pub fn hide(app: &AppHandle, generation: u64) {
    if current() != generation {
        return;
    }
    let _ = app.emit_to(LABEL, "overlay", false);
    let handle = app.clone();
    std::thread::spawn(move || {
        std::thread::sleep(FADE_OUT);
        let inner = handle.clone();
        let _ = handle.run_on_main_thread(move || {
            if current() != generation {
                return;
            }
            if let Some(hud) = inner.get_webview_window(LABEL) {
                platform::conceal(&hud);
            }
        });
    });
}

#[cfg(windows)]
mod platform {
    use super::{HEIGHT, LIFT, WIDTH};
    use windows::Win32::Foundation::{COLORREF, HWND};
    use windows::Win32::Graphics::Gdi::{
        GetMonitorInfoW, MonitorFromWindow, MONITORINFO, MONITOR_DEFAULTTOPRIMARY,
    };
    use windows::Win32::UI::HiDpi::{GetDpiForMonitor, MDT_EFFECTIVE_DPI};
    use windows::Win32::UI::WindowsAndMessaging::{
        GetForegroundWindow, SetLayeredWindowAttributes, SetWindowPos, ShowWindow, HWND_TOPMOST,
        LWA_ALPHA, SWP_NOACTIVATE, SWP_SHOWWINDOW, SW_HIDE,
    };

    fn hwnd(hud: &tauri::WebviewWindow) -> Option<HWND> {
        hud.hwnd().ok().map(|handle| HWND(handle.0))
    }

    /// Click-through needs `WS_EX_LAYERED`, and a layered window is not drawn
    /// at all until it has been given layered attributes. Full opacity: the
    /// page draws its own transparency.
    pub fn settle(hud: &tauri::WebviewWindow) {
        let Some(hwnd) = hwnd(hud) else { return };
        unsafe {
            let _ = SetLayeredWindowAttributes(hwnd, COLORREF(0), 255, LWA_ALPHA);
        }
    }

    pub fn present(hud: &tauri::WebviewWindow) {
        let Some(hwnd) = hwnd(hud) else { return };
        let (x, y, width, height) = placement();
        unsafe {
            let _ = SetWindowPos(
                hwnd,
                HWND_TOPMOST,
                x,
                y,
                width,
                height,
                SWP_NOACTIVATE | SWP_SHOWWINDOW,
            );
        }
    }

    pub fn conceal(hud: &tauri::WebviewWindow) {
        let Some(hwnd) = hwnd(hud) else { return };
        unsafe {
            let _ = ShowWindow(hwnd, SW_HIDE);
        }
    }

    /// The screen being worked on is the one holding the foreground window, as
    /// the Mac takes the screen holding the key window. Computed here rather
    /// than through Tauri's monitor queries, which wait on the event loop that
    /// this runs on.
    fn placement() -> (i32, i32, i32, i32) {
        unsafe {
            let monitor = MonitorFromWindow(GetForegroundWindow(), MONITOR_DEFAULTTOPRIMARY);
            let mut info = MONITORINFO {
                cbSize: std::mem::size_of::<MONITORINFO>() as u32,
                ..Default::default()
            };
            let _ = GetMonitorInfoW(monitor, &mut info);
            let (mut dpi, mut unused) = (96u32, 96u32);
            let _ = GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, &mut dpi, &mut unused);
            let scale = dpi as f64 / 96.0;

            let area = info.rcWork;
            let width = (WIDTH * scale).round() as i32;
            let height = (HEIGHT * scale).round() as i32;
            let x = area.left + (area.right - area.left - width) / 2;
            let y = area.bottom - height - (LIFT * scale).round() as i32;
            (x, y, width, height)
        }
    }
}

#[cfg(not(windows))]
mod platform {
    pub fn settle(_hud: &tauri::WebviewWindow) {}

    pub fn present(hud: &tauri::WebviewWindow) {
        let _ = hud.show();
    }

    pub fn conceal(hud: &tauri::WebviewWindow) {
        let _ = hud.hide();
    }
}
