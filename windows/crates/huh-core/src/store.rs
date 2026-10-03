//! Reading and writing the files huh? keeps.
//!
//! Same names, same shapes and the same pretty-printed, key-sorted JSON the Mac
//! writes, so a folder copied from one to the other opens without conversion.
//! The only difference is where the folder lives: `%APPDATA%\Huh` rather than
//! `~/Library/Application Support/Huh`. `Huh`, not `huh?`, for the same reason
//! as on the Mac -- the display name has a character in it that a path cannot.
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use serde::de::DeserializeOwned;
use serde::Serialize;

use crate::model::{CorrectionPair, DictionaryFile, PeopleFile, Transcript, VocabularyTerm};
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

/// How many bias strings the recogniser is given. Long context lists make
/// these models drift and emit spurious text on near-silent audio.
pub const BIAS_LIMIT: usize = 120;

/// How many transcripts are kept.
pub const HISTORY_LIMIT: usize = 500;

fn read_json<T: DeserializeOwned + Default>(path: &Path) -> T {
    let Ok(raw) = fs::read_to_string(path) else {
        return T::default();
    };
    serde_json::from_str(&raw).unwrap_or_default()
}

fn write_json<T: Serialize>(path: &Path, value: &T) -> io::Result<()> {
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
    pub fn settings_path(&self) -> PathBuf {
        self.root.join("settings.json")
    }

    pub fn dictionary(&self) -> DictionaryFile {
        read_json(&self.dictionary_path())
    }
    pub fn save_dictionary(&self, value: &DictionaryFile) -> io::Result<()> {
        write_json(&self.dictionary_path(), value)
    }

    pub fn people(&self) -> PeopleFile {
        read_json(&self.people_path())
    }
    pub fn save_people(&self, value: &PeopleFile) -> io::Result<()> {
        write_json(&self.people_path(), value)
    }

    pub fn history(&self) -> Vec<Transcript> {
        read_json(&self.history_path())
    }
    pub fn save_history(&self, value: &[Transcript]) -> io::Result<()> {
        let trimmed = if value.len() > HISTORY_LIMIT {
            &value[..HISTORY_LIMIT]
        } else {
            value
        };
        write_json(&self.history_path(), &trimmed)
    }

    pub fn settings(&self) -> Settings {
        read_json(&self.settings_path())
    }
    pub fn save_settings(&self, value: &Settings) -> io::Result<()> {
        write_json(&self.settings_path(), value)
    }

    /// Everything dictation needs: the spellings to bias the recogniser toward,
    /// and the rewrites to apply afterwards.
    ///
    /// Assembled here rather than read from one store, because names live in
    /// their own file and dictation has to see both without either store
    /// knowing the other exists.
    pub fn bias(&self) -> Vec<String> {
        let people = self.people();
        let dictionary = self.dictionary();
        let mut seen = std::collections::HashSet::new();
        let mut out = Vec::new();
        // Names lead: they are what recognition gets wrong most often, and the
        // list is truncated.
        let candidates = people
            .people
            .iter()
            .filter(|person| person.enabled)
            .flat_map(|person| person.all_spellings().into_iter().map(str::to_string))
            .chain(
                dictionary
                    .terms
                    .iter()
                    .filter(|term| term.enabled)
                    .map(|term| term.text.clone()),
            );
        for value in candidates {
            let text = value.trim().to_string();
            if text.is_empty() || !seen.insert(text.to_lowercase()) {
                continue;
            }
            out.push(text);
            if out.len() == BIAS_LIMIT {
                break;
            }
        }
        out
    }

    /// The dictionary comes first, so a rule written by hand wins over one
    /// derived from an alias.
    pub fn corrections(&self) -> Vec<CorrectionPair> {
        let mut out = self.dictionary().corrections;
        for person in self.people().people {
            out.extend(person.correction_rules());
        }
        out
    }

    pub fn add_term(&self, text: &str, note: &str) -> io::Result<()> {
        let mut file = self.dictionary();
        file.terms.push(VocabularyTerm {
            enabled: true,
            id: uuid::Uuid::new_v4(),
            note: note.trim().to_string(),
            text: text.trim().to_string(),
        });
        self.save_dictionary(&file)
    }

    pub fn add_correction(&self, hear: &str, write: &str) -> io::Result<()> {
        let mut file = self.dictionary();
        file.corrections
            .push(CorrectionPair::new(hear.trim(), write.trim()));
        self.save_dictionary(&file)
    }

    pub fn add_transcript(&self, transcript: Transcript) -> io::Result<()> {
        let mut history = self.history();
        history.insert(0, transcript);
        self.save_history(&history)
    }
}
