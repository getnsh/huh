//! Speech recognition.
//!
//! Parakeet TDT 0.6B v3, the model the Mac runs on its Neural Engine through
//! FluidAudio. Here it is NVIDIA's network exported to ONNX, quantised to
//! int8, and run on the CPU by ONNX Runtime through `transcribe-rs`: the same
//! weights and vocabulary, and the same punctuation and capitals in what comes
//! back.
//!
//! The model is not in the installer. It is fetched once, on first launch,
//! from one pinned revision on Hugging Face, every file is checked against a
//! SHA-256 compiled into the app before it is used, and it is kept in
//! `%LOCALAPPDATA%\Huh\Models`. That download is the only request the app
//! makes over the network, and it carries nothing of yours.
//!
//! Recognition happens on a thread of its own, which owns the model. Loading it
//! takes seconds, so it happens once, at launch, and each utterance after that
//! is a message to the same thread.
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};

use crossbeam_channel::{bounded, unbounded, Receiver, Sender};
use parking_lot::RwLock;
use serde::Serialize;
use sha2::{Digest, Sha256};
use transcribe_rs::onnx::parakeet::{ParakeetModel, ParakeetParams, TimestampGranularity};
use transcribe_rs::onnx::Quantization;

/// A sentence the recogniser heard, and when, in seconds from the start of
/// the audio it was given.
#[derive(Debug, Clone, PartialEq)]
pub struct Spoken {
    pub start: f64,
    pub end: f64,
    pub text: String,
}

/// What the window and the overlay say about the recogniser.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Status {
    /// Nothing has been asked of it yet.
    Waiting,
    Downloading {
        percent: u8,
    },
    Loading,
    Ready,
    Failed {
        message: String,
    },
}

/// The model, file by file, as published at one revision.
struct Part {
    name: &'static str,
    bytes: u64,
    sha256: &'static str,
}

const REPOSITORY: &str = "istupakov/parakeet-tdt-0.6b-v3-onnx";
const REVISION: &str = "8f23f0c03c8761650bdb5b40aaf3e40d2c15f1ce";
const FOLDER: &str = "parakeet-tdt-0.6b-v3-int8";

/// The hashes are what a download is checked against. A launch checks only
/// the sizes: a file is renamed into place only after its hash has matched, and
/// hashing 640 MB on every start would cost seconds for nothing.
const PARTS: [Part; 4] = [
    Part {
        name: "encoder-model.int8.onnx",
        bytes: 652_183_999,
        sha256: "6139d2fa7e1b086097b277c7149725edbab89cc7c7ae64b23c741be4055aff09",
    },
    Part {
        name: "decoder_joint-model.int8.onnx",
        bytes: 18_202_004,
        sha256: "eea7483ee3d1a30375daedc8ed83e3960c91b098812127a0d99d1c8977667a70",
    },
    Part {
        name: "nemo128.onnx",
        bytes: 139_764,
        sha256: "a9fde1486ebfcc08f328d75ad4610c67835fea58c73ba57e3209a6f6cf019e9f",
    },
    Part {
        name: "vocab.txt",
        bytes: 93_939,
        sha256: "d58544679ea4bc6ac563d1f545eb7d474bd6cfa467f0a6e2c1dc1c7d37e3c35d",
    },
];

/// What the history calls the engine, in the Mac's pattern of naming the
/// hardware it runs on.
pub const ENGINE_NAME: &str = "Parakeet TDT (CPU)";

/// Where the model lives.
///
/// `%LOCALAPPDATA%`, not `%APPDATA%` beside the dictionary: a roaming profile
/// copies `%APPDATA%` from machine to machine at every sign-in, and 640 MB of
/// weights is not something to roam. `HUH_MODEL_DIR` names the folder holding
/// the files directly, for development.
pub fn directory() -> PathBuf {
    if let Ok(explicit) = std::env::var("HUH_MODEL_DIR") {
        return PathBuf::from(explicit);
    }
    #[cfg(windows)]
    let base = std::env::var("LOCALAPPDATA")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("."));
    #[cfg(not(windows))]
    let base = std::env::var("HOME")
        .map(|home| PathBuf::from(home).join("Library/Caches"))
        .unwrap_or_else(|_| PathBuf::from("."));
    base.join("Huh").join("Models").join(FOLDER)
}

fn complete(folder: &Path, part: &Part) -> bool {
    fs::metadata(folder.join(part.name))
        .map(|meta| meta.len() == part.bytes)
        .unwrap_or(false)
}

