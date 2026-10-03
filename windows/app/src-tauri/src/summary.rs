//! Meeting write-ups, from Qwen3 4B on this PC.
//!
//! The Mac's summary service has two engines, Apple's on-device model and a
//! downloaded Qwen3 4B; only the second can exist on Windows, and its path is
//! the simpler one. The model holds an hour of speech at once, so there is no
//! chunking, no consolidation and no second pass: the whole transcript goes
//! in with the Mac's instructions and its fixed headings, and the write-up
//! streams out as Markdown into the transcript's summary.
//!
//! The model is downloaded the first time a summary asks for it, kept in
//! memory afterwards so the next one starts at once, and released from
//! Settings or after ten idle minutes. Like everything else here it runs locally; the download is the
//! only network access, and it carries nothing of anyone's.
use std::sync::Arc;
use std::time::{Duration, Instant};

use chrono::{SecondsFormat, Utc};
use crossbeam_channel::{unbounded, Receiver, RecvTimeoutError, Sender};
use parking_lot::Mutex;
use serde::Serialize;
use tauri::{AppHandle, Emitter, State};
use uuid::Uuid;

use huh_core::model::Transcript;

use crate::llm::{self, Llm, Step};
use crate::{fetch, Shared};

/// The longest answer: the Mac's write-up is five short sections.
const MOST: usize = 1_024;

/// How long the model stays in memory with nothing to do. The Mac keeps it
/// until it is unloaded by hand; three gigabytes held for nothing is more than
/// many Windows laptops can spare, and loading it again takes seconds.
const IDLE: Duration = Duration::from_secs(10 * 60);

/// What the window shows about a summary under way, or the last one that
/// failed.
#[derive(Debug, Clone, Default, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SummaryState {
    pub running_for: Option<Uuid>,
    pub stage: String,
    /// Only while there is something real to measure: the download, and the
    /// reading of the transcript. A bar parked at a made-up number reads as a
    /// hang.
    pub progress: Option<f64>,
    pub streamed: String,
    pub failure: Option<String>,
}

/// The model, as Settings describes it.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SummaryModel {
    pub ready: bool,
    pub busy: bool,
    pub text: String,
}

enum Job {
    Summarise(Uuid),
    Unload,
}

#[derive(Debug, Clone, PartialEq)]
enum Held {
    Absent,
    Downloading { done: u64, total: u64 },
    Loading,
    Ready,
    Failed(String),
}

pub struct Summaries {
    state: Arc<Mutex<SummaryState>>,
    held: Arc<Mutex<Held>>,
    jobs: Sender<Job>,
    inbox: Mutex<Option<Receiver<Job>>>,
}

impl Default for Summaries {
    fn default() -> Self {
        let (jobs, inbox) = unbounded();
        Self {
            state: Arc::default(),
            held: Arc::new(Mutex::new(Held::Absent)),
            jobs,
            inbox: Mutex::new(Some(inbox)),
        }
    }
}

impl Summaries {
    pub fn state(&self) -> SummaryState {
        self.state.lock().clone()
    }

    pub fn model(&self) -> SummaryModel {
        describe(&self.held.lock())
    }
}

/// The Mac's `statusText`, for this PC.
fn describe(held: &Held) -> SummaryModel {
    let size = fetch::readable(llm::download_size());
    let (ready, busy, text) = match held {
        Held::Absent if fetch::present(&llm::directory(), &llm::PARTS) => (
            false,
            false,
            "Downloaded. Loads into memory when a summary needs it.".to_string(),
        ),
        Held::Absent => (
            false,
            false,
            format!("Not downloaded. About {size}, fetched once when a summary first needs it."),
        ),
        Held::Downloading { done, total } => (false, true, downloading(*done, *total)),
        Held::Loading => (false, true, "Loading into memory…".to_string()),
        Held::Ready => (true, false, "Ready. Runs on this PC, offline.".to_string()),
        Held::Failed(why) => (false, false, why.clone()),
    };
    SummaryModel { ready, busy, text }
}

fn downloading(done: u64, total: u64) -> String {
    let percent = (done * 100 / total.max(1)).min(100);
    format!(
        "Downloading {} — {percent}%  ({} of {})",
        llm::DISPLAY_NAME,
        fetch::readable(done),
        fetch::readable(total)
    )
}

/// Starts the worker that owns the model. The model never leaves its thread:
/// a session several gigabytes in size is not something to share.
pub fn start(handle: &AppHandle, app: &Shared) {
    let Some(inbox) = app.summaries.inbox.lock().take() else {
        return;
    };
    let handle = handle.clone();
    let app = app.clone();
    let _ = std::thread::Builder::new()
        .name("huh-summaries".into())
        .spawn(move || {
            let mut model: Option<Llm> = None;
            loop {
                let job = match inbox.recv_timeout(IDLE) {
                    Ok(job) => job,
                    // Nobody has asked for a while: the memory goes back to
                    // the PC, and the next summary waits a few seconds more.
                    Err(RecvTimeoutError::Timeout) if model.is_some() => Job::Unload,
                    Err(RecvTimeoutError::Timeout) => continue,
                    Err(RecvTimeoutError::Disconnected) => break,
                };
                match job {
                    Job::Summarise(id) => run(&handle, &app, &mut model, id),
                    Job::Unload => {
                        model = None;
                        *app.summaries.held.lock() = Held::Absent;
                        publish_model(&handle, &app);
                    }
                }
            }
        });
}

