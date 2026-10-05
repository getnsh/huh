//! Live sessions: a meeting or call transcribed as it happens, you and the
//! room apart, in the small panel that floats at the top of the screen.
//!
//! The Mac's `LiveSession`. Two streams -- the microphone, and what the PC is
//! playing -- each go to a voice of their own. A voice cuts its audio into
//! pieces at the natural pauses, or at twelve seconds when nobody pauses, and
//! each piece is recognised into sentences that settle as lines: the
//! dictionary and cleanup applied, timed from the start of the session, and
//! joined to the line before when the same voice is still talking. While a
//! voice is mid-sentence its words so far show as a grey draft, re-read the
//! way dictation's overlay re-reads them, giving way to every other job.
//!
//! A session starts from the button, the tray, Ctrl+Shift+M, or a call being
//! noticed: offered in the panel, or begun at once when that is the setting.
//! Stopping finishes both voices, saves the lines as a meeting transcript and
//! offers to open it. The Mac's Parakeet sessions saved nothing, because that
//! engine never finalised a line; this one settles every line it hears.
use std::collections::HashSet;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use chrono::{DateTime, Utc};
use crossbeam_channel::{unbounded, Receiver, RecvTimeoutError};
use parking_lot::Mutex;
use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Emitter, Manager, State, WebviewUrl, WebviewWindowBuilder};
use uuid::Uuid;

use huh_core::model::{Transcript, TranscriptSegment, TranscriptSource};
use huh_core::{cleanup, corrections};

use crate::audio::{self, Meter};
use crate::capture::{self, Source};
use crate::speech::ENGINE_NAME;
use crate::{chrome, learning, meetings, Shared};

const PANEL: &str = "panel";

/// A line keeps growing while the same voice talks, up to about this many
/// characters, then a new line starts.
const JOIN_LIMIT: usize = 320;
/// Silence that ends a piece.
const PAUSE: Duration = Duration::from_millis(450);
/// The longest piece; past this a voice is cut at its quietest moment.
const LONGEST: f64 = 12.0;
/// The shortest piece worth recognising.
const SHORTEST: f64 = 1.0;
/// How often the meters are sent to the panel.
const METER_INTERVAL: Duration = Duration::from_millis(33);
/// How long a finished session's panel stays before going.
const LINGER: Duration = Duration::from_secs(14);
/// How often the microphone's users are checked for a call.
const CALL_POLL: Duration = Duration::from_millis(500);
/// How long the page takes to slide the panel out before the window goes:
/// the Mac's 0.2 s, and a frame to spare.
const SLIDE_OUT: Duration = Duration::from_millis(220);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Voice {
    You,
    Room,
}

