//! The main window's frame: the parts Windows draws around the page.
use tauri::{AppHandle, Manager};

const MAIN: &str = "main";

/// Brings the main window back from wherever it went: hidden by its close
/// button, minimised, or behind something else.
pub fn reveal(app: &AppHandle) {
    if let Some(main) = app.get_webview_window(MAIN) {
        let _ = main.unminimize();
        let _ = main.show();
        let _ = main.set_focus();
        platform::bring_forward(&main);
    }
}

/// Dresses the main window once, at launch.
pub fn dress(app: &AppHandle) {
    if let Some(main) = app.get_webview_window(MAIN) {
        platform::border(&main);
    }
}

/// The same grey outline for any other window the app opens.
pub fn border(window: &tauri::WebviewWindow) {
    platform::border(window);
}

#[cfg(windows)]
mod platform {
    use windows::Win32::Foundation::{COLORREF, HWND};
    use windows::Win32::Graphics::Dwm::{DwmSetWindowAttribute, DWMWA_BORDER_COLOR};
    use windows::Win32::System::Threading::{AttachThreadInput, GetCurrentThreadId};
    use windows::Win32::UI::WindowsAndMessaging::{
        BringWindowToTop, GetForegroundWindow, GetWindowThreadProcessId, SetForegroundWindow,
    };

    /// Puts the window in front when it was asked for.
    ///
    /// Windows keeps focus from an app that isn't already in front, and this
    /// one rarely is when someone asks for its window: they have clicked the
    /// tray, or the session panel, which never takes focus, over a call in
    /// another app. `set_focus` alone then only flashes the taskbar. Joining
    /// the input of the thread that has the foreground for a moment is the
    /// sanctioned way through, and it only ever happens on a request.
    pub fn bring_forward(window: &tauri::WebviewWindow) {
        let Ok(handle) = window.hwnd() else { return };
        let raw = handle.0 as isize;
        let _ = window.run_on_main_thread(move || unsafe {
            let ours = HWND(raw as *mut _);
            let front = GetForegroundWindow();
            if front == ours {
                return;
            }
            let theirs = GetWindowThreadProcessId(front, None);
            let me = GetCurrentThreadId();
            let joined =
                theirs != 0 && theirs != me && AttachThreadInput(me, theirs, true).as_bool();
            let _ = BringWindowToTop(ours);
            let _ = SetForegroundWindow(ours);
            if joined {
                let _ = AttachThreadInput(me, theirs, false);
            }
        });
    }

    /// Windows 11 outlines a window in the system accent colour. When the
    /// accent is purple, a window that is not listening looks as though it is,
    /// because purple is the one colour that means live here. The outline
    /// takes the grey every other edge in the app has instead. Windows 10 has
    /// no outline to colour and refuses the call, which is fine.
    pub fn border(window: &tauri::WebviewWindow) {
        let Ok(handle) = window.hwnd() else { return };
        // Theme.border, #262626, as Windows writes a colour: 0x00BBGGRR.
        let colour = COLORREF(0x0026_2626);
        unsafe {
            let _ = DwmSetWindowAttribute(
                HWND(handle.0),
                DWMWA_BORDER_COLOR,
                std::ptr::from_ref(&colour).cast(),
                std::mem::size_of::<COLORREF>() as u32,
            );
        }
    }
}

#[cfg(not(windows))]
mod platform {
    pub fn border(_window: &tauri::WebviewWindow) {}

    pub fn bring_forward(_window: &tauri::WebviewWindow) {}
}