fn publish(handle: &AppHandle, app: &Shared) {
    let _ = handle.emit("summary", app.summaries.state());
}

fn publish_model(handle: &AppHandle, app: &Shared) {
    let _ = handle.emit("summary-model", app.summaries.model());
}

fn set_stage(handle: &AppHandle, app: &Shared, stage: String, progress: Option<f64>) {
    {
        let mut state = app.summaries.state.lock();
        state.stage = stage;
        state.progress = progress;
    }
    publish(handle, app);
}

fn run(handle: &AppHandle, app: &Shared, model: &mut Option<Llm>, id: Uuid) {
    let started = Instant::now();
    let result = write_up(handle, app, model, id);
    {
        let mut state = app.summaries.state.lock();
        state.running_for = None;
        state.stage.clear();
        state.progress = None;
        state.streamed.clear();
        if let Err(why) = &result {
            state.failure = Some(why.clone());
        }
    }
    match result {
        Ok(()) => tracing::info!(elapsed = ?started.elapsed(), "summarised"),
        Err(why) => tracing::warn!(%why, "summary failed"),
    }
    publish(handle, app);
    publish_model(handle, app);
}

fn write_up(
    handle: &AppHandle,
    app: &Shared,
    model: &mut Option<Llm>,
    id: Uuid,
) -> Result<(), String> {
    let transcript = find(app, id)?;

    // The model may not be on disk yet. Downloading is the one part of this
    // with a real percentage, so it owns the bar.
    if model.is_none() {
        let folder = llm::directory();
        if !fetch::present(&folder, &llm::PARTS) {
            let mut last = 0u64;
            let mut announced = Instant::now();
            fetch::download(&llm::SOURCE, &folder, &llm::PARTS, &mut |done, total| {
                *app.summaries.held.lock() = Held::Downloading { done, total };
                // A few times a second is enough for a bar, and far fewer
                // events than one per network read.
                if done == total || done - last > 8 << 20 || announced.elapsed().as_millis() > 250 {
                    last = done;
                    announced = Instant::now();
                    set_stage(
                        handle,
                        app,
                        downloading(done, total),
                        Some(done as f64 / total.max(1) as f64),
                    );
                    publish_model(handle, app);
                }
            })
            .map_err(|why| {
                let message = readable_download_error(&why);
                *app.summaries.held.lock() = Held::Failed(message.clone());
                message
            })?;
        }
        *app.summaries.held.lock() = Held::Loading;
        set_stage(handle, app, "Loading into memory…".into(), None);
        publish_model(handle, app);
        let loaded = Llm::load(&folder).inspect_err(|why| {
            *app.summaries.held.lock() = Held::Failed(why.clone());
        })?;
        *model = Some(loaded);
        *app.summaries.held.lock() = Held::Ready;
        publish_model(handle, app);
    }
    let Some(model) = model.as_mut() else {
        return Err("The model isn't loaded.".into());
    };

    let names: Vec<String> = app
        .library
        .lock()
        .people
        .people
        .iter()
        .filter(|p| p.enabled)
        .take(20)
        .map(|p| p.name.clone())
        .collect();
    let instructions = instructions(&names);
    let prompt = format!("{HEADINGS}\n\nTranscript:\n{}", body(&transcript));

    set_stage(handle, app, "Reading the whole meeting…".into(), Some(0.0));
    let text = model.respond(&instructions, &prompt, MOST, &mut |step| match step {
        Step::Reading { done, total } => set_stage(
            handle,
            app,
            "Reading the whole meeting…".into(),
            Some(done as f64 / total.max(1) as f64),
        ),
        Step::Writing { text } => {
            {
                let mut state = app.summaries.state.lock();
                state.stage = format!("Writing it up… {} words", text.split_whitespace().count());
                state.progress = None;
                state.streamed = text.to_string();
            }
            publish(handle, app);
        }
    })?;
    if text.is_empty() {
        return Err("The model wrote nothing. Try again.".into());
    }

    // Saved onto the transcript as it is now, not as it was when this began:
    // a correction applied meanwhile must not be undone by the summary.
    let history = {
        let mut library = app.library.lock();
        let Some(mut current) = library.history.iter().find(|t| t.id == id).cloned() else {
            return Err("That transcript was deleted while it was being summarised.".into());
        };
        current.summary = text;
        current.summary_date = Some(Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true));
        library.update_transcript(current);
        library.history.clone()
    };
    let _ = handle.emit("history", history);
    Ok(())
}

