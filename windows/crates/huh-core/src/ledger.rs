//! What has been decided about each word the learning pass raised, so that
//! nothing is ever asked about twice.
//!
//! `decisions.json`, the same file the Mac's `DecisionLedger` keeps: a bare
//! array of records sorted by token, one per word, the later record winning
//! when a word appears twice. A word anyone has ruled on -- added, filed under
//! People, turned into a correction, or dismissed -- is known from then on,
//! and every producer of suggestions checks here first.
use std::collections::BTreeMap;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::model::swift_date;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Decision {
    Person,
    Term,
    Correction,
    Ignored,
}

/// One ruling. Fields in alphabetical order, as the Mac writes them.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Record {
    #[serde(with = "swift_date")]
    pub date: DateTime<Utc>,
    pub decision: Decision,
    /// The word as it was shown.
    pub display: String,
    /// What it was resolved to: the name, the term, the correction's target.
    /// Empty for a dismissal.
    pub resolved: String,
    /// The word, trimmed and lowercased: the key.
    pub token: String,
}

#[derive(Debug, Default, Clone)]
pub struct Ledger {
    records: BTreeMap<String, Record>,
}

impl Ledger {
    pub fn key(token: &str) -> String {
        token.trim().to_lowercase()
    }

    pub fn from_records(records: Vec<Record>) -> Self {
        let mut ledger = Self::default();
        for record in records {
            ledger.records.insert(Self::key(&record.token), record);
        }
        ledger
    }

    /// The file's contents: sorted by token, because the map is.
    pub fn to_records(&self) -> Vec<Record> {
        self.records.values().cloned().collect()
    }

    pub fn decision(&self, token: &str) -> Option<&Record> {
        self.records.get(&Self::key(token))
    }

    pub fn is_decided(&self, token: &str) -> bool {
        self.decision(token).is_some()
    }

    pub fn is_ignored(&self, token: &str) -> bool {
        self.decision(token)
            .map(|record| record.decision == Decision::Ignored)
            .unwrap_or(false)
    }

    pub fn ignored_count(&self) -> usize {
        self.records
            .values()
            .filter(|record| record.decision == Decision::Ignored)
            .count()
    }

    /// Every token anyone has ruled on, lowercased.
    pub fn keys(&self) -> impl Iterator<Item = &String> {
        self.records.keys()
    }

    pub fn record(&mut self, token: &str, decision: Decision, resolved: &str) {
        let key = Self::key(token);
        if key.is_empty() {
            return;
        }
        self.records.insert(
            key.clone(),
            Record {
                date: Utc::now(),
                decision,
                display: token.trim().to_string(),
                resolved: resolved.trim().to_string(),
                token: key,
            },
        );
    }

    /// Forgets every dismissal, so those words can be raised again. What was
    /// accepted stays accepted. Returns how many were forgotten.
    pub fn restore_ignored(&mut self) -> usize {
        let before = self.records.len();
        self.records
            .retain(|_, record| record.decision != Decision::Ignored);
        before - self.records.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_word_is_known_however_it_is_cased() {
        let mut ledger = Ledger::default();
        ledger.record("  Leena ", Decision::Person, "Lena Vasquez");
        assert!(ledger.is_decided("leena"));
        assert!(ledger.is_decided("LEENA"));
        let record = ledger.decision("Leena").unwrap();
        assert_eq!(record.display, "Leena");
        assert_eq!(record.resolved, "Lena Vasquez");
        assert_eq!(record.token, "leena");
    }

    #[test]
    fn restoring_dismissals_keeps_what_was_accepted() {
        let mut ledger = Ledger::default();
        ledger.record("versal", Decision::Ignored, "");
        ledger.record("supabase", Decision::Term, "Supabase");
        assert_eq!(ledger.ignored_count(), 1);
        assert_eq!(ledger.restore_ignored(), 1);
        assert!(!ledger.is_decided("versal"));
        assert!(ledger.is_decided("supabase"));
    }

    #[test]
    fn the_file_is_sorted_by_token_and_the_later_record_wins() {
        let ledger = Ledger::from_records(vec![
            Record {
                date: Utc::now(),
                decision: Decision::Ignored,
                display: "zed".into(),
                resolved: String::new(),
                token: "zed".into(),
            },
            Record {
                date: Utc::now(),
                decision: Decision::Ignored,
                display: "Ada".into(),
                resolved: String::new(),
                token: "ada".into(),
            },
            Record {
                date: Utc::now(),
                decision: Decision::Person,
                display: "Ada".into(),
                resolved: "Ada Okonkwo".into(),
                token: "ada".into(),
            },
        ]);
        let tokens: Vec<String> = ledger.to_records().into_iter().map(|r| r.token).collect();
        assert_eq!(tokens, vec!["ada", "zed"]);
        assert_eq!(ledger.decision("ada").unwrap().decision, Decision::Person);
    }
}
