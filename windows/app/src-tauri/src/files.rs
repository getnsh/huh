//! Transcribing a recording someone already has: a meeting, a voice memo,
//! the sound of a video.
//!
//! The file is decoded in blocks and transcribed as it goes, in pieces of
//! about thirty seconds, each cut at the quietest moment near its end so no
//! word is split in two. Each piece comes back as sentences with the time
//! each began, offset to the recording's own clock, which is what gives the
//! transcript its lines. Nothing is held whole, so an afternoon of meetings
//! costs no more memory than a minute, and the progress shown is how far
//! through the file the transcription actually is.
use std::path::{Path, PathBuf};

use parking_lot::Mutex;
use serde::Serialize;
use tauri::{AppHandle, Emitter, State};
use uuid::Uuid;

use huh_core::model::{Transcript, TranscriptSegment, TranscriptSource};
use huh_core::{cleanup, corrections};

use crate::speech::{Spoken, ENGINE_NAME};
use crate::{audio, learning, media, Shared};

/// The extensions the open dialog offers and a drop accepts.
const MEDIA: &[&str] = &[
    "mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "ogg", "opus", "wma", "mp4", "m4v", "mov",
    "mkv", "webm", "avi", "wmv",
];

/// Pieces are cut between these many seconds in, at the quietest point.
const PIECE_EARLIEST: f64 = 27.0;
const PIECE_LATEST: f64 = 33.0;

#[derive(Debug, Clone, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum FileJob {
    Idle,
    Running {
        name: String,
        progress: f64,
        stage: String,
    },
    Done {
        id: Uuid,
        name: String,
        path: String,
    },
    Failed {
        message: String,
    },
}

pub struct Files {
    job: Mutex<FileJob>,
}

impl Default for Files {
    fn default() -> Self {
        Self {
            job: Mutex::new(FileJob::Idle),
        }
    }
}

fn set(handle: &AppHandle, app: &Shared, job: FileJob) {
    *app.files.job.lock() = job.clone();
    let _ = handle.emit("file-job", job);
}

fn file_name(path: &Path) -> String {
    path.file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| path.display().to_string())
}

type Done = Result<(), String>;

#[tauri::command]
pub fn file_job(app: State<'_, Shared>) -> FileJob {
    app.files.job.lock().clone()
}

#[tauri::command]
pub fn transcribe_file(app: State<'_, Shared>, handle: AppHandle, path: String) -> Done {
    let path = PathBuf::from(path);
    let name = file_name(&path);
    if let FileJob::Running { name, .. } = &*app.files.job.lock() {
        return Err(format!("Already transcribing {name}."));
    }
    let extension = path
        .extension()
        .map(|e| e.to_string_lossy().to_lowercase())
        .unwrap_or_default();
    if !MEDIA.contains(&extension.as_str()) {
        set(
            &handle,
            &app,
            FileJob::Failed {
                message: format!("{name} isn't an audio or video file."),
            },
        );
        return Ok(());
    }
    set(
        &handle,
        &app,
        FileJob::Running {
            name: name.clone(),
            progress: 0.0,
            stage: "Reading the recording…".into(),
        },
    );

    let app = app.inner().clone();
    let _ = std::thread::Builder::new()
        .name("huh-file".into())
        .spawn(move || match transcribe(&handle, &app, &path, &name) {
            Ok(transcript) => {
                let id = transcript.id;
                let history = {
                    let mut library = app.library.lock();
                    library.add_transcript(transcript.clone());
                    library.history.clone()
                };
                let _ = handle.emit("transcript", &transcript);
                let _ = handle.emit("history", history);
                learning::schedule_queue(&app);
                set(
                    &handle,
                    &app,
                    FileJob::Done {
                        id,
                        name,
                        path: path.display().to_string(),
                    },
                );
            }
            Err(message) => {
                tracing::warn!(%message, "file transcription failed");
                set(&handle, &app, FileJob::Failed { message });
            }
        });
    Ok(())
}

/// The quietest 20 ms between two points, so a piece ends between words.
fn quietest_between(samples: &[f32], from: usize, to: usize, rate: u32) -> usize {
    let frame = (rate as usize / 50).max(1);
    let to = to.min(samples.len()).saturating_sub(frame);
    (from..to.max(from + 1))
        .step_by(frame)
        .filter(|start| start + frame <= samples.len())
        .map(|start| {
            (
                start,
                samples[start..start + frame]
                    .iter()
                    .map(|s| s * s)
                    .sum::<f32>(),
            )
        })
        .min_by(|a, b| a.1.total_cmp(&b.1))
        .map(|(start, _)| start)
        .unwrap_or(to)
}

