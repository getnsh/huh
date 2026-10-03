//! The data models, and the shapes they take on disk.
//!
//! Field order is alphabetical on purpose. The Mac encodes with
//! `JSONEncoder.sortedKeys`, and serde writes a struct's fields in declaration
//! order, so declaring them sorted is what makes a file written on Windows
//! byte-identical to one written on a Mac. Dates are ISO 8601 to the second,
//! which is what Swift's `.iso8601` strategy emits.
use chrono::{DateTime, SecondsFormat, Utc};
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use uuid::Uuid;

/// Swift's `.iso8601` strategy: no fractional seconds, always `Z`.
pub mod swift_date {
    use super::*;

    pub fn serialize<S: Serializer>(value: &DateTime<Utc>, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&value.to_rfc3339_opts(SecondsFormat::Secs, true))
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<DateTime<Utc>, D::Error> {
        let raw = String::deserialize(d)?;
        DateTime::parse_from_rfc3339(&raw)
            .map(|value| value.with_timezone(&Utc))
            .map_err(serde::de::Error::custom)
    }
}

fn yes() -> bool {
    true
}

fn now() -> DateTime<Utc> {
    Utc::now()
}

/// A term the recogniser should be biased toward producing.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VocabularyTerm {
    #[serde(default = "yes")]
    pub enabled: bool,
    #[serde(default = "Uuid::new_v4")]
    pub id: Uuid,
    #[serde(default)]
    pub note: String,
    pub text: String,
}

/// A substitution rule: when the recogniser produces `hear`, write `write`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CorrectionPair {
    #[serde(default = "yes")]
    pub enabled: bool,
    /// The text the recogniser produces.
    pub hear: String,
    /// How many times this rule has fired, so ineffective entries show up.
    #[serde(default)]
    pub hit_count: u32,
    #[serde(default = "Uuid::new_v4")]
    pub id: Uuid,
    /// The text that should replace it.
    pub write: String,
}

impl CorrectionPair {
    pub fn new(hear: impl Into<String>, write: impl Into<String>) -> Self {
        Self {
            enabled: true,
            hear: hear.into(),
            hit_count: 0,
            id: Uuid::new_v4(),
            write: write.into(),
        }
    }
}

/// A correction that fired on a specific transcript.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AppliedCorrection {
    pub hear: String,
    #[serde(default = "Uuid::new_v4")]
    pub id: Uuid,
    /// The literal text that was replaced, not the pattern.
    pub matched: String,
    pub write: String,
}

/// A person the recogniser is expected to encounter by name.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Person {
    #[serde(default = "now", with = "swift_date")]
    pub added_at: DateTime<Utc>,
    #[serde(default)]
    pub aliases: Vec<String>,
    #[serde(default = "yes")]
    pub enabled: bool,
    #[serde(default = "Uuid::new_v4")]
    pub id: Uuid,
    /// Whether the entry came from the analysis pass rather than being typed.
    #[serde(default)]
    pub learned: bool,
    /// The canonical spelling. This is what gets written.
    pub name: String,
    #[serde(default)]
    pub note: String,
}

impl Person {
    pub fn all_spellings(&self) -> Vec<&str> {
        let mut out = vec![self.name.as_str()];
        out.extend(self.aliases.iter().map(String::as_str));
        out
    }

    pub fn matches(&self, token: &str) -> bool {
        let needle = token.trim().to_lowercase();
        if needle.is_empty() {
            return false;
        }
        self.all_spellings()
            .iter()
            .any(|spelling| spelling.trim().to_lowercase() == needle)
    }

    /// Each alias becomes a rewrite rule pointing at the canonical spelling.
    pub fn correction_rules(&self) -> Vec<CorrectionPair> {
        if !self.enabled {
            return Vec::new();
        }
        self.aliases
            .iter()
            .filter(|alias| !alias.trim().is_empty())
            .map(|alias| CorrectionPair::new(alias.trim(), self.name.trim()))
            .collect()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum TranscriptSource {
    #[default]
    Dictation,
    File,
    /// A session that ran in the background: a call, or anything else
    /// transcribed live from both the microphone and the machine's output.
    Meeting,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TranscriptSegment {
    #[serde(default = "Uuid::new_v4")]
    pub id: Uuid,
    pub start: f64,
    pub text: String,
}

impl TranscriptSegment {
    pub fn timecode(&self) -> String {
        let total = self.start.round().max(0.0) as u64;
        format!("{:02}:{:02}", total / 60, total % 60)
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Transcript {
    #[serde(default)]
    pub analysis_findings: u32,
    #[serde(default)]
    pub analyzed_at: Option<String>,
    #[serde(default)]
    pub cleanup_removed: u32,
    #[serde(default)]
    pub corrections: Vec<AppliedCorrection>,
    #[serde(default = "now", with = "swift_date")]
    pub date: DateTime<Utc>,
    #[serde(default)]
    pub duration: f64,
    #[serde(default)]
    pub engine: String,
    #[serde(default = "Uuid::new_v4")]
    pub id: Uuid,
    /// Straight from the engine, before the dictionary touched it.
    pub raw: String,
    #[serde(default)]
    pub segments: Vec<TranscriptSegment>,
    #[serde(default)]
    pub source: TranscriptSource,
    #[serde(default)]
    pub source_name: String,
    #[serde(default)]
    pub source_path: String,
    #[serde(default)]
    pub summary: String,
    #[serde(default)]
    pub summary_date: Option<String>,
    /// The text that was inserted.
    pub text: String,
}

impl Transcript {
    pub fn word_count(&self) -> usize {
        self.text
            .split([' ', '\n'])
            .filter(|word| !word.is_empty())
            .count()
    }

    /// What to call this in a list.
    pub fn display_name(&self) -> String {
        match self.source {
            TranscriptSource::File => self.source_name.clone(),
            TranscriptSource::Meeting => {
                if self.source_name.is_empty() {
                    "Live session".into()
                } else {
                    self.source_name.clone()
                }
            }
            TranscriptSource::Dictation => "Dictation".into(),
        }
    }
}

/// `dictionary.json`.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DictionaryFile {
    #[serde(default)]
    pub corrections: Vec<CorrectionPair>,
    #[serde(default)]
    pub terms: Vec<VocabularyTerm>,
    #[serde(default = "one")]
    pub version: u32,
}

/// `people.json`.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PeopleFile {
    #[serde(default)]
    pub people: Vec<Person>,
    #[serde(default = "one")]
    pub version: u32,
}

fn one() -> u32 {
    1
}
