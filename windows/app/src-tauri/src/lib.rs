//! The Windows build of huh?.
//!
//! The split mirrors the Mac's: everything timing-sensitive -- the keyboard
//! hook, audio capture, decoding, insertion -- lives in Rust, and the interface
//! only draws and sends commands. A busy interface can then never delay a
//! keypress or a paste, which on a push-to-talk app is the whole game.
pub mod audio;
pub mod controller;
pub mod dictation;
pub mod hotkey;
pub mod inject;
pub mod overlay;
pub mod speech;

use std::sync::atomic::AtomicU64;
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
    pub recorder: audio::Recorder,
    pub recogniser: speech::Recogniser,
    /// Counts utterances, so work started for one can tell it has been
    /// overtaken by the next.
    pub utterances: AtomicU64,
}

impl App {
    fn load() -> Self {
        let stores = Stores::default();
        let settings = stores.settings();
        Self {
            stores,
            settings: RwLock::new(settings),
            dictation: dictation::Machine::new(),
            recorder: audio::Recorder::new(),
            recogniser: speech::Recogniser::new(),
            utterances: AtomicU64::new(0),
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
    hotkey::set_key(hotkey::virtual_key(settings.hotkey));
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

#[tauri::command]
fn engine_status(app: tauri::State<'_, Shared>) -> speech::Status {
    app.recogniser.status()
}

/// Starts and stops from the window or the tray, independently of the key.
///
/// On a thread of its own: a synchronous command runs on the interface's
/// thread, and opening a microphone takes long enough to be seen there.
#[tauri::command]
fn toggle_dictation(app: tauri::State<'_, Shared>, handle: tauri::AppHandle) {
    let app = app.inner().clone();
    std::thread::spawn(move || controller::toggle(&handle, &app));
}

pub fn run() {
    tracing_subscriber::fmt()
        .with_env_filter(
            // Both names: the binary is `huh`, but everything it runs is in
            // the library crate, `huh_lib`, and a filter on one is silent
            // about the other.
            tracing_subscriber::EnvFilter::try_from_env("HUH_LOG")
                .unwrap_or_else(|_| "huh=info,huh_lib=info".into()),
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
            engine_status,
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
            }
            let handle = app.handle().clone();
            overlay::prepare(&handle);

            // The model loads now, long before the first press needs it, and
            // on a first launch this is where it is downloaded.
            let events = handle.clone();
            shared.recogniser.prepare(move |status| {
                let _ = events.emit("engine", status);
            });

            hotkey::set_key(hotkey::virtual_key(shared.settings.read().hotkey));
            let shared = shared.clone();
            hotkey::listen(move |event| match event {
                hotkey::Event::Down => controller::key_down(&handle, &shared),
                hotkey::Event::Up => controller::key_up(&handle, &shared),
            });
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("huh? failed to start");
}