/// Whether every file is in place.
pub fn present(folder: &Path) -> bool {
    PARTS.iter().all(|part| complete(folder, part))
}

/// Fetches whatever is missing, reporting progress as a whole percentage of
/// what was missing.
pub fn download(folder: &Path, progress: &mut dyn FnMut(u8)) -> Result<(), String> {
    fs::create_dir_all(folder).map_err(|e| e.to_string())?;
    let missing: Vec<&Part> = PARTS
        .iter()
        .filter(|part| !complete(folder, part))
        .collect();
    let total: u64 = missing.iter().map(|part| part.bytes).sum();
    let agent = agent();
    let mut finished = 0u64;
    for part in missing {
        fetch(&agent, folder, part, &mut |bytes| {
            let percent = ((finished + bytes) * 100 / total.max(1)).min(100) as u8;
            progress(percent);
        })?;
        finished += part.bytes;
    }
    Ok(())
}

fn agent() -> ureq::Agent {
    use ureq::tls::{RootCerts, TlsConfig, TlsProvider};
    // The system's TLS and the system's certificate store: the same trust
    // Edge has, including any root a company has installed.
    let tls = TlsConfig::builder()
        .provider(TlsProvider::NativeTls)
        .root_certs(RootCerts::PlatformVerifier)
        .build();
    ureq::Agent::config_builder()
        .tls_config(tls)
        .timeout_connect(Some(Duration::from_secs(20)))
        .user_agent(concat!("huh/", env!("CARGO_PKG_VERSION")))
        .build()
        .new_agent()
}

fn fetch(
    agent: &ureq::Agent,
    folder: &Path,
    part: &Part,
    progress: &mut dyn FnMut(u64),
) -> Result<(), String> {
    let target = folder.join(part.name);
    let partial = folder.join(format!("{}.part", part.name));

    // An attempt that stopped part-way is carried on from where it stopped
    // rather than started again: 650 MB is a lot to lose to a dropped
    // connection. What is already on disk is hashed first, so the check at
    // the end still covers every byte.
    let mut hasher = Sha256::new();
    let mut have = match File::open(&partial) {
        Ok(mut existing) => absorb(&mut existing, &mut hasher).unwrap_or(0),
        Err(_) => 0,
    };
    if have >= part.bytes {
        let _ = fs::remove_file(&partial);
        hasher = Sha256::new();
        have = 0;
    }

    let url = format!(
        "https://huggingface.co/{REPOSITORY}/resolve/{REVISION}/{}",
        part.name
    );
    let mut request = agent.get(&url);
    if have > 0 {
        request = request.header("Range", format!("bytes={have}-"));
    }
    let mut response = request
        .call()
        .map_err(|e| format!("{} could not be fetched: {e}", part.name))?;

    // A server is free to ignore a range and send the whole file again.
    let resumed = have > 0 && response.status().as_u16() == 206;
    if !resumed {
        hasher = Sha256::new();
        have = 0;
    }
    let mut file = OpenOptions::new()
        .create(true)
        .write(true)
        .append(resumed)
        .truncate(!resumed)
        .open(&partial)
        .map_err(|e| e.to_string())?;

    let mut reader = response.body_mut().as_reader();
    let mut buffer = vec![0u8; 1 << 16];
    progress(have);
    loop {
        let read = reader
            .read(&mut buffer)
            .map_err(|e| format!("{} stopped arriving: {e}", part.name))?;
        if read == 0 {
            break;
        }
        file.write_all(&buffer[..read]).map_err(|e| e.to_string())?;
        hasher.update(&buffer[..read]);
        have += read as u64;
        progress(have);
    }
    file.flush().map_err(|e| e.to_string())?;
    drop(file);

    if have != part.bytes {
        // Kept, so the next attempt resumes.
        return Err(format!(
            "{} arrived incomplete, {have} of {} bytes.",
            part.name, part.bytes
        ));
    }
    let digest = format!("{:x}", hasher.finalize());
    if digest != part.sha256 {
        let _ = fs::remove_file(&partial);
        return Err(format!("{} did not match its checksum.", part.name));
    }
    fs::rename(&partial, &target).map_err(|e| e.to_string())
}

fn absorb(file: &mut File, hasher: &mut Sha256) -> io::Result<u64> {
    let mut buffer = vec![0u8; 1 << 16];
    let mut total = 0u64;
    loop {
        let read = file.read(&mut buffer)?;
        if read == 0 {
            return Ok(total);
        }
        hasher.update(&buffer[..read]);
        total += read as u64;
    }
}

