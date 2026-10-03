//! The commands that read and change what huh? knows and keeps: the
//! dictionary, the people, and the history.
//!
//! Every change goes through the library under its one lock, then the window
//! is told what changed -- the dictionary, and the history as well when a new
//! rule or name has just fixed transcripts already kept. Asynchronous, so a
//! correction being applied to five hundred transcripts never runs on the
//! interface's thread.
use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager, State};
use uuid::Uuid;

use huh_core::library::Library;
use huh_core::model::{CorrectionPair, Person, Transcript, VocabularyTerm};
use huh_core::safety::{self, Warning};

use crate::{learning, Shared};

/// Everything the Dictionary section draws, in one read.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DictionaryState {
    pub terms: Vec<VocabularyTerm>,
    pub corrections: Vec<CorrectionPair>,
    pub people: Vec<Person>,
    pub load_error: Option<String>,
    pub retro_note: Option<String>,
    pub dictionary_path: String,
    pub people_path: String,
    pub hint_count: usize,
    pub terms_without_corrections: usize,
    pub bias_overflow: usize,
}

pub fn state_of(library: &Library) -> DictionaryState {
    DictionaryState {
        terms: library.dictionary.terms.clone(),
        corrections: library.dictionary.corrections.clone(),
        people: library.people.people.clone(),
        load_error: library
            .dictionary_error
            .clone()
            .or_else(|| library.people_error.clone()),
        retro_note: library.retro_note.clone(),
        dictionary_path: library.stores.dictionary_path().display().to_string(),
        people_path: library.stores.people_path().display().to_string(),
        hint_count: library.bias().len(),
        terms_without_corrections: library.terms_without_corrections(),
        bias_overflow: library.bias_overflow(),
    }
}

/// Tells every window what changed. `history` when transcripts were rewritten.
pub fn publish(handle: &AppHandle, app: &Shared, history: bool) {
    let (state, transcripts) = {
        let library = app.library.lock();
        let transcripts = history.then(|| library.history.clone());
        (state_of(&library), transcripts)
    };
    let _ = handle.emit("dictionary", state);
    if let Some(transcripts) = transcripts {
        let _ = handle.emit("history", transcripts);
    }
    // What is known changed, so what is worth suggesting did too.
    learning::refresh_soon(handle, app);
}

/// Notices dictionary.json and people.json being edited outside the app, in
/// a text editor say, and shows the edit, as the Mac's file watchers do. Once
/// a second is soon enough for a person switching back from an editor, and
/// cheap: it asks the file system two dates.
pub fn watch(handle: &AppHandle, app: &Shared) {
    let handle = handle.clone();
    let app = app.clone();
    let _ = std::thread::Builder::new()
        .name("huh-file-watch".into())
        .spawn(move || loop {
            std::thread::sleep(std::time::Duration::from_secs(1));
            let changed = app.library.lock().reread();
            if changed.dictionary || changed.people {
                tracing::info!(
                    dictionary = changed.dictionary,
                    people = changed.people,
                    "edited outside the app; read again"
                );
                publish(&handle, &app, false);
            }
        });
}

type Done = Result<(), String>;

#[tauri::command]
pub fn dictionary_state(app: State<'_, Shared>) -> DictionaryState {
    state_of(&app.library.lock())
}

#[tauri::command]
pub fn get_history(app: State<'_, Shared>) -> Vec<Transcript> {
    app.library.lock().history.clone()
}

#[tauri::command]
pub async fn add_term(
    app: State<'_, Shared>,
    handle: AppHandle,
    text: String,
    note: String,
) -> Done {
    app.library.lock().add_term(&text, &note);
    publish(&handle, &app, false);
    Ok(())
}

#[tauri::command]
pub async fn update_term(app: State<'_, Shared>, handle: AppHandle, term: VocabularyTerm) -> Done {
    app.library.lock().update_term(term);
    publish(&handle, &app, false);
    Ok(())
}

#[tauri::command]
pub async fn set_term_enabled(
    app: State<'_, Shared>,
    handle: AppHandle,
    id: Uuid,
    on: bool,
) -> Done {
    app.library.lock().set_term_enabled(id, on);
    publish(&handle, &app, false);
    Ok(())
}

#[tauri::command]
pub async fn delete_term(app: State<'_, Shared>, handle: AppHandle, id: Uuid) -> Done {
    app.library.lock().delete_term(id);
    publish(&handle, &app, false);
    Ok(())
}

#[tauri::command]
pub async fn add_correction(
    app: State<'_, Shared>,
    handle: AppHandle,
    hear: String,
    write: String,
) -> Done {
    app.library.lock().add_correction(&hear, &write);
    publish(&handle, &app, true);
    Ok(())
}

#[tauri::command]
pub async fn update_correction(
    app: State<'_, Shared>,
    handle: AppHandle,
    pair: CorrectionPair,
) -> Done {
    app.library.lock().update_correction(pair);
    publish(&handle, &app, false);
    Ok(())
}

#[tauri::command]
pub async fn set_correction_enabled(
    app: State<'_, Shared>,
    handle: AppHandle,
    id: Uuid,
    on: bool,
) -> Done {
    app.library.lock().set_correction_enabled(id, on);
    publish(&handle, &app, false);
    Ok(())
}

#[tauri::command]
pub async fn delete_correction(app: State<'_, Shared>, handle: AppHandle, id: Uuid) -> Done {
    app.library.lock().delete_correction(id);
    publish(&handle, &app, false);
    Ok(())
}

