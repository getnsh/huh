//! The Windows build of huh?.
//!
//! The split mirrors the Mac's: everything timing-sensitive -- the keyboard
//! hook, audio capture, decoding, insertion -- lives in Rust, and the interface
//! only draws and sends commands. A busy interface can then never delay a
//! keypress or a paste, which on a push-to-talk app is the whole game.
pub mod audio;
pub mod dictation;
pub mod hotkey;
pub mod inject;

use std::sync::Arc;

use parking_lot::RwLock;
use tauri::{Emitter, Manager};

use huh_core::settings::Settings;
use huh_core::store::Stores;

/// What the whole app shares.
pub struct App {
    pub stores: Stores,
    pub settings: RwLock<Settings>,
    pub dictation: dictation::Machine,
}

impl App {
    fn load() -> Self {
        let stores = Stores::default();
        let settings = stores.settings();
        Self {
            stores,
            settings: RwLock::new(settings),
            dictation: dictation::Machine::new(),
        }
    }
}

pub type Shared = Arc<App>;

#[tauri::command]
fn get_settings(app: tauri::State<'_, Shared>) -> Settings {
    app.settings.read().clone()
}

#[tauri::command]
fn set_settings(app: tauri::State<'_, Shared>, settings: Settings) -> Result<(), String> {
    app.stores
        .save_settings(&settings)
        .map_err(|e| e.to_string())?;
    *app.settings.write() = settings;
    Ok(())
}

#[tauri::command]
fn get_dictionary(app: tauri::State<'_, Shared>) -> huh_core::DictionaryFile {
    app.stores.dictionary()
}

#[tauri::command]
fn save_dictionary(
    app: tauri::State<'_, Shared>,
    file: huh_core::DictionaryFile,
) -> Result<(), String> {
    app.stores.save_dictionary(&file).map_err(|e| e.to_string())
}

#[tauri::command]
fn get_people(app: tauri::State<'_, Shared>) -> huh_core::PeopleFile {
    app.stores.people()
}

#[tauri::command]
fn save_people(app: tauri::State<'_, Shared>, file: huh_core::PeopleFile) -> Result<(), String> {
    app.stores.save_people(&file).map_err(|e| e.to_string())
}

#[tauri::command]
fn get_history(app: tauri::State<'_, Shared>) -> Vec<huh_core::Transcript> {
    app.stores.history()
}

/// Runs a correction pass without touching any file, so the dictionary editor
/// can show what a rule would do before it is saved.
#[tauri::command]
fn preview_corrections(
    app: tauri::State<'_, Shared>,
    text: String,
) -> huh_core::corrections::CorrectionResult {
    let rules = app.stores.corrections();
    huh_core::corrections::apply(&text, &rules)
}

#[tauri::command]
fn state(app: tauri::State<'_, Shared>) -> dictation::State {
    app.dictation.state()
}

/// Starts and stops from the window or the tray, independently of the key.
#[tauri::command]
fn toggle_dictation(app: tauri::State<'_, Shared>, window: tauri::Window) -> Result<(), String> {
    let _ = window;
    app.dictation.toggle();
    Ok(())
}

pub fn run() {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_env("HUH_LOG")
                .unwrap_or_else(|_| "huh=info".into()),
        )
        .init();

    let shared: Shared = Arc::new(App::load());

    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_autostart::init(
            tauri_plugin_autostart::MacosLauncher::LaunchAgent,
            None,
        ))
        .manage(shared.clone())
        .invoke_handler(tauri::generate_handler![
            get_settings,
            set_settings,
            get_dictionary,
            save_dictionary,
            get_people,
            save_people,
            get_history,
            preview_corrections,
            state,
            toggle_dictation,
        ])
        .setup(move |app| {
            // The overlay exists from launch, hidden.
            //
            // Key-down to visible has to stay under 50 ms, and building a
            // WebView takes longer than that on any machine. A press only ever
            // shows a window that is already there.
            if let Some(hud) = app.get_webview_window("hud") {
                let _ = hud.hide();
                inject::make_overlay_click_through(&hud);
            }

            let handle = app.handle().clone();
            let shared = shared.clone();
            hotkey::listen(move |event| {
                let machine = &shared.dictation;
                match event {
                    hotkey::Event::Down => machine.press(),
                    // The release says whether the utterance was long enough
                    // to transcribe; the state it leaves behind is what the
                    // interface reads, so nothing is needed from it here.
                    hotkey::Event::Up => {
                        let _ = machine.release();
                    }
                }
                let _ = handle.emit("dictation", machine.state());
            });
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("huh? failed to start");
}