enum Job {
    Prepare,
    Transcribe {
        samples: Vec<f32>,
        reply: Sender<Result<String, String>>,
    },
    /// The live preview: answered only when nothing else is waiting.
    Preview {
        samples: Vec<f32>,
        reply: Sender<Option<String>>,
    },
    /// A stretch of a recording or a meeting, returned sentence by sentence
    /// with the time each began.
    Sentences {
        samples: Vec<f32>,
        reply: Sender<Result<Vec<Spoken>, String>>,
    },
}

type Listener = Box<dyn Fn(&Status) + Send + Sync>;

const GONE: &str = "The recogniser has stopped. Restart huh?.";

pub struct Recogniser {
    jobs: Sender<Job>,
    status: Arc<RwLock<Status>>,
    listener: Arc<OnceLock<Listener>>,
}

impl Recogniser {
    pub fn new() -> Self {
        let (jobs, inbox) = unbounded();
        let status = Arc::new(RwLock::new(Status::Waiting));
        let listener: Arc<OnceLock<Listener>> = Arc::default();
        let worker = Worker {
            folder: directory(),
            status: status.clone(),
            listener: listener.clone(),
            model: None,
        };
        std::thread::Builder::new()
            .name("huh-recogniser".into())
            .spawn(move || worker.run(inbox))
            .expect("could not start the recogniser thread");
        Self {
            jobs,
            status,
            listener,
        }
    }

    /// Downloads the model if it is missing, loads it, and reports each step
    /// to `listener`.
    pub fn prepare(&self, listener: impl Fn(&Status) + Send + Sync + 'static) {
        let _ = self.listener.set(Box::new(listener));
        let _ = self.jobs.send(Job::Prepare);
    }

    /// Tries again after a failure: a download that died with the network, say.
    pub fn retry(&self) {
        if matches!(self.status(), Status::Failed { .. }) {
            let _ = self.jobs.send(Job::Prepare);
        }
    }

    pub fn status(&self) -> Status {
        self.status.read().clone()
    }

    /// Recognises 16 kHz mono audio. Blocks until the words are back, which
    /// includes waiting for the model to finish loading.
    pub fn transcribe(&self, samples: Vec<f32>) -> Result<String, String> {
        let (reply, answer) = bounded(1);
        self.jobs
            .send(Job::Transcribe { samples, reply })
            .map_err(|_| GONE.to_string())?;
        answer.recv().map_err(|_| GONE.to_string())?
    }

    /// Recognises audio for the live preview, or declines.
    ///
    /// A preview gives way to everything. It is skipped while the model is
    /// still on its way, and whenever another job is already queued -- above
    /// all the final pass for the same utterance, which must not queue behind
    /// previews of it; at worst it waits out the one already running.
    /// Declining, or failing, is `None`: a preview that does not arrive costs
    /// nothing, and the final pass reports its own errors.
    pub fn preview(&self, samples: Vec<f32>) -> Option<String> {
        let (reply, answer) = bounded(1);
        self.jobs.send(Job::Preview { samples, reply }).ok()?;
        answer.recv().ok().flatten()
    }

    /// Recognises 16 kHz mono audio into sentences with their start times,
    /// for transcripts that are read line by line: recordings and meetings.
    pub fn sentences(&self, samples: Vec<f32>) -> Result<Vec<Spoken>, String> {
        let (reply, answer) = bounded(1);
        self.jobs
            .send(Job::Sentences { samples, reply })
            .map_err(|_| GONE.to_string())?;
        answer.recv().map_err(|_| GONE.to_string())?
    }
}

impl Default for Recogniser {
    fn default() -> Self {
        Self::new()
    }
}

struct Worker {
    folder: PathBuf,
    status: Arc<RwLock<Status>>,
    listener: Arc<OnceLock<Listener>>,
    model: Option<ParakeetModel>,
}

impl Worker {
    fn run(mut self, inbox: Receiver<Job>) {
        while let Ok(job) = inbox.recv() {
            match job {
                Job::Prepare => {
                    let _ = self.ensure();
                }
                Job::Transcribe { samples, reply } => {
                    let result = self
                        .ensure()
                        .and_then(|model| recognise(model, &samples, false));
                    let _ = reply.send(result);
                }
                Job::Preview { samples, reply } => {
                    let text = match self.model.as_mut() {
                        Some(model) if inbox.is_empty() => recognise(model, &samples, true).ok(),
                        _ => None,
                    };
                    let _ = reply.send(text);
                }
                Job::Sentences { samples, reply } => {
                    let result = self.ensure().and_then(|model| sentences(model, &samples));
                    let _ = reply.send(result);
                }
            }
        }
    }