/// A person typed into the sheet: added, then each "also heard as" spelling
/// becomes an alias that rewrites to the name, in the history too.
#[tauri::command]
pub async fn add_person(
    app: State<'_, Shared>,
    handle: AppHandle,
    name: String,
    aliases: Vec<String>,
    note: String,
) -> Done {
    {
        let mut library = app.library.lock();
        if library.add_person(&name, None, &note, false).is_some() {
            for alias in &aliases {
                library.add_alias(alias, &name);
            }
        }
    }
    publish(&handle, &app, true);
    Ok(())
}

#[tauri::command]
pub async fn update_person(app: State<'_, Shared>, handle: AppHandle, person: Person) -> Done {
    app.library.lock().update_person(person);
    publish(&handle, &app, false);
    Ok(())
}

#[tauri::command]
pub async fn set_person_enabled(
    app: State<'_, Shared>,
    handle: AppHandle,
    id: Uuid,
    on: bool,
) -> Done {
    app.library.lock().set_person_enabled(id, on);
    publish(&handle, &app, false);
    Ok(())
}

#[tauri::command]
pub async fn delete_person(app: State<'_, Shared>, handle: AppHandle, id: Uuid) -> Done {
    app.library.lock().delete_person(id);
    publish(&handle, &app, false);
    Ok(())
}

#[tauri::command]
pub async fn dismiss_retro_note(app: State<'_, Shared>, handle: AppHandle) -> Done {
    app.library.lock().dismiss_retro_note();
    publish(&handle, &app, false);
    Ok(())
}

/// Cheap enough to run on every keystroke in the editor.
#[tauri::command]
pub fn check_correction(hear: String, write: String) -> Vec<Warning> {
    safety::check(&hear, &write)
}

/// Where a word came up, to show beside it in the editor: the first line
/// that has it, newest transcript first, or the sentence around it.
#[tauri::command]
pub fn correction_context(app: State<'_, Shared>, word: String) -> String {
    let library = app.library.lock();
    let wanted = word.trim().to_lowercase();
    if wanted.is_empty() {
        return String::new();
    }
    for transcript in &library.history {
        if let Some(segment) = transcript
            .segments
            .iter()
            .find(|s| s.text.to_lowercase().contains(&wanted))
        {
            return segment.text.trim().to_string();
        }
        if transcript.text.to_lowercase().contains(&wanted) {
            return around(&transcript.text, &wanted, 140);
        }
    }
    word.trim().to_string()
}

fn around(text: &str, lowered_word: &str, reach: usize) -> String {
    let lowered = text.to_lowercase();
    let Some(at) = lowered.find(lowered_word) else {
        return text.trim().to_string();
    };
    let chars: Vec<(usize, char)> = text.char_indices().collect();
    let index = chars.iter().position(|(i, _)| *i >= at).unwrap_or(0);
    let from = index.saturating_sub(reach);
    let to = (index + lowered_word.chars().count() + reach).min(chars.len());
    chars[from..to]
        .iter()
        .map(|(_, c)| c)
        .collect::<String>()
        .trim()
        .to_string()
}

/// Selects the file in Explorer. The path comes from here, never the page.
#[tauri::command]
pub fn reveal_file(app: State<'_, Shared>, which: String) -> Done {
    let path = {
        let library = app.library.lock();
        if which == "people" {
            library.stores.people_path()
        } else {
            library.stores.dictionary_path()
        }
    };
    tauri_plugin_opener::reveal_item_in_dir(path).map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn delete_transcripts(app: State<'_, Shared>, handle: AppHandle, ids: Vec<Uuid>) -> Done {
    let history = {
        let mut library = app.library.lock();
        library.delete_transcripts(&ids);
        library.history.clone()
    };
    let _ = handle.emit("history", history);
    learning::refresh_soon(&handle, &app);
    Ok(())
}

/// Writes an export where the person chose in the save dialog.
#[tauri::command]
pub async fn write_export(path: String, contents: String) -> Done {
    std::fs::write(&path, contents).map_err(|e| format!("Couldn't save the export: {e}"))
}

/// Whether a transcript's recording can be played from its timecodes: it came
/// from a file, the file is still there, and the webview can decode it.
#[tauri::command]
pub fn is_playable(handle: AppHandle, app: State<'_, Shared>, id: Uuid) -> bool {
    const PLAYABLE: &[&str] = &[
        "mp3", "m4a", "aac", "wav", "flac", "ogg", "opus", "mp4", "m4v", "mov", "webm",
    ];
    let library = app.library.lock();
    let Some(transcript) = library.history.iter().find(|t| t.id == id) else {
        return false;
    };
    let path = std::path::Path::new(&transcript.source_path);
    let extension = path
        .extension()
        .map(|e| e.to_string_lossy().to_lowercase())
        .unwrap_or_default();
    let playable = !transcript.source_path.is_empty()
        && path.exists()
        && PLAYABLE.contains(&extension.as_str());
    // The page can read a file from disk only once the core has vouched for
    // it, one recording at a time, rather than through a scope that opens
    // the whole drive to it.
    if playable {
        if let Err(error) = handle.asset_protocol_scope().allow_file(path) {
            tracing::warn!(%error, "couldn't open the recording to playback");
            return false;
        }
    }
    playable
}
