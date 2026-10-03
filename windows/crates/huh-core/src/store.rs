//! Reading and writing the files huh? keeps.
//!
//! Same names, same shapes and the same pretty-printed, key-sorted JSON the Mac
//! writes, so a folder copied from one to the other opens without conversion.
//! The only difference is where the folder lives: `%APPDATA%\Huh` rather than
//! `~/Library/Application Support/Huh`. `Huh`, not `huh?`, for the same reason
//! as on the Mac -- the display name has a character in it that a path cannot.
//!
//! This is the file layer only. What the files mean -- which rule fires, what
//! a new name rewrites -- is the library's.
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use serde::de::DeserializeOwned;
use serde::Serialize;

use crate::settings::Settings;

/// The folder every file lives in.
pub fn directory() -> PathBuf {
    if let Ok(explicit) = std::env::var("HUH_DATA_DIR") {
        return PathBuf::from(explicit);
    }
    #[cfg(windows)]
    let base = std::env::var("APPDATA")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("."));
    #[cfg(not(windows))]
    let base = std::env::var("HOME")
        .map(|home| PathBuf::from(home).join("Library/Application Support"))
        .unwrap_or_else(|_| PathBuf::from("."));
    base.join("Huh")
}

/// How many transcripts are kept.
pub const HISTORY_LIMIT: usize = 500;

/// What reading a file found.
///
/// Three answers rather than two, because "not there" and "there but
/// unreadable" call for opposite things: the first is a fresh start, and the
/// second is someone's data that must not be overwritten by an empty list the
/// next time anything is saved.
#[derive(Debug)]
pub enum Loaded<T> {
    Missing,
    Read(T),
    Corrupt(String),
}

pub fn load<T: DeserializeOwned>(path: &Path) -> Loaded<T> {
    let raw = match fs::read_to_string(path) {
        Ok(raw) => raw,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Loaded::Missing,
        Err(error) => return Loaded::Corrupt(error.to_string()),
    };
    match serde_json::from_str(&raw) {
        Ok(value) => Loaded::Read(value),
        Err(error) => Loaded::Corrupt(error.to_string()),
    }
}

fn read_json<T: DeserializeOwned + Default>(path: &Path) -> T {
    match load(path) {
        Loaded::Read(value) => value,
        _ => T::default(),
    }
}

pub fn write_json<T: Serialize>(path: &Path, value: &T) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    // Pretty-printed with two spaces, the same as Swift's `.prettyPrinted`,
    // because the dictionary is documented as editable by hand.
    let body = serde_json::to_string_pretty(value)
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
    // Written beside the target and renamed, so a crash mid-write cannot leave
    // a half a dictionary behind.
    let temporary = path.with_extension("json.tmp");
    fs::write(&temporary, body.as_bytes())?;
    fs::rename(&temporary, path)
}

pub struct Stores {
    pub root: PathBuf,
}

impl Default for Stores {
    fn default() -> Self {
        Self::new(directory())
    }
}

impl Stores {
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    pub fn dictionary_path(&self) -> PathBuf {
        self.root.join("dictionary.json")
    }
    pub fn people_path(&self) -> PathBuf {
        self.root.join("people.json")
    }
    pub fn history_path(&self) -> PathBuf {
        self.root.join("history.json")
    }
    /// Where an unreadable history is copied before anything else happens.
    pub fn history_corrupt_path(&self) -> PathBuf {
        self.root.join("history.corrupt.json")
    }
    pub fn decisions_path(&self) -> PathBuf {
        self.root.join("decisions.json")
    }
    pub fn settings_path(&self) -> PathBuf {
        self.root.join("settings.json")
    }

    /// Settings fall back to defaults when unreadable: they are a handful of
    /// choices, cheap to make again, and nothing else depends on them.
    pub fn settings(&self) -> Settings {
        read_json(&self.settings_path())
    }
    pub fn save_settings(&self, value: &Settings) -> io::Result<()> {
        write_json(&self.settings_path(), value)
    }
}