impl Voice {
    fn saved_label(self) -> &'static str {
        match self {
            Voice::You => "You",
            Voice::Room => "Room",
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct SessionLine {
    pub id: Uuid,
    pub voice: Voice,
    pub text: String,
    /// Seconds from the start of the session.
    pub at: f64,
}

#[derive(Debug, Clone, PartialEq)]
enum Trigger {
    Manual,
    Meeting(String),
}

impl Trigger {
    fn label(&self) -> String {
        match self {
            Trigger::Manual => "Listening".into(),
            Trigger::Meeting(app) => app.clone(),
        }
    }

    fn past_label(&self) -> String {
        match self {
            Trigger::Manual => "Live session".into(),
            Trigger::Meeting(app) => app.clone(),
        }
    }

    fn room_label(&self) -> String {
        match self {
            Trigger::Manual => "PC".into(),
            Trigger::Meeting(app) => app.clone(),
        }
    }
}

/// Everything the panel and the main window draw about a session.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionState {
    pub running: bool,
    pub stopping: bool,
    pub label: String,
    pub past_label: String,
    pub room_label: String,
    pub started_at: Option<String>,
    pub final_duration: Option<f64>,
    pub hears_you: bool,
    pub hears_room: bool,
    /// A voice that is open but paused: its stream keeps running and is
    /// heard as silence, so nothing said while paused reaches the record.
    pub you_paused: bool,
    pub room_paused: bool,
    pub status_message: Option<String>,
    pub saved_transcript: Option<Uuid>,
    pub expanded: bool,
    pub visible: bool,
    pub offer: Option<String>,
    /// The app a call is running in right now, offered or not.
    pub call: Option<String>,
    pub lines: Vec<SessionLine>,
    pub you_draft: String,
    pub room_draft: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct SessionLevels {
    pub you: Vec<f32>,
    pub room: Vec<f32>,
}

struct Inner {
    running: bool,
    stopping: bool,
    trigger: Trigger,
    started_at: Option<DateTime<Utc>>,
    started: Option<Instant>,
    final_duration: Option<f64>,
    hears_you: bool,
    hears_room: bool,
    status_message: Option<String>,
    saved_transcript: Option<Uuid>,
    expanded: bool,
    visible: bool,
    offer: Option<String>,
    call: Option<String>,
    declined: HashSet<String>,
    lines: Vec<SessionLine>,
    you_draft: String,
    room_draft: String,
    streams: Vec<capture::Stream>,
    voices: Vec<std::thread::JoinHandle<()>>,
    /// Where the panel's top-left corner sits, in physical pixels.
    anchor: Option<(i32, i32)>,
    /// The panel's size in logical pixels, as the page last measured it.
    size: (f64, f64),
}

impl Default for Inner {
    fn default() -> Self {
        Self {
            running: false,
            stopping: false,
            trigger: Trigger::Manual,
            started_at: None,
            started: None,
            final_duration: None,
            hears_you: false,
            hears_room: false,
            status_message: None,
            saved_transcript: None,
            expanded: true,
            visible: false,
            offer: None,
            call: None,
            declined: HashSet::new(),
            lines: Vec::new(),
            you_draft: String::new(),
            room_draft: String::new(),
            streams: Vec::new(),
            voices: Vec::new(),
            anchor: None,
            size: (388.0, 240.0),
        }
    }
}

#[derive(Default)]
pub struct Session {
    inner: Mutex<Inner>,
    you: Arc<Meter>,
    room: Arc<Meter>,
    /// Read by each stream's callback for every block, so they live outside
    /// the lock the voices and the panel contend for.
    you_paused: Arc<AtomicBool>,
    room_paused: Arc<AtomicBool>,
    /// Bumped by every start, so a voice from an earlier session cannot write
    /// into this one.
    generation: AtomicU64,
    /// Set while the panel is being dragged.
    dragging: Arc<AtomicBool>,
}

impl Session {
    pub fn state(&self) -> SessionState {
        let inner = self.inner.lock();
        SessionState {
            running: inner.running,
            stopping: inner.stopping,
            label: inner.trigger.label(),
            past_label: inner.trigger.past_label(),
            room_label: inner.trigger.room_label(),
            started_at: inner
                .started_at
                .map(|at| at.to_rfc3339_opts(chrono::SecondsFormat::Millis, true)),
            final_duration: inner.final_duration,
            hears_you: inner.hears_you,
            hears_room: inner.hears_room,
            you_paused: self.you_paused.load(Ordering::SeqCst),
            room_paused: self.room_paused.load(Ordering::SeqCst),
            status_message: inner.status_message.clone(),
            saved_transcript: inner.saved_transcript,
            expanded: inner.expanded,
            visible: inner.visible,
            offer: inner.offer.clone(),
            call: inner.call.clone(),
            lines: inner.lines.clone(),
            you_draft: inner.you_draft.clone(),
            room_draft: inner.room_draft.clone(),
        }
    }

    fn elapsed(&self) -> f64 {
        self.inner
            .lock()
            .started
            .map(|at| at.elapsed().as_secs_f64())
            .unwrap_or(0.0)
    }
}

/* ── Telling the windows ── */

fn publish(handle: &AppHandle, app: &Shared) {
    let state = app.session.state();
    panel::follow(handle, app, &state);
    let _ = handle.emit("session", state);
    crate::tray::refresh(handle);
}

/* ── Starting and stopping ── */

fn start(handle: &AppHandle, app: &Shared, trigger: Trigger) {
    let generation = {
        let mut inner = app.session.inner.lock();
        if inner.running || inner.stopping {
            return;
        }
        let anchor = inner.anchor;
        let declined = std::mem::take(&mut inner.declined);
        let call = inner.call.clone();
        *inner = Inner {
            running: true,
            trigger: trigger.clone(),
            started_at: Some(Utc::now()),
            started: Some(Instant::now()),
            visible: true,
            expanded: false,
            anchor,
            declined,
            call,
            ..Inner::default()
        };
        app.session.generation.fetch_add(1, Ordering::SeqCst) + 1
    };
    app.session.you.clear();
    app.session.room.clear();
    app.session.you_paused.store(false, Ordering::SeqCst);
    app.session.room_paused.store(false, Ordering::SeqCst);
    publish(handle, app);

    // The room first, then you, as the Mac opens them. Either can fail alone
    // and the session carries on with the other.
    let room = open_voice(handle, app, Voice::Room, Source::System, generation);
    let you = open_voice(handle, app, Voice::You, Source::Microphone, generation);
    {
        let mut inner = app.session.inner.lock();
        match (&room, &you) {
            (Err(_), Err(_)) => {
                inner.status_message = Some("Nothing to listen to.".into());
            }
            (Err(why), Ok(_)) => {
                inner.status_message = Some(format!("Only hearing you. {why}"));
            }
            (Ok(_), Err(why)) => {
                inner.status_message = Some(format!("Only hearing your PC. {why}"));
            }
            _ => {}
        }
        inner.hears_room = room.is_ok();
        inner.hears_you = you.is_ok();
        for opened in [room, you].into_iter().flatten() {
            inner.streams.push(opened.0);
            inner.voices.push(opened.1);
        }
    }
    // Read under one lock: two `lock()` calls in one condition would hold
    // the first guard while asking for the second, and wait forever.
    let heard_anything = {
        let inner = app.session.inner.lock();
        inner.hears_you || inner.hears_room
    };
    if !heard_anything {
        close(handle, app, false);
        return;
    }
    meter(handle, app, generation);
    publish(handle, app);
}

/// Asks both voices to finish, then saves.
fn stop(handle: &AppHandle, app: &Shared) {
    {
        let mut inner = app.session.inner.lock();
        if !inner.running || inner.stopping {
            return;
        }
        inner.stopping = true;
    }
    publish(handle, app);
    let handle = handle.clone();
    let app = app.clone();
    std::thread::spawn(move || close(&handle, &app, true));
}

/// Closes the streams, waits for the voices to settle their last words, and,
/// when asked to, keeps what was heard.
fn close(handle: &AppHandle, app: &Shared, save: bool) {
    let (streams, voices) = {
        let mut inner = app.session.inner.lock();
        (
            std::mem::take(&mut inner.streams),
            std::mem::take(&mut inner.voices),
        )
    };
    // Dropping the streams closes the devices and ends the voices' input,
    // which is their signal to finish.
    drop(streams);
    for voice in voices {
        let _ = voice.join();
    }

    let elapsed = app.session.elapsed();
    let saved = {
        let mut inner = app.session.inner.lock();
        inner.final_duration = Some(elapsed);
        inner.expanded = true;
        inner.you_draft.clear();
        inner.room_draft.clear();
        inner.hears_you = false;
        inner.hears_room = false;
        inner.running = false;
        inner.stopping = false;
        if save && !inner.lines.is_empty() {
            Some(persist(&inner, elapsed))
        } else {
            None
        }
    };

    match saved {
        Some(transcript) => {
            let id = transcript.id;
            let history = {
                let mut library = app.library.lock();
                library.add_transcript(transcript.clone());
                library.history.clone()
            };
            let _ = handle.emit("transcript", &transcript);
            let _ = handle.emit("history", history);
            learning::schedule_queue(app);
            app.session.inner.lock().saved_transcript = Some(id);
            publish(handle, app);
            // The panel stays long enough to open what was saved, then goes.
            let handle = handle.clone();
            let app = app.clone();
            std::thread::spawn(move || {
                std::thread::sleep(LINGER);
                let mut inner = app.session.inner.lock();
                if !inner.running && inner.saved_transcript == Some(id) {
                    inner.visible = false;
                    inner.saved_transcript = None;
                    drop(inner);
                    publish(&handle, &app);
                }
            });
        }
        None => {
            {
                let mut inner = app.session.inner.lock();
                // A failure is shown with a way to close it; a session that
                // simply heard nothing goes.
                inner.visible = inner.status_message.is_some() && !save;
            }
            publish(handle, app);
        }
    }
}

/// The Mac's saved shape: each line labelled "You" or "Room", the same text
/// as the transcript and as its timecoded lines.
fn persist(inner: &Inner, elapsed: f64) -> Transcript {
    let labelled: Vec<(f64, String)> = inner
        .lines
        .iter()
        .map(|line| {
            (
                line.at,
                format!("{}: {}", line.voice.saved_label(), line.text),
            )
        })
        .collect();
    let text = labelled
        .iter()
        .map(|(_, line)| line.as_str())
        .collect::<Vec<_>>()
        .join("\n\n");
    Transcript {
        analysis_findings: 0,
        analyzed_at: None,
        cleanup_removed: 0,
        corrections: Vec::new(),
        date: inner.started_at.unwrap_or_else(Utc::now),
        duration: elapsed,
        engine: ENGINE_NAME.into(),
        id: Uuid::new_v4(),
        raw: text.clone(),
        segments: labelled
            .into_iter()
            .map(|(start, text)| TranscriptSegment {
                id: Uuid::new_v4(),
                start,
                text,
            })
            .collect(),
        source: TranscriptSource::Meeting,
        source_name: inner.trigger.past_label(),
        source_path: String::new(),
        summary: String::new(),
        summary_date: None,
        text,
    }
}

/* ── A voice ── */

type Opened = (capture::Stream, std::thread::JoinHandle<()>);

fn open_voice(
    handle: &AppHandle,
    app: &Shared,
    voice: Voice,
    source: Source,
    generation: u64,
) -> Result<Opened, String> {
    let (blocks, inbox) = unbounded::<(Vec<f32>, u32)>();
    let (meter, paused) = match voice {
        Voice::You => (app.session.you.clone(), app.session.you_paused.clone()),
        Voice::Room => (app.session.room.clone(), app.session.room_paused.clone()),
    };
    let sink_meter = meter.clone();
    let mut pending_level: Vec<f32> = Vec::new();
    let mut silence: Vec<f32> = Vec::new();
    let stream = capture::Stream::open(
        source,
        Box::new(move |block, rate| {
            // Paused, the voice still gets a block of the same length, only
            // silent: the session's clock stays true, the meter falls flat,
            // and a sentence cut off by the pause settles at the gap the way
            // it would at any other.
            let block = if paused.load(Ordering::Relaxed) {
                silence.clear();
                silence.resize(block.len(), 0.0);
                &silence[..]
            } else {
                block
            };
            // A level per 1/44 s, as dictation's meter takes them.
            pending_level.extend_from_slice(block);
            let size = (rate as usize / audio::HISTORY_DEPTH).max(1);
            while pending_level.len() >= size {
                sink_meter.push(audio::level_of(&pending_level[..size]));
                pending_level.drain(..size);
            }
            let _ = blocks.send((block.to_vec(), rate));
        }),
    )?;
    let handle = handle.clone();
    let app = app.clone();
    let worker = std::thread::Builder::new()
        .name(match voice {
            Voice::You => "huh-voice-you".into(),
            Voice::Room => "huh-voice-room".into(),
        })
        .spawn(move || listen(&handle, &app, voice, inbox, generation))
        .map_err(|e| e.to_string())?;
    Ok((stream, worker))
}

/// The floor under which a frame is silence: a little above the quietest the
/// stream has been lately, and never below an absolute minimum, which is
/// lower for the PC's own sound because it carries no room noise.
struct Gate {
    floor: f32,
    minimum: f32,
}

impl Gate {
    fn new(voice: Voice) -> Self {
        Self {
            floor: 0.0,
            minimum: match voice {
                Voice::You => 0.012,
                Voice::Room => 0.004,
            },
        }
    }

    fn is_speech(&mut self, rms: f32) -> bool {
        // The floor follows quiet frames down at once and rises slowly, so a
        // long stretch of talking does not become the new silence.
        self.floor = if rms < self.floor || self.floor == 0.0 {
            rms
        } else {
            self.floor + (rms - self.floor) * 0.002
        };
        rms > (self.floor * 3.0).max(self.minimum)
    }
}

fn rms(samples: &[f32]) -> f32 {
    if samples.is_empty() {
        return 0.0;
    }
    (samples.iter().map(|s| s * s).sum::<f32>() / samples.len() as f32).sqrt()
}

/// One voice, for the length of the session: gathers its audio, cuts it at
/// pauses, recognises each piece and settles its lines.
fn listen(
    handle: &AppHandle,
    app: &Shared,
    voice: Voice,
    inbox: Receiver<(Vec<f32>, u32)>,
    generation: u64,
) {
    let current = || app.session.generation.load(Ordering::SeqCst) == generation;
    let mut gate = Gate::new(voice);
    let mut piece: Vec<f32> = Vec::new();
    let mut rate = 48_000u32;
    // Where the piece starts, in seconds from the start of the session.
    let mut piece_start = 0.0f64;
    let mut heard_speech = false;
    let mut silent_frames = 0usize;
    let mut frame_cursor = 0usize;
    let mut last_draft = Instant::now();
    let mut draft_cost = Duration::from_millis(400);

    loop {
        let received = inbox.recv_timeout(Duration::from_millis(200));
        let finished = matches!(received, Err(RecvTimeoutError::Disconnected));
        if let Ok((block, block_rate)) = received {
            rate = block_rate;
            piece.extend_from_slice(&block);
        }
        if !current() {
            return;
        }

        // Read the new audio in 30 ms frames.
        let frame = (rate as usize * 30 / 1000).max(1);
        while frame_cursor + frame <= piece.len() {
            if gate.is_speech(rms(&piece[frame_cursor..frame_cursor + frame])) {
                heard_speech = true;
                silent_frames = 0;
            } else {
                silent_frames += 1;
            }
            frame_cursor += frame;
        }

        let seconds = piece.len() as f64 / rate as f64;
        let paused = silent_frames as f64 * 0.03 >= PAUSE.as_secs_f64();
        let close_at = if finished {
            Some(piece.len())
        } else if heard_speech && paused && seconds >= SHORTEST {
            // Up to the pause, keeping a little of it so the last word ends.
            let quiet = silent_frames * frame;
            Some(piece.len().saturating_sub(quiet) + (rate as usize / 5).min(quiet))
        } else if seconds >= LONGEST {
            let earliest = (LONGEST - 3.0).max(1.0);
            Some(
                audio::quietest_near(&piece, (earliest * rate as f64) as usize, rate)
                    .max(rate as usize),
            )
        } else if !heard_speech && seconds >= 3.0 {
            // Nothing said: let the oldest silence go, keeping half a second
            // so a word starting now keeps its first sound.
            let keep = rate as usize / 2;
            let drop_count = piece.len() - keep;
            piece.drain(..drop_count);
            piece_start += drop_count as f64 / rate as f64;
            frame_cursor = piece.len();
            None
        } else {
            None
        };

        if let Some(cut) = close_at {
            let cut = cut.min(piece.len());
            if heard_speech && cut as f64 / rate as f64 >= 0.3 {
                let speech = audio::resample(&piece[..cut], rate, audio::SPEECH_RATE);
                if let Ok(sentences) = app.recogniser.sentences(speech) {
                    if !current() {
                        return;
                    }
                    for sentence in sentences {
                        settle(app, voice, &sentence.text, piece_start + sentence.start);
                    }
                }
            }
            piece.drain(..cut);
            piece_start += cut as f64 / rate as f64;
            frame_cursor = 0;
            silent_frames = 0;
            heard_speech = false;
            set_draft(app, voice, String::new());
            publish(handle, app);
        } else if heard_speech
            && seconds >= SHORTEST
            && last_draft.elapsed() >= draft_cost.max(Duration::from_secs(1))
        {
            // The words so far, while the voice is still mid-sentence.
            let started = Instant::now();
            let tail = &piece[piece.len().saturating_sub((LONGEST * rate as f64) as usize)..];
            let speech = audio::resample(tail, rate, audio::SPEECH_RATE);
            if let Some(text) = app.recogniser.preview(speech) {
                draft_cost = started.elapsed() * 2;
                if current() && !text.is_empty() {
                    set_draft(app, voice, text);
                    publish(handle, app);
                }
            }
            last_draft = Instant::now();
        }

        if finished {
            return;
        }
    }
}

fn set_draft(app: &Shared, voice: Voice, text: String) {
    let mut inner = app.session.inner.lock();
    match voice {
        Voice::You => inner.you_draft = text,
        Voice::Room => inner.room_draft = text,
    }
}

/// A sentence becomes part of the record: the dictionary and cleanup applied,
/// then added to the line the same voice is still speaking, or as a new
/// line in time order.
fn settle(app: &Shared, voice: Voice, piece: &str, at: f64) {
    let piece = piece.trim();
    if piece.is_empty() {
        return;
    }
    let rules = app.library.lock().corrections();
    let corrected = corrections::apply(piece, &rules);
    app.library.lock().record_hits(&corrected.applied);
    let level = app.settings.read().cleanup_level;
    let text = cleanup::apply(&corrected.text, level).text;
    if text.is_empty() {
        return;
    }

    let mut inner = app.session.inner.lock();
    // Pieces from the two voices finish out of order; a line goes where its
    // time puts it, and joins the line before only when that is the end of
    // the record and the same voice.
    let position = inner
        .lines
        .iter()
        .rposition(|line| line.at <= at)
        .map(|index| index + 1)
        .unwrap_or(0);
    if position == inner.lines.len() {
        if let Some(last) = inner.lines.last_mut() {
            if last.voice == voice && last.text.chars().count() < JOIN_LIMIT {
                last.text.push(' ');
                last.text.push_str(&text);
                return;
            }
        }
    }
    inner.lines.insert(
        position,
        SessionLine {
            id: Uuid::new_v4(),
            voice,
            text,
            at,
        },
    );
}

/// Sends both meters to the panel while the session runs. A stream that has
/// gone quiet (Windows sends nothing while nothing plays) shows as flat.
fn meter(handle: &AppHandle, app: &Shared, generation: u64) {
    let handle = handle.clone();
    let app = app.clone();
    let _ = std::thread::Builder::new()
        .name("huh-session-meter".into())
        .spawn(move || {
            let mut last = [0usize; 2];
            let mut quiet = [0u32; 2];
            while app.session.generation.load(Ordering::SeqCst) == generation
                && app.session.inner.lock().running
            {
                for (index, meter) in [&app.session.you, &app.session.room]
                    .into_iter()
                    .enumerate()
                {
                    let pushed = meter.pushes();
                    if pushed == last[index] {
                        quiet[index] += 1;
                        if quiet[index] >= 3 {
                            meter.push(0.0);
                        }
                    } else {
                        quiet[index] = 0;
                    }
                    last[index] = meter.pushes();
                }
                let _ = handle.emit_to(
                    PANEL,
                    "session-levels",
                    SessionLevels {
                        you: app.session.you.history(),
                        room: app.session.room.history(),
                    },
                );
                std::thread::sleep(METER_INTERVAL);
            }
        });
}

/* ── Calls ── */

/// Starts the panel window and, while the setting is on, the watch for calls.
pub fn start_watching(handle: &AppHandle, app: &Shared) {
    panel::create(handle);
    {
        let settings = app.settings.read();
        if let (Some(x), Some(y)) = (settings.panel_anchor_x, settings.panel_anchor_y) {
            app.session.inner.lock().anchor = Some((x, y));
        }
    }
    let handle = handle.clone();
    let app = app.clone();
    let _ = std::thread::Builder::new()
        .name("huh-call-watch".into())
        .spawn(move || {
            let mut previous: Option<String> = None;
            let mut seen_twice: Option<String> = None;
            loop {
                std::thread::sleep(CALL_POLL);
                let watching = app.settings.read().watches_for_meetings;
                let call = if watching {
                    meetings::in_use().into_iter().next()
                } else {
                    None
                };
                // Two looks in a row before believing it: a microphone test
                // or a browser's permission check is not a call.
                let confirmed = if call.is_some() && call == seen_twice {
                    call.clone()
                } else if call.is_none() {
                    None
                } else {
                    seen_twice = call.clone();
                    continue;
                };
                seen_twice = call.clone();
                if confirmed == previous {
                    continue;
                }
                previous = confirmed.clone();
                noticed(&handle, &app, confirmed);
            }
        });
}

fn noticed(handle: &AppHandle, app: &Shared, call: Option<String>) {
    let automatic = app.settings.read().captures_meetings_automatically;
    let begin = {
        let mut inner = app.session.inner.lock();
        inner.call = call.clone();
        match &call {
            None => {
                // The Mac leaves a withdrawn offer's mark on screen; here the
                // panel goes with the call when nothing was started.
                if inner.offer.take().is_some()
                    && !inner.running
                    && inner.saved_transcript.is_none()
                {
                    inner.visible = false;
                }
                None
            }
            Some(app_name) if !inner.running => {
                if automatic {
                    Some(app_name.clone())
                } else if !inner.declined.contains(app_name) {
                    inner.offer = Some(app_name.clone());
                    inner.visible = true;
                    None
                } else {
                    None
                }
            }
            Some(_) => None,
        }
    };
    match begin {
        Some(app_name) => start(handle, app, Trigger::Meeting(app_name)),
        None => publish(handle, app),
    }
}

/* ── Commands ── */

type Done = Result<(), String>;

#[tauri::command]
pub fn session_state(app: State<'_, Shared>) -> SessionState {
    app.session.state()
}

#[tauri::command]
pub fn toggle_session(app: State<'_, Shared>, handle: AppHandle) {
    let app = app.inner().clone();
    std::thread::spawn(move || toggle(&handle, &app));
}

/// From the button, the tray and Ctrl+Shift+M.
pub fn toggle(handle: &AppHandle, app: &Shared) {
    let running = app.session.inner.lock().running;
    if running {
        stop(handle, app);
    } else {
        app.session.inner.lock().offer = None;
        start(handle, app, Trigger::Manual);
    }
}

/// Pauses or resumes one voice of the running session.
#[tauri::command]
pub fn set_voice_paused(app: State<'_, Shared>, handle: AppHandle, voice: Voice, paused: bool) {
    if !app.session.inner.lock().running {
        return;
    }
    let flag = match voice {
        Voice::You => &app.session.you_paused,
        Voice::Room => &app.session.room_paused,
    };
    flag.store(paused, Ordering::SeqCst);
    publish(&handle, &app);
}

#[tauri::command]
pub fn accept_offer(app: State<'_, Shared>, handle: AppHandle) {
    let offer = app.session.inner.lock().offer.take();
    if let Some(name) = offer {
        let app = app.inner().clone();
        std::thread::spawn(move || start(&handle, &app, Trigger::Meeting(name)));
    }
}

/// Not now: this app is not offered again until huh? restarts, as on the Mac.
#[tauri::command]
pub fn decline_offer(app: State<'_, Shared>, handle: AppHandle) {
    {
        let mut inner = app.session.inner.lock();
        if let Some(name) = inner.offer.take() {
            inner.declined.insert(name);
        }
        if !inner.running {
            inner.visible = false;
        }
    }
    publish(&handle, &app);
}

#[tauri::command]
pub fn dismiss_panel(app: State<'_, Shared>, handle: AppHandle) {
    {
        let mut inner = app.session.inner.lock();
        if inner.running {
            return;
        }
        inner.visible = false;
        inner.saved_transcript = None;
        inner.status_message = None;
    }
    publish(&handle, &app);
}

/// Opens what was just saved in the main window: the one deliberate change
/// of focus a session makes.
#[tauri::command]
pub fn open_saved(app: State<'_, Shared>, handle: AppHandle) {
    let id = {
        let mut inner = app.session.inner.lock();
        inner.visible = false;
        inner.saved_transcript.take()
    };
    if let Some(id) = id {
        let _ = handle.emit(
            "navigate",
            serde_json::json!({ "section": "transcripts", "transcript": id }),
        );
        chrome::reveal(&handle);
    }
    publish(&handle, &app);
}

#[tauri::command]
pub fn set_panel_expanded(app: State<'_, Shared>, handle: AppHandle, on: bool) {
    app.session.inner.lock().expanded = on;
    publish(&handle, &app);
}

#[tauri::command]
pub fn panel_measured(app: State<'_, Shared>, handle: AppHandle, width: f64, height: f64) {
    app.session.inner.lock().size = (width, height);
    let state = app.session.state();
    panel::follow(&handle, &app, &state);
}

#[tauri::command]
pub fn panel_drag(app: State<'_, Shared>, handle: AppHandle, phase: String) -> Done {
    match phase.as_str() {
        "began" => panel::drag(&handle, app.inner()),
        "ended" => panel::end_drag(app.inner()),
        other => return Err(format!("No drag phase called {other}.")),
    }
    Ok(())
}

/* ── The panel window ── */

mod panel {
    use super::*;

    /// Built at launch, hidden, as the overlay is, so the first call never
    /// waits on a webview being made.
    pub fn create(handle: &AppHandle) {
        if handle.get_webview_window(PANEL).is_some() {
            return;
        }
        let built = WebviewWindowBuilder::new(handle, PANEL, WebviewUrl::App("panel.html".into()))
            .title("huh? session")
            .inner_size(388.0, 240.0)
            .decorations(false)
            .transparent(true)
            .resizable(false)
            .always_on_top(true)
            .skip_taskbar(true)
            .shadow(false)
            .focused(false)
            .focusable(false)
            .visible(false)
            .build();
        if let Err(error) = built {
            tracing::error!(%error, "could not build the session panel");
        }
    }

    /// Shows, hides, sizes and places the panel to match the state.
    pub fn follow(handle: &AppHandle, app: &Shared, state: &SessionState) {
        let handle = handle.clone();
        let app = app.clone();
        let visible = state.visible;
        let _ = handle.clone().run_on_main_thread(move || {
            let Some(window) = handle.get_webview_window(PANEL) else {
                return;
            };
            let (size, anchor) = {
                let inner = app.session.inner.lock();
                (inner.size, inner.anchor)
            };
            if !visible {
                // The page slides its card out first; the window goes once
                // that has finished, unless the panel has been asked back.
                let handle = handle.clone();
                let app = app.clone();
                std::thread::spawn(move || {
                    std::thread::sleep(SLIDE_OUT);
                    let main = handle.clone();
                    let _ = main.run_on_main_thread(move || {
                        if app.session.inner.lock().visible {
                            return;
                        }
                        if let Some(window) = handle.get_webview_window(PANEL) {
                            platform::hide(&window);
                        }
                    });
                });
                return;
            }
            let placed = platform::place(&window, size, anchor);
            app.session.inner.lock().anchor = Some(placed);
        });
    }

    /// Ends a drag and keeps where it ended, for next time, as the Mac does.
    pub fn end_drag(app: &Shared) {
        if !app.session.dragging.swap(false, Ordering::SeqCst) {
            return;
        }
        let Some((x, y)) = app.session.inner.lock().anchor else {
            return;
        };
        let mut settings = app.settings.write();
        settings.panel_anchor_x = Some(x);
        settings.panel_anchor_y = Some(y);
        if let Err(error) = app.stores.save_settings(&settings) {
            tracing::warn!(%error, "couldn't keep the panel's place");
        }
    }

    /// Follows the pointer until the page says the drag has ended.
    pub fn drag(handle: &AppHandle, app: &Shared) {
        if app.session.dragging.swap(true, Ordering::SeqCst) {
            return;
        }
        let handle = handle.clone();
        let app = app.clone();
        std::thread::spawn(move || {
            let Some(origin_pointer) = platform::pointer() else {
                app.session.dragging.store(false, Ordering::SeqCst);
                return;
            };
            let origin = app.session.inner.lock().anchor.unwrap_or((0, 0));
            while app.session.dragging.load(Ordering::SeqCst) {
                // A release the page never reported still ends it: a drag
                // must not outlive the button that started it.
                if !platform::button_down() {
                    end_drag(&app);
                    break;
                }
                if let Some(now) = platform::pointer() {
                    let anchor = (
                        origin.0 + now.0 - origin_pointer.0,
                        origin.1 + now.1 - origin_pointer.1,
                    );
                    app.session.inner.lock().anchor = Some(anchor);
                    let state = app.session.state();
                    follow(&handle, &app, &state);
                }
                std::thread::sleep(Duration::from_millis(16));
            }
        });
    }

    #[cfg(windows)]
    mod platform {
        use windows::Win32::Foundation::{HWND, POINT};
        use windows::Win32::Graphics::Gdi::{
            GetMonitorInfoW, MonitorFromPoint, MONITORINFO, MONITOR_DEFAULTTOPRIMARY,
        };
        use windows::Win32::UI::HiDpi::{GetDpiForMonitor, MDT_EFFECTIVE_DPI};
        use windows::Win32::UI::Input::KeyboardAndMouse::{
            GetAsyncKeyState, VK_LBUTTON, VK_RBUTTON,
        };
        use windows::Win32::UI::WindowsAndMessaging::{
            GetCursorPos, GetSystemMetrics, SetWindowPos, ShowWindow, HWND_TOPMOST, SM_SWAPBUTTON,
            SWP_NOACTIVATE, SWP_SHOWWINDOW, SW_HIDE,
        };

        pub fn pointer() -> Option<(i32, i32)> {
            let mut point = POINT::default();
            unsafe { GetCursorPos(&mut point) }.ok()?;
            Some((point.x, point.y))
        }

        /// Whether the primary button is held. The physical button, so for
        /// someone who has swapped them it is the right one.
        pub fn button_down() -> bool {
            let swapped = unsafe { GetSystemMetrics(SM_SWAPBUTTON) } != 0;
            let button = if swapped { VK_RBUTTON } else { VK_LBUTTON };
            (unsafe { GetAsyncKeyState(i32::from(button.0)) } as u16) & 0x8000 != 0
        }

        /// The work area and scale of the screen holding `point`.
        fn screen(point: (i32, i32)) -> ((i32, i32, i32, i32), f64) {
            unsafe {
                let monitor = MonitorFromPoint(
                    POINT {
                        x: point.0,
                        y: point.1,
                    },
                    MONITOR_DEFAULTTOPRIMARY,
                );
                let mut info = MONITORINFO {
                    cbSize: std::mem::size_of::<MONITORINFO>() as u32,
                    ..Default::default()
                };
                let _ = GetMonitorInfoW(monitor, &mut info);
                let (mut dpi, mut unused) = (96u32, 96u32);
                let _ = GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, &mut dpi, &mut unused);
                let area = info.rcWork;
                (
                    (area.left, area.top, area.right, area.bottom),
                    dpi as f64 / 96.0,
                )
            }
        }

        /// Puts the panel's top-left corner at `anchor` (or the Mac's default,
        /// top right), sized to the page, kept 8 px inside the screen, without
        /// ever activating it. Returns where it went.
        pub fn place(
            window: &tauri::WebviewWindow,
            size: (f64, f64),
            anchor: Option<(i32, i32)>,
        ) -> (i32, i32) {
            let probe = anchor.unwrap_or_else(|| pointer().unwrap_or((0, 0)));
            let ((left, top, right, bottom), scale) = screen(probe);
            let width = (size.0.clamp(80.0, 520.0) * scale).round() as i32;
            let height = (size.1.clamp(60.0, 780.0) * scale).round() as i32;
            let margin = (8.0 * scale).round() as i32;
            let (x, y) = anchor.unwrap_or((
                right - (388.0 * scale).round() as i32 - (18.0 * scale).round() as i32,
                top + (14.0 * scale).round() as i32,
            ));
            let x = x.clamp(left + margin, (right - width - margin).max(left + margin));
            let y = y.clamp(top + margin, (bottom - height - margin).max(top + margin));
            if let Ok(handle) = window.hwnd() {
                unsafe {
                    let _ = SetWindowPos(
                        HWND(handle.0),
                        HWND_TOPMOST,
                        x,
                        y,
                        width,
                        height,
                        SWP_NOACTIVATE | SWP_SHOWWINDOW,
                    );
                }
            }
            (x, y)
        }

        pub fn hide(window: &tauri::WebviewWindow) {
            if let Ok(handle) = window.hwnd() {
                unsafe {
                    let _ = ShowWindow(HWND(handle.0), SW_HIDE);
                }
            }
        }
    }

    #[cfg(not(windows))]
    mod platform {
        pub fn pointer() -> Option<(i32, i32)> {
            None
        }

        pub fn button_down() -> bool {
            false
        }

        pub fn place(
            window: &tauri::WebviewWindow,
            size: (f64, f64),
            anchor: Option<(i32, i32)>,
        ) -> (i32, i32) {
            let _ = window.set_size(tauri::LogicalSize::new(size.0, size.1));
            let _ = window.show();
            anchor.unwrap_or((0, 0))
        }

        pub fn hide(window: &tauri::WebviewWindow) {
            let _ = window.hide();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_gate_learns_the_room_and_hears_speech_above_it() {
        let mut gate = Gate::new(Voice::You);
        for _ in 0..50 {
            assert!(!gate.is_speech(0.004));
        }
        assert!(gate.is_speech(0.08));
        // A long stretch of speech does not become the new floor.
        for _ in 0..200 {
            gate.is_speech(0.08);
        }
        assert!(!gate.is_speech(0.005));
    }

    #[test]
    fn a_saved_session_labels_each_line_with_who_spoke() {
        let mut inner = Inner {
            trigger: Trigger::Meeting("Teams".into()),
            started_at: Some(Utc::now()),
            ..Inner::default()
        };
        inner.lines = vec![
            SessionLine {
                id: Uuid::new_v4(),
                voice: Voice::Room,
                text: "Can everyone hear me?".into(),
                at: 1.0,
            },
            SessionLine {
                id: Uuid::new_v4(),
                voice: Voice::You,
                text: "Yes, loud and clear.".into(),
                at: 3.5,
            },
        ];
        let transcript = persist(&inner, 60.0);
        assert_eq!(
            transcript.text,
            "Room: Can everyone hear me?\n\nYou: Yes, loud and clear."
        );
        assert_eq!(transcript.segments[1].start, 3.5);
        assert_eq!(transcript.source, TranscriptSource::Meeting);
        assert_eq!(transcript.source_name, "Teams");
    }
}
