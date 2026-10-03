//! The Windows build of huh?.
//!
//! The split mirrors the Mac's: everything timing-sensitive -- the keyboard
//! hook, audio capture, decoding, insertion -- lives in Rust, and the interface
//! only draws and sends commands. A busy interface can then never delay a
//! keypress or a paste, which on a push-to-talk app is the whole game.
pub mod audio;
pub mod book;
pub mod capture;
pub mod chrome;
pub mod controller;
pub mod dictation;
pub mod files;
pub mod hotkey;
pub mod inject;
pub mod learning;
pub mod media;
pub mod meetings;
pub mod overlay;
pub mod session;
mod sounds;
pub mod speech;
pub mod spelling;
pub mod system;
pub mod tray;

use std::sync::atomic::AtomicU64;
use std::sync::Arc;

use parking_lot::{Mutex, RwLock};
use tauri::{Emitter, Manager};

use huh_core::library::Library;
use huh_core::settings::Settings;
use huh_core::store::Stores;

/// What the whole app shares.
pub struct App {
    /// Where settings.json lives. Everything else is the library's.
    pub stores: Stores,
    pub settings: RwLock<Settings>,
    /// The dictionary, the people, the history and the ledger, behind one
    /// lock, so dictation counting a hit and the window adding a rule cannot
    /// undo each other.
    pub library: Mutex<Library>,
    pub dictation: dictation::Machine,
    pub recorder: audio::Recorder,
    /// What the PC is playing, summed in while the key is held when "Your PC
    /// as well as you" is on.
    pub pc: audio::PcTap,
    pub recogniser: speech::Recogniser,
    pub learning: learning::Learning,
    pub files: files::Files,
    pub session: session::Session,
    /// Counts utterances, so work started for one can tell it has been
    /// overtaken by the next.
    pub utterances: AtomicU64,
}

impl App {
    fn load() -> Self {
        let stores = Stores::default();
        let settings = stores.settings();
        Self {
            library: Mutex::new(Library::open(Stores::new(stores.root.clone()))),
            stores,
            settings: RwLock::new(settings),
            dictation: dictation::Machine::new(),
            recorder: audio::Recorder::new(),
            pc: audio::PcTap::default(),
            recogniser: speech::Recogniser::new(),
            learning: learning::Learning::default(),
            files: files::Files::default(),
            session: session::Session::default(),
            utterances: AtomicU64::new(0),
        }
    }
}

pub type Shared = Arc<App>;

/// Runs a correction pass without touching any file, so the dictionary editor
/// can show what a rule would do before it is saved.
#[tauri::command]
fn preview_corrections(
    app: tauri::State<'_, Shared>,
    text: String,
) -> huh_core::corrections::CorrectionResult {
    let rules = app.library.lock().corrections();
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
        // First, as the plugin requires. A second launch hands over to the
        // first and exits, rather than becoming a second copy with its own
        // keyboard hook and its own copy of the model.
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| {
            chrome::reveal(app);
        }))
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_autostart::init(
            tauri_plugin_autostart::MacosLauncher::LaunchAgent,
            None,
        ))
        // The main window comes back where it was left, at the size it was
        // left, as the Mac's does by autosaving its frame. Only that window,
        // and only its frame: whether it shows at launch is the app's call.
        .plugin(
            tauri_plugin_window_state::Builder::default()
                .with_state_flags(
                    tauri_plugin_window_state::StateFlags::SIZE
                        | tauri_plugin_window_state::StateFlags::POSITION
                        | tauri_plugin_window_state::StateFlags::MAXIMIZED,
                )
                .with_denylist(&["hud", "panel", "settings"])
                .build(),
        )
        .manage(shared.clone())
        .invoke_handler(tauri::generate_handler![
            preview_corrections,
            state,
            engine_status,
            toggle_dictation,
            book::get_history,
            book::delete_transcripts,
            book::write_export,
            book::is_playable,
            book::dictionary_state,
            book::add_term,
            book::update_term,
            book::set_term_enabled,
            book::delete_term,
            book::add_correction,
            book::update_correction,
            book::set_correction_enabled,
            book::delete_correction,
            book::add_person,
            book::update_person,
            book::set_person_enabled,
            book::delete_person,
            book::dismiss_retro_note,
            book::check_correction,
            book::correction_context,
            book::reveal_file,
            learning::suggestions,
            learning::learning_state,
            learning::run_learning,
            learning::accept_candidate,
            learning::accept_candidate_as_person,
            learning::dismiss_candidate,
            learning::reset_dismissed,
            learning::accept_proposal,
            learning::proposal_as_person,
            learning::take_proposal_for_edit,
            learning::dismiss_proposal,
            learning::accept_person_proposal,
            learning::dismiss_person_proposal,
            learning::restore_dismissed,
            learning::dismiss_scan_result,
            files::transcribe_file,
            files::file_job,
            files::keep_original,
            files::recycle_original,
            files::dismiss_file_failure,
            system::get_settings,
            system::set_settings,
            system::audio_input,
            system::open_settings,
            system::open_system_settings,
            system::launch_at_login,
            system::set_launch_at_login,
            session::session_state,
            session::toggle_session,
            session::accept_offer,
            session::decline_offer,
            session::dismiss_panel,
            session::open_saved,
            session::set_panel_expanded,
            session::panel_measured,
            session::panel_drag,
        ])
        .on_window_event(|window, event| {
            // Alt+F4 and the taskbar's "Close window" hide the main window,
            // as its own close button does: the key keeps working, and the
            // tray brings it back.
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                if window.label() == "main" {
                    api.prevent_close();
                    let _ = window.hide();
                }
            }
        })
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
            tray::install(&handle)?;
            overlay::prepare(&handle);
            chrome::dress(&handle);

            // The model loads now, long before the first press needs it, and
            // on a first launch this is where it is downloaded.
            let events = handle.clone();
            shared.recogniser.prepare(move |status| {
                let _ = events.emit("engine", status);
                tray::refresh(&events);
            });

            learning::start(&handle, &shared);
            system::watch_input(&handle);
            session::start_watching(&handle, &shared);

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
