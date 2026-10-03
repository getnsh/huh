//! The machine around the app: settings, the microphone as Windows sees it,
//! starting at sign-in, and the Settings window.
use std::time::Duration;

use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager, State, WebviewUrl, WebviewWindowBuilder};
use tauri_plugin_autostart::ManagerExt;

use huh_core::settings::Settings;

use crate::{audio, chrome, hotkey, Shared};

type Done = Result<(), String>;

#[tauri::command]
pub fn get_settings(app: State<'_, Shared>) -> Settings {
    app.settings.read().clone()
}

/// Saves, applies what takes effect at once, and tells every window, so the
/// main window's "Hold Right Ctrl" follows a change made in Settings.
#[tauri::command]
pub fn set_settings(app: State<'_, Shared>, handle: AppHandle, mut settings: Settings) -> Done {
    // The panel's place is the core's to keep: a page that never knew of it
    // must not wipe it by sending its copy of the rest.
    {
        let current = app.settings.read();
        if settings.panel_anchor_x.is_none() || settings.panel_anchor_y.is_none() {
            settings.panel_anchor_x = current.panel_anchor_x;
            settings.panel_anchor_y = current.panel_anchor_y;
        }
    }
    app.stores
        .save_settings(&settings)
        .map_err(|e| e.to_string())?;
    hotkey::set_key(hotkey::virtual_key(settings.hotkey));
    *app.settings.write() = settings.clone();
    let _ = handle.emit("settings", settings);
    crate::tray::refresh(&handle);
    Ok(())
}

/// The microphone as the banners and Settings describe it.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AudioInput {
    pub has_input: bool,
    pub name: Option<String>,
    pub problem: Option<String>,
}

fn input() -> AudioInput {
    let name = audio::default_input_name();
    AudioInput {
        has_input: name.is_some(),
        problem: name.as_ref().and_then(|_| audio::input_problem()),
        name,
    }
}

#[tauri::command]
pub fn audio_input() -> AudioInput {
    input()
}

/// Watches for a microphone being plugged in, unplugged, muted or blocked,
/// and says so when it changes. The Mac is told by Core Audio; looking every
/// few seconds costs Windows almost nothing and finds the same things.
pub fn watch_input(handle: &AppHandle) {
    let handle = handle.clone();
    let _ = std::thread::Builder::new()
        .name("huh-input-watch".into())
        .spawn(move || {
            let mut last = input();
            loop {
                std::thread::sleep(Duration::from_secs(3));
                let now = input();
                if now != last {
                    let _ = handle.emit("audio-input", &now);
                    crate::tray::refresh(&handle);
                    last = now;
                }
            }
        });
}

/// Looks at the microphone again now, for a Check Again button, rather than
/// waiting for the next poll.
pub fn recheck_input(handle: &AppHandle) {
    let _ = handle.emit("audio-input", input());
}

/// One Settings window, brought forward if it is already open.
///
/// Async on purpose: a synchronous command runs on the main thread, and a
/// webview built from there on Windows never gets past about:blank.
#[tauri::command]
pub async fn open_settings(handle: AppHandle) -> Done {
    if let Some(window) = handle.get_webview_window("settings") {
        let _ = window.unminimize();
        let _ = window.show();
        let _ = window.set_focus();
        return Ok(());
    }
    let window =
        WebviewWindowBuilder::new(&handle, "settings", WebviewUrl::App("settings.html".into()))
            .title("huh? Settings")
            .inner_size(520.0, 592.0)
            .resizable(false)
            .maximizable(false)
            .minimizable(false)
            .decorations(false)
            .theme(Some(tauri::Theme::Dark))
            .background_color(tauri::window::Color(0x0A, 0x0A, 0x0A, 0xFF))
            .center()
            .build()
            .map_err(|e| e.to_string())?;
    chrome::border(&window);
    Ok(())
}

/// The pages of Windows' own Settings app that can fix what the app reports.
#[tauri::command]
pub fn open_system_settings(page: String) -> Done {
    let url = match page.as_str() {
        "microphone" => "ms-settings:privacy-microphone",
        "sound" => "ms-settings:sound",
        "startup" => "ms-settings:startupapps",
        _ => return Err(format!("No settings page called {page}.")),
    };
    tauri_plugin_opener::open_url(url, None::<&str>).map_err(|e| e.to_string())
}

/// Whether huh? starts at sign-in, as Windows has it: the system is the
/// source of truth, as `SMAppService` is on the Mac, so a choice undone in
/// Task Manager's Startup apps is reflected here.
#[tauri::command]
pub fn launch_at_login(handle: AppHandle) -> bool {
    handle.autolaunch().is_enabled().unwrap_or(false)
}

#[tauri::command]
pub fn set_launch_at_login(handle: AppHandle, on: bool) -> Done {
    let launcher = handle.autolaunch();
    if on {
        launcher.enable()
    } else {
        launcher.disable()
    }
    .map_err(|e| e.to_string())
}