fn transcribe(
    handle: &AppHandle,
    app: &Shared,
    path: &Path,
    name: &str,
) -> Result<Transcript, String> {
    let mut pending: Vec<f32> = Vec::new();
    let mut offset = 0.0f64;
    let mut lines: Vec<Spoken> = Vec::new();
    let mut shown = -1i64;
    let mut failure: Option<String> = None;

    let piece = |samples: &[f32], rate: u32, offset: f64| -> Result<Vec<Spoken>, String> {
        let speech = audio::resample(samples, rate, audio::SPEECH_RATE);
        let spoken = app.recogniser.sentences(speech)?;
        Ok(spoken
            .into_iter()
            .map(|line| Spoken {
                start: line.start + offset,
                end: line.end + offset,
                text: line.text,
            })
            .collect())
    };

    let rate = media::decode(path, &mut |block, rate, progress| {
        pending.extend_from_slice(block);
        let latest = (PIECE_LATEST * rate as f64) as usize;
        while pending.len() >= latest {
            let earliest = (PIECE_EARLIEST * rate as f64) as usize;
            let cut = quietest_between(&pending, earliest, latest, rate).max(rate as usize);
            match piece(&pending[..cut], rate, offset) {
                Ok(spoken) => lines.extend(spoken),
                Err(message) => {
                    failure = Some(message);
                    return false;
                }
            }
            pending.drain(..cut);
            offset += cut as f64 / rate as f64;
        }
        if let Some(total) = progress.total.filter(|t| *t > 0.0) {
            let fraction = (progress.decoded / total).clamp(0.0, 0.99);
            let percent = (fraction * 100.0) as i64;
            if percent != shown {
                shown = percent;
                set(
                    handle,
                    app,
                    FileJob::Running {
                        name: name.to_string(),
                        progress: fraction,
                        stage: "Transcribing".into(),
                    },
                );
            }
        }
        true
    })?;
    if let Some(message) = failure {
        return Err(message);
    }
    if pending.len() as f64 > 0.3 * rate as f64 {
        lines.extend(piece(&pending, rate, offset)?);
    }
    let duration = offset + pending.len() as f64 / rate.max(1) as f64;

    if lines.is_empty() {
        return Err(format!("No speech found in {name}."));
    }

    // The dictionary and cleanup, on the whole text and on every line, as the
    // Mac does for a recording.
    let raw = lines
        .iter()
        .map(|line| line.text.as_str())
        .collect::<Vec<_>>()
        .join(" ");
    let (rules, level) = {
        let library = app.library.lock();
        (library.corrections(), app.settings.read().cleanup_level)
    };
    let corrected = corrections::apply(&raw, &rules);
    app.library.lock().record_hits(&corrected.applied);
    let cleaned = cleanup::apply(&corrected.text, level);
    let segments = lines
        .iter()
        .filter_map(|line| {
            let text = cleanup::apply(&corrections::apply(&line.text, &rules).text, level).text;
            (!text.is_empty()).then(|| TranscriptSegment {
                id: Uuid::new_v4(),
                start: line.start,
                text,
            })
        })
        .collect();

    Ok(Transcript {
        analysis_findings: 0,
        analyzed_at: None,
        cleanup_removed: cleaned.removed as u32,
        corrections: corrected.applied,
        date: chrono::Utc::now(),
        duration,
        engine: ENGINE_NAME.into(),
        id: Uuid::new_v4(),
        raw,
        segments,
        source: TranscriptSource::File,
        source_name: name.to_string(),
        source_path: path.display().to_string(),
        summary: String::new(),
        summary_date: None,
        text: cleaned.text,
    })
}

#[tauri::command]
pub fn keep_original(app: State<'_, Shared>, handle: AppHandle) {
    set(&handle, &app, FileJob::Idle);
}

/// Moves the recording to the Recycle Bin, from where it can be put back.
#[tauri::command]
pub fn recycle_original(app: State<'_, Shared>, handle: AppHandle) {
    let path = match &*app.files.job.lock() {
        FileJob::Done { path, .. } => path.clone(),
        _ => return,
    };
    let next = match trash::delete(&path) {
        Ok(()) => FileJob::Idle,
        Err(error) => FileJob::Failed {
            message: format!("Couldn't move it to the Recycle Bin: {error}"),
        },
    };
    set(&handle, &app, next);
}

#[tauri::command]
pub fn dismiss_file_failure(app: State<'_, Shared>, handle: AppHandle) {
    set(&handle, &app, FileJob::Idle);
}

#[cfg(test)]
mod tests {
    use super::quietest_between;

    #[test]
    fn a_piece_ends_in_the_pause() {
        let rate = 16_000u32;
        let mut samples = vec![0.4f32; rate as usize * 34];
        let pause = rate as usize * 29;
        for sample in &mut samples[pause..pause + 400] {
            *sample = 0.0;
        }
        let cut = quietest_between(&samples, rate as usize * 27, rate as usize * 33, rate);
        assert!((pause..pause + 400).contains(&cut), "cut at {cut}");
    }
}
