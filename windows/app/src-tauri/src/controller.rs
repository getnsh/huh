//! Dictation from key to cursor, in the order the Mac's `DictationController`
//! runs it: show the overlay, open the microphone, hear the utterance out,
//! recognise it, apply the dictionary, clean it up, type it, keep it.
//!
//! None of it runs on the interface's thread. A press is handled on the
//! hotkey's dispatch thread and returns once the microphone is open; a release
//! hands the recording to a thread of its own, so recognition -- the slow part
//! -- can never hold up the next keypress.
use std::sync::atomic::Ordering;
use std::time::Duration;

use tauri::{AppHandle, Emitter};

use huh_core::settings::{InjectionMode, TriggerMode};
use huh_core::{cleanup, corrections, Transcript, TranscriptSource};

use crate::dictation::{Ending, Opened, State};
use crate::inject::{self, Outcome};
use crate::speech::{Status, ENGINE_NAME};
use crate::{audio, overlay, Shared};

/// How long the overlay holds a confirmation, as on the Mac.
const CONFIRMATION: Duration = Duration::from_millis(1400);
/// How long a failure stays up, as on the Mac.
const FAILURE: Duration = Duration::from_secs(2);
/// The meter's frame interval; `LevelMeter.svelte` redraws at the same 30 Hz.
const METER_INTERVAL: Duration = Duration::from_millis(33);
/// The pause between one live preview arriving and the next being asked for.
/// Each preview takes as long as recognition takes, so this is a floor on the
/// interval rather than the interval itself.
const PREVIEW_PAUSE: Duration = Duration::from_millis(250);
/// How much of the utterance a preview reads. The overlay shows the last four
/// lines, which is less than this much speech, so reading more would cost time
/// and show nothing.
const PREVIEW_WINDOW: f64 = 20.0;
/// Below this, there is nothing worth previewing yet.
const PREVIEW_MINIMUM: f64 = 0.6;

/// Shown when the microphone hands over perfect silence for a reason the
/// check before opening it did not catch.
const ONLY_SILENCE: &str = "The microphone sent only silence. Check which one is selected in \
    Settings › System › Sound.";

pub fn key_down(handle: &AppHandle, app: &Shared) {
    let mode = app.settings.read().trigger_mode;
    match mode {
        TriggerMode::Hold => begin(handle, app),
        TriggerMode::Toggle => toggle(handle, app),
    }
}

pub fn key_up(handle: &AppHandle, app: &Shared) {
    if app.settings.read().trigger_mode != TriggerMode::Hold {
        return;
    }
    let ending = app.dictation.release();
    conclude(handle, app, ending);
}

/// Starts and stops from the window, or from the key in toggle mode.
pub fn toggle(handle: &AppHandle, app: &Shared) {
    if app.dictation.state().is_busy() {
        let ending = app.dictation.stop();
        conclude(handle, app, ending);
    } else {
        begin(handle, app);
    }
}

fn publish(handle: &AppHandle, app: &Shared) {
    let _ = handle.emit("dictation", app.dictation.state());
}

fn begin(handle: &AppHandle, app: &Shared) {
    if !app.dictation.begin() {
        return;
    }
    let utterance = app.utterances.fetch_add(1, Ordering::SeqCst) + 1;
    publish(handle, app);
    overlay::show(handle);

    // Before the microphone: a press during the first-launch download should
    // say so, not record something there is nothing to transcribe with.
    match app.recogniser.status() {
        Status::Downloading { percent } => {
            return fail(
                handle,
                app,
                format!("Parakeet is still downloading — {percent}%."),
            );
        }
        Status::Failed { message } => {
            app.recogniser.retry();
            return fail(handle, app, message);
        }
        _ => {}
    }
    if let Some(problem) = audio::input_problem() {
        return fail(handle, app, problem);
    }

    if let Err(message) = app.recorder.start() {
        return fail(handle, app, message);
    }
    match app.dictation.opened() {
        Opened::Listening => {
            publish(handle, app);
            meter(handle, app, utterance);
            preview(handle, app, utterance);
        }
        Opened::Transcribe => {
            publish(handle, app);
            transcribe(handle, app);
        }
        Opened::Abandoned => {
            let _ = app.recorder.stop();
        }
    }
}

fn conclude(handle: &AppHandle, app: &Shared, ending: Ending) {
    match ending {
        Ending::Cancelled => {
            let _ = app.recorder.stop();
            publish(handle, app);
            overlay::hide(handle, overlay::current());
        }
        Ending::Transcribe => {
            publish(handle, app);
            transcribe(handle, app);
        }
        Ending::Deferred | Ending::Ignored => {}
    }
}

/// Sends the meter to every window while the microphone is open.
fn meter(handle: &AppHandle, app: &Shared, utterance: u64) {
    let handle = handle.clone();
    let app = app.clone();
    let _ = std::thread::Builder::new()
        .name("huh-meter".into())
        .spawn(move || {
            while app.utterances.load(Ordering::SeqCst) == utterance
                && matches!(app.dictation.state(), State::Starting | State::Listening)
            {
                let _ = handle.emit("levels", app.recorder.meter.history());
                std::thread::sleep(METER_INTERVAL);
            }
            let _ = handle.emit("levels", Vec::<audio::Level>::new());
        });
}