    fn set(&self, status: Status) {
        *self.status.write() = status.clone();
        if let Some(listener) = self.listener.get() {
            listener(&status);
        }
    }

    fn failed(&self, message: String) -> String {
        tracing::error!(%message, "recogniser unavailable");
        self.set(Status::Failed {
            message: message.clone(),
        });
        message
    }

    fn ensure(&mut self) -> Result<&mut ParakeetModel, String> {
        if self.model.is_none() {
            if !present(&self.folder) {
                self.set(Status::Downloading { percent: 0 });
                let mut last = 0u8;
                let status = self.status.clone();
                let listener = self.listener.clone();
                let result = download(&self.folder, &mut |percent| {
                    if percent != last {
                        last = percent;
                        let now = Status::Downloading { percent };
                        *status.write() = now.clone();
                        if let Some(listener) = listener.get() {
                            listener(&now);
                        }
                    }
                });
                if let Err(why) = result {
                    return Err(self.failed(format!("Model download failed: {why}")));
                }
            }

            self.set(Status::Loading);
            let started = Instant::now();
            let model = ParakeetModel::load(&self.folder, &Quantization::Int8)
                .map_err(|e| self.failed(format!("Parakeet would not load: {e}")))?;
            tracing::info!(elapsed = ?started.elapsed(), "parakeet loaded");
            self.model = Some(model);
            self.set(Status::Ready);
        }
        self.model
            .as_mut()
            .ok_or_else(|| "The recogniser lost its model.".to_string())
    }
}

/// Parakeet's words, grouped into sentences: split after a full stop,
/// question mark or exclamation, each with its first word's time.
///
/// Asked for token by token and grouped here, rather than taken from
/// transcribe-rs's own sentences. The model writes the space before a number
/// as a token of its own, and transcribe-rs takes a token that is only a
/// space for a blank and drops it, which glues the number to the word before
/// it: "came in4%", "Thursday at10". The plain text keeps the space; only
/// the timed sentences lost it.
fn sentences(model: &mut ParakeetModel, samples: &[f32]) -> Result<Vec<Spoken>, String> {
    let started = Instant::now();
    let result = model
        .transcribe_with(
            samples,
            &ParakeetParams {
                timestamp_granularity: Some(TimestampGranularity::Token),
                ..Default::default()
            },
        )
        .map_err(|e| format!("Transcription failed: {e}"))?;
    let tokens: Vec<(f64, f64, String)> = result
        .segments
        .unwrap_or_default()
        .into_iter()
        .map(|token| {
            (
                token.start.max(0.0) as f64,
                token.end.max(0.0) as f64,
                token.text,
            )
        })
        .collect();
    let mut spoken = group_sentences(&tokens);
    // Words with no sentence boundary still come back as one line.
    if spoken.is_empty() && !result.text.trim().is_empty() {
        spoken.push(Spoken {
            start: 0.0,
            end: samples.len() as f64 / crate::audio::SPEECH_RATE as f64,
            text: result.text.trim().to_string(),
        });
    }
    tracing::info!(
        seconds = samples.len() as f32 / crate::audio::SPEECH_RATE as f32,
        lines = spoken.len(),
        elapsed = ?started.elapsed(),
        "recognised a passage"
    );
    Ok(spoken)
}

/// The word-boundary mark of a SentencePiece vocabulary, should a token
/// arrive with it still in place rather than turned into a space.
const BOUNDARY: char = '\u{2581}';

/// Tokens, as `(start, end, text)` with a leading space marking a new word,
/// into sentences. A token that is nothing but a space is a word boundary
/// with no letters of its own, not a blank.
fn group_sentences(tokens: &[(f64, f64, String)]) -> Vec<Spoken> {
    struct Word {
        start: f64,
        end: f64,
        text: String,
    }
    let mut words: Vec<Word> = Vec::new();
    let mut boundary = true;
    for (start, end, text) in tokens {
        if text.starts_with([' ', BOUNDARY]) {
            boundary = true;
        }
        let letters = text.trim_start_matches([' ', BOUNDARY]);
        if letters.trim().is_empty() {
            continue;
        }
        match words.last_mut() {
            Some(word) if !boundary => {
                word.text.push_str(letters);
                word.end = *end;
            }
            _ => words.push(Word {
                start: *start,
                end: *end,
                text: letters.to_string(),
            }),
        }
        boundary = false;
    }

    let mut sentences = Vec::new();
    let mut current: Vec<Word> = Vec::new();
    let finish = |current: &mut Vec<Word>, sentences: &mut Vec<Spoken>| {
        if let (Some(first), Some(last)) = (current.first(), current.last()) {
            let text = current
                .iter()
                .map(|w| w.text.as_str())
                .collect::<Vec<_>>()
                .join(" ");
            sentences.push(Spoken {
                start: first.start,
                end: last.end,
                text,
            });
        }
        current.clear();
    };
    for word in words {
        // Closing quotes and brackets after the stop still end the sentence.
        let ends = word
            .text
            .trim_end_matches(['"', '\'', ')', ']', '\u{201D}', '\u{2019}'])
            .ends_with(['.', '?', '!']);
        current.push(word);
        if ends {
            finish(&mut current, &mut sentences);
        }
    }
    finish(&mut current, &mut sentences);
    sentences
}

