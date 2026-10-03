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
use transcribe_rs::onnx::parakeet::{ParakeetModel, ParakeetParams};
use transcribe_rs::onnx::Quantization;

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
    /// all the final pass for the same utterance, which must never wait behind
    /// a preview of it. Declining, or failing, is `None`: a preview that does
    /// not arrive costs nothing, and the final pass reports its own errors.
    pub fn preview(&self, samples: Vec<f32>) -> Option<String> {
        let (reply, answer) = bounded(1);
        self.jobs.send(Job::Preview { samples, reply }).ok()?;
        answer.recv().ok().flatten()
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