/// The words so far, while the key is held, as the Mac's overlay shows them.
///
/// Parakeet does not stream, so each preview recognises the utterance again
/// from the top, or its last twenty seconds once it is longer than that. One
/// is in flight at a time, and the recogniser drops a preview rather than make
/// the final pass wait for it.
fn preview(handle: &AppHandle, app: &Shared, utterance: u64) {
    let handle = handle.clone();
    let app = app.clone();
    let _ = std::thread::Builder::new()
        .name("huh-preview".into())
        .spawn(move || {
            let current = || app.utterances.load(Ordering::SeqCst) == utterance;
            let mut heard = 0usize;
            while current() && app.dictation.state() == State::Listening {
                std::thread::sleep(PREVIEW_PAUSE);
                let recording = app.recorder.recent(PREVIEW_WINDOW);
                let total = app.dictation.since_begin().as_secs_f64();
                if recording.seconds() < PREVIEW_MINIMUM || recording.samples.len() == heard {
                    continue;
                }
                heard = recording.samples.len();
                let clipped = total > PREVIEW_WINDOW;
                let Some(text) = app.recogniser.preview(recording.for_speech()) else {
                    continue;
                };
                // A preview that finishes after the key came up still shows:
                // it is the newest text there is until the final pass lands.
                let still_relevant = current()
                    && matches!(
                        app.dictation.state(),
                        State::Listening | State::Transcribing
                    );
                if still_relevant && !text.is_empty() {
                    let shown = if clipped { format!("…{text}") } else { text };
                    let _ = handle.emit("partial", shown);
                }
            }
        });
}

fn transcribe(handle: &AppHandle, app: &Shared) {
    let recording = app.recorder.stop();
    let handle = handle.clone();
    let app = app.clone();
    let _ = std::thread::Builder::new()
        .name("huh-transcribe".into())
        .spawn(move || {
            if recording.seconds() > 0.5 && recording.is_blank() {
                return fail(&handle, &app, ONLY_SILENCE.into());
            }
            let raw = match app.recogniser.transcribe(recording.for_speech()) {
                Ok(text) => text,
                Err(message) => return fail(&handle, &app, message),
            };
            let outcome = if raw.is_empty() {
                Outcome::nothing_heard()
            } else {
                deliver(&handle, &app, raw)
            };
            app.dictation.finish();
            publish(&handle, &app);
            confirm(&handle, outcome);
        });
}

/// The dictionary, cleanup, insertion and the history, in the Mac's order.
fn deliver(handle: &AppHandle, app: &Shared, raw: String) -> Outcome {
    // The deterministic pass. Bias toward the dictionary is only advice to a
    // recogniser; this is what enforces it.
    let corrected = corrections::apply(&raw, &app.stores.corrections());
    if let Err(error) = app.stores.record_hits(&corrected.applied) {
        tracing::warn!(%error, "could not record correction hits");
    }

    // Corrections first, against the recogniser's literal output; cleanup then
    // works on the result.
    let settings = app.settings.read().clone();
    let cleaned = cleanup::apply(&corrected.text, settings.cleanup_level);
    let outcome = inject::insert(
        &cleaned.text,
        settings.injection_mode == InjectionMode::AlwaysPaste,
    );

    let transcript = Transcript {
        analysis_findings: 0,
        analyzed_at: None,
        cleanup_removed: cleaned.removed as u32,
        corrections: corrected.applied,
        date: chrono::Utc::now(),
        duration: app.dictation.since_begin().as_secs_f64(),
        engine: ENGINE_NAME.into(),
        id: uuid::Uuid::new_v4(),
        raw,
        segments: Vec::new(),
        source: TranscriptSource::Dictation,
        source_name: String::new(),
        source_path: String::new(),
        summary: String::new(),
        summary_date: None,
        text: cleaned.text,
    };
    match app.stores.add_transcript(transcript.clone()) {
        Ok(()) => {
            let _ = handle.emit("transcript", &transcript);
        }
        Err(error) => tracing::error!(%error, "could not save the transcript"),
    }
    outcome
}

/// Holds the overlay long enough to be read, then lets it go. Dictation
/// happens while another application has focus, where a silent success is
/// indistinguishable from a failure.
fn confirm(handle: &AppHandle, outcome: Outcome) {
    let _ = handle.emit("delivered", &outcome);
    let generation = overlay::current();
    let handle = handle.clone();
    std::thread::spawn(move || {
        std::thread::sleep(CONFIRMATION);
        overlay::hide(&handle, generation);
    });
}

fn fail(handle: &AppHandle, app: &Shared, message: String) {
    tracing::warn!(%message, "dictation failed");
    let _ = app.recorder.stop();
    app.dictation.fail(message);
    publish(handle, app);
    let generation = overlay::current();
    let handle = handle.clone();
    let app = app.clone();
    std::thread::spawn(move || {
        std::thread::sleep(FAILURE);
        if app.dictation.clear_failure() {
            publish(&handle, &app);
        }
        overlay::hide(&handle, generation);
    });
}