fn recognise(model: &mut ParakeetModel, samples: &[f32], preview: bool) -> Result<String, String> {
    let started = Instant::now();
    let result = model
        .transcribe_with(samples, &ParakeetParams::default())
        .map_err(|e| format!("Transcription failed: {e}"))?;
    let text = result.text.trim().to_string();
    // Lengths only. What was said never goes in a log.
    let seconds = samples.len() as f32 / crate::audio::SPEECH_RATE as f32;
    let characters = text.chars().count();
    let elapsed = started.elapsed();
    if preview {
        tracing::debug!(seconds, characters, ?elapsed, "previewed");
    } else {
        tracing::info!(seconds, characters, ?elapsed, "transcribed");
    }
    Ok(text)
}

#[cfg(test)]
mod sentence_tests {
    use super::*;

    fn tokens(list: &[(f64, &str)]) -> Vec<(f64, f64, String)> {
        list.iter()
            .enumerate()
            .map(|(i, (start, text))| {
                let end = list
                    .get(i + 1)
                    .map(|(next, _)| *next)
                    .unwrap_or(start + 0.1);
                (*start, end, text.to_string())
            })
            .collect()
    }

    #[test]
    fn a_number_keeps_the_space_the_model_wrote_before_it() {
        let heard = tokens(&[
            (0.0, " Re"),
            (0.1, "ven"),
            (0.2, "ue"),
            (0.4, " c"),
            (0.5, "ame"),
            (0.7, " in"),
            (0.9, " "),
            (1.0, "4"),
            (1.1, "%"),
            (1.3, " ab"),
            (1.4, "ove"),
            (1.6, " the"),
            (1.8, " for"),
            (1.9, "ec"),
            (2.0, "ast"),
            (2.2, "."),
            (3.0, " We"),
            (3.2, " met"),
            (3.4, " at"),
            (3.5, " "),
            (3.6, "1"),
            (3.7, "0"),
            (3.8, "."),
        ]);
        let sentences = group_sentences(&heard);
        assert_eq!(sentences.len(), 2);
        assert_eq!(sentences[0].text, "Revenue came in 4% above the forecast.");
        assert_eq!(sentences[1].text, "We met at 10.");
        assert_eq!(sentences[0].start, 0.0);
        assert_eq!(sentences[1].start, 3.0);
        assert!((sentences[1].end - 3.9).abs() < 1e-9);
    }

    #[test]
    fn a_decimal_point_does_not_end_a_sentence() {
        let heard = tokens(&[
            (0.0, " It"),
            (0.2, " grew"),
            (0.4, " "),
            (0.5, "4"),
            (0.6, "."),
            (0.7, "5"),
            (0.8, "%"),
            (1.0, " this"),
            (1.2, " year"),
            (1.4, "."),
        ]);
        let sentences = group_sentences(&heard);
        assert_eq!(sentences.len(), 1);
        assert_eq!(sentences[0].text, "It grew 4.5% this year.");
    }

    #[test]
    fn words_without_a_full_stop_are_still_a_line() {
        let heard = tokens(&[(0.0, " so"), (0.2, " that"), (0.4, "'s"), (0.6, " it")]);
        let sentences = group_sentences(&heard);
        assert_eq!(sentences.len(), 1);
        assert_eq!(sentences[0].text, "so that's it");
    }

    #[test]
    fn a_quoted_question_ends_its_sentence() {
        let heard = tokens(&[
            (0.0, " She"),
            (0.2, " said"),
            (0.4, " \"why"),
            (0.6, "?\""),
            (1.0, " Then"),
            (1.2, " left"),
            (1.4, "."),
        ]);
        let sentences = group_sentences(&heard);
        assert_eq!(sentences.len(), 2);
        assert_eq!(sentences[0].text, "She said \"why?\"");
    }
}