fn find(app: &Shared, id: Uuid) -> Result<Transcript, String> {
    app.library
        .lock()
        .history
        .iter()
        .find(|t| t.id == id)
        .cloned()
        .ok_or_else(|| "That transcript is no longer in the history.".to_string())
}

/// The transcript as the model reads it: the lines, joined, or the text.
fn body(transcript: &Transcript) -> String {
    if transcript.segments.is_empty() {
        transcript.text.clone()
    } else {
        transcript
            .segments
            .iter()
            .map(|s| s.text.as_str())
            .collect::<Vec<_>>()
            .join(" ")
    }
}

/// The Mac's instructions, with the people already known as its roster.
fn instructions(names: &[String]) -> String {
    let roster = if names.is_empty() {
        String::new()
    } else {
        format!(
            "\n\nPeople already known by name: {}. Prefer these spellings where the transcript is clearly referring to them.",
            names.join(", ")
        )
    };
    format!(
        "You write up meeting notes from a transcript produced by a speech recogniser. \
         The transcript is imperfect: names may be misspelled and sentences garbled. \
         Work only from what is there. Never invent a name, a date, an owner or a \
         decision, and never assign a task to someone the transcript does not name.{roster}"
    )
}

/// The Mac's headings, word for word, so a summary written on either reads
/// the same.
const HEADINGS: &str =
    "Use exactly these headings, in this order. If a section has nothing, write \
\"None recorded.\" under it.

## In one line
One sentence: what this was about and what came of it.

## What was discussed
Three to five short bullets.

## Decisions
Bullets. Only what was actually settled.

## Action items
Bullets formatted \"Owner — task\". Write \"Unassigned\" when no owner is named.

## Open questions
Bullets.";

/// The Mac's wording for a download that failed on the network.
fn readable_download_error(why: &str) -> String {
    let lowered = why.to_lowercase();
    if lowered.contains("could not be fetched")
        || lowered.contains("stopped arriving")
        || lowered.contains("network")
        || lowered.contains("dns")
        || lowered.contains("connect")
    {
        "Couldn't download the model — check your connection and try again.".into()
    } else {
        format!("Couldn't download the model: {why}")
    }
}

/* ── Commands ── */

type Done = Result<(), String>;

#[tauri::command]
pub fn summarise(app: State<'_, Shared>, handle: AppHandle, id: Uuid) -> Done {
    {
        let mut state = app.summaries.state.lock();
        if let Some(running) = state.running_for {
            let name = find(&app, running)
                .map(|t| t.display_name())
                .unwrap_or_else(|_| "another transcript".into());
            return Err(format!("Already summarising {name}."));
        }
        find(&app, id)?;
        *state = SummaryState {
            running_for: Some(id),
            stage: "Reading the transcript…".into(),
            progress: None,
            streamed: String::new(),
            failure: None,
        };
    }
    publish(&handle, &app);
    app.summaries
        .jobs
        .send(Job::Summarise(id))
        .map_err(|_| "Summaries have stopped. Quit and reopen huh? to carry on.".to_string())
}

#[tauri::command]
pub fn summary_state(app: State<'_, Shared>) -> SummaryState {
    app.summaries.state()
}

#[tauri::command]
pub fn dismiss_summary_failure(app: State<'_, Shared>, handle: AppHandle) {
    app.summaries.state.lock().failure = None;
    publish(&handle, &app);
}

#[tauri::command]
pub fn summary_model(app: State<'_, Shared>) -> SummaryModel {
    app.summaries.model()
}

/// Frees the model's memory. Refused while a summary is using it.
#[tauri::command]
pub fn unload_summary_model(app: State<'_, Shared>) -> Done {
    if app.summaries.state.lock().running_for.is_some() {
        return Err("A summary is being written. Unload it once that has finished.".into());
    }
    app.summaries
        .jobs
        .send(Job::Unload)
        .map_err(|_| "Summaries have stopped. Quit and reopen huh? to carry on.".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_roster_is_offered_only_when_there_is_one() {
        assert!(!instructions(&[]).contains("People already known"));
        let with = instructions(&["Ada Okonkwo".into(), "Lena Vasquez".into()]);
        assert!(with.ends_with(
            "People already known by name: Ada Okonkwo, Lena Vasquez. Prefer these spellings where the transcript is clearly referring to them."
        ));
    }

    #[test]
    fn the_headings_are_the_macs() {
        for heading in [
            "## In one line",
            "## What was discussed",
            "## Decisions",
            "## Action items",
            "## Open questions",
        ] {
            assert!(HEADINGS.contains(heading));
        }
        assert!(HEADINGS.starts_with("Use exactly these headings, in this order. If a section has nothing, write \"None recorded.\" under it."));
    }

    #[test]
    fn the_download_reads_as_settings_says_it() {
        assert_eq!(
            downloading(1_200_000_000, 2_897_377_162),
            "Downloading Qwen3 4B — 41%  (1.2 GB of 2.9 GB)"
        );
    }
}
