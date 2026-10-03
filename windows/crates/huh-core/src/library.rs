//! Everything a person has taught huh? and everything it has written down:
//! the dictionary, the people, the history, and the ledger of decisions.
//!
//! One owner, so every change goes through one place with the Mac's rules:
//! a new correction is applied to the transcripts already kept and says how
//! many it fixed; a new name's other spellings start rewriting to it at once;
//! a file that could not be read is never overwritten by the empty list that
//! stood in for it. The app holds this behind a single lock, so dictation
//! recording a hit and the window adding a rule cannot undo each other.
use std::collections::HashSet;

use chrono::{SecondsFormat, Utc};
use uuid::Uuid;

use crate::corrections;
use crate::ledger::{Decision, Ledger, Record};
use crate::model::{
    AppliedCorrection, CorrectionPair, DictionaryFile, PeopleFile, Person, Transcript,
    VocabularyTerm,
};
use crate::store::{self, Loaded, Stores, HISTORY_LIMIT};

/// How many dictionary hints go to the recogniser.
pub const DICTIONARY_BIAS_LIMIT: usize = 40;
/// How many names go to it.
pub const PEOPLE_BIAS_LIMIT: usize = 24;
/// How many hints in all.
pub const BIAS_LIMIT: usize = 40;

pub struct Library {
    pub stores: Stores,
    pub dictionary: DictionaryFile,
    pub people: PeopleFile,
    pub history: Vec<Transcript>,
    pub ledger: Ledger,
    pub dictionary_error: Option<String>,
    pub people_error: Option<String>,
    pub history_error: Option<String>,
    pub ledger_error: Option<String>,
    /// What the last new correction did to the history, shown once.
    pub retro_note: Option<String>,
    /// How dictionary.json and people.json stood when this library last read
    /// or wrote them, so an edit made by anything else can be told apart.
    dictionary_stamp: Option<Stamp>,
    people_stamp: Option<Stamp>,
}

/// When a file was last written, as the file system reports it, and its
/// length: two different writes all but never share both.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Stamp {
    modified: std::time::SystemTime,
    bytes: u64,
}

fn stamp(path: &std::path::Path) -> Option<Stamp> {
    let meta = std::fs::metadata(path).ok()?;
    Some(Stamp {
        modified: meta.modified().ok()?,
        bytes: meta.len(),
    })
}

/// Which files `Library::reread` read again.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct Reread {
    pub dictionary: bool,
    pub people: bool,
}

fn plural(n: usize, one: &str, many: &str) -> String {
    format!("{n} {}", if n == 1 { one } else { many })
}

/// The Mac's first-run dictionary: five things people dictate about that
/// recognisers reliably get wrong, so a correction can be seen working on the
/// first day.
fn seeded() -> DictionaryFile {
    let terms = [
        "Supabase",
        "Vercel",
        "Kubernetes",
        "PostgreSQL",
        "PowerShell",
    ];
    let corrections = [
        ("super base", "Supabase"),
        ("versal", "Vercel"),
        ("cuber netties", "Kubernetes"),
        ("post gress", "PostgreSQL"),
        ("power shell", "PowerShell"),
    ];
    DictionaryFile {
        corrections: corrections
            .iter()
            .map(|(hear, write)| CorrectionPair::new(*hear, *write))
            .collect(),
        terms: terms
            .iter()
            .map(|text| VocabularyTerm {
                enabled: true,
                id: Uuid::new_v4(),
                note: String::new(),
                text: (*text).to_string(),
            })
            .collect(),
        version: 1,
    }
}

impl Library {
    pub fn open(stores: Stores) -> Self {
        let mut library = Self {
            stores,
            dictionary: DictionaryFile::default(),
            people: PeopleFile::default(),
            history: Vec::new(),
            ledger: Ledger::default(),
            dictionary_error: None,
            people_error: None,
            history_error: None,
            ledger_error: None,
            retro_note: None,
            dictionary_stamp: None,
            people_stamp: None,
        };

        match store::load::<DictionaryFile>(&library.stores.dictionary_path()) {
            Loaded::Read(file) => library.dictionary = file,
            Loaded::Missing => {
                library.dictionary = seeded();
                library.save_dictionary();
            }
            Loaded::Corrupt(why) => {
                library.dictionary_error = Some(format!("dictionary.json couldn't be read: {why}"))
            }
        }

        match store::load::<PeopleFile>(&library.stores.people_path()) {
            Loaded::Read(file) => library.people = file,
            Loaded::Missing => library.save_people(),
            Loaded::Corrupt(why) => {
                library.people_error = Some(format!("people.json couldn't be read: {why}"))
            }
        }

        library.dictionary_stamp = stamp(&library.stores.dictionary_path());
        library.people_stamp = stamp(&library.stores.people_path());

        match store::load::<Vec<Transcript>>(&library.stores.history_path()) {
            Loaded::Read(history) => library.history = history,
            Loaded::Missing => {}
            Loaded::Corrupt(why) => {
                // Kept aside before anything else can touch it.
                let _ = std::fs::copy(
                    library.stores.history_path(),
                    library.stores.history_corrupt_path(),
                );
                library.history_error = Some(format!("history.json couldn't be read: {why}"));
            }
        }

        match store::load::<Vec<Record>>(&library.stores.decisions_path()) {
            Loaded::Read(records) => library.ledger = Ledger::from_records(records),
            Loaded::Missing => {}
            Loaded::Corrupt(why) => {
                library.ledger_error = Some(format!("decisions.json couldn't be read: {why}"))
            }
        }
        library
    }

    /* ── Saving: nothing is written over a file that could not be read ── */

    fn save_dictionary(&mut self) {
        if self.dictionary_error.is_some() {
            return;
        }
        if let Err(error) = store::write_json(&self.stores.dictionary_path(), &self.dictionary) {
            self.dictionary_error = Some(format!("Couldn't save dictionary.json: {error}"));
        }
        self.dictionary_stamp = stamp(&self.stores.dictionary_path());
    }

    fn save_people(&mut self) {
        if self.people_error.is_some() {
            return;
        }
        if let Err(error) = store::write_json(&self.stores.people_path(), &self.people) {
            self.people_error = Some(format!("Couldn't save people.json: {error}"));
        }
        self.people_stamp = stamp(&self.stores.people_path());
    }

    /* ── Edits made outside the app ── */

    /// Reads again whichever of dictionary.json and people.json something
    /// other than this library has changed since it last read or wrote it, as
    /// the Mac does when one is edited in a text editor.
    ///
    /// A file caught half-written reads as unreadable, which stops the app
    /// writing over it until the editor finishes and it is read again whole.
    pub fn reread(&mut self) -> Reread {
        let mut changed = Reread::default();

        let path = self.stores.dictionary_path();
        let now = stamp(&path);
        if now.is_some() && now != self.dictionary_stamp {
            self.dictionary_stamp = now;
            changed.dictionary = true;
            match store::load::<DictionaryFile>(&path) {
                Loaded::Read(file) => {
                    self.dictionary = file;
                    self.dictionary_error = None;
                }
                Loaded::Corrupt(why) => {
                    self.dictionary_error = Some(format!("dictionary.json couldn't be read: {why}"))
                }
                Loaded::Missing => changed.dictionary = false,
            }
        }

        let path = self.stores.people_path();
        let now = stamp(&path);
        if now.is_some() && now != self.people_stamp {
            self.people_stamp = now;
            changed.people = true;
            match store::load::<PeopleFile>(&path) {
                Loaded::Read(file) => {
                    self.people = file;
                    self.people_error = None;
                }
                Loaded::Corrupt(why) => {
                    self.people_error = Some(format!("people.json couldn't be read: {why}"))
                }
                Loaded::Missing => changed.people = false,
            }
        }
        changed
    }

    fn save_history(&mut self) {
        if self.history_error.is_some() {
            return;
        }
        self.history.truncate(HISTORY_LIMIT);
        if let Err(error) = store::write_json(&self.stores.history_path(), &self.history) {
            self.history_error = Some(format!("Couldn't save history.json: {error}"));
        }
    }

    fn save_ledger(&mut self) {
        if self.ledger_error.is_some() {
            return;
        }
        let records = self.ledger.to_records();
        if let Err(error) = store::write_json(&self.stores.decisions_path(), &records) {
            self.ledger_error = Some(format!("Couldn't save decisions.json: {error}"));
        }
    }

    /* ── Words ── */

    pub fn add_term(&mut self, text: &str, note: &str) -> Option<Uuid> {
        let text = text.trim();
        if text.is_empty() {
            return None;
        }
        let id = Uuid::new_v4();
        self.dictionary.terms.push(VocabularyTerm {
            enabled: true,
            id,
            note: note.trim().to_string(),
            text: text.to_string(),
        });
        self.save_dictionary();
        Some(id)
    }

    pub fn update_term(&mut self, term: VocabularyTerm) -> bool {
        let Some(slot) = self.dictionary.terms.iter_mut().find(|t| t.id == term.id) else {
            return false;
        };
        slot.text = term.text.trim().to_string();
        slot.note = term.note.trim().to_string();
        slot.enabled = term.enabled;
        self.save_dictionary();
        true
    }

    pub fn set_term_enabled(&mut self, id: Uuid, on: bool) {
        if let Some(term) = self.dictionary.terms.iter_mut().find(|t| t.id == id) {
            term.enabled = on;
            self.save_dictionary();
        }
    }

    pub fn delete_term(&mut self, id: Uuid) {
        self.dictionary.terms.retain(|t| t.id != id);
        self.save_dictionary();
    }

    /* ── Corrections ── */

    /// Adds a rule, applies it to every transcript already kept, and says so.
    pub fn add_correction(&mut self, hear: &str, write: &str) -> Option<Uuid> {
        let (hear, write) = (hear.trim(), write.trim());
        if hear.is_empty() || write.is_empty() {
            return None;
        }
        let pair = CorrectionPair::new(hear, write);
        let id = pair.id;
        self.dictionary.corrections.push(pair.clone());
        self.save_dictionary();

        let fixed = self.apply_retroactively(&pair);
        self.retro_note = Some(if fixed > 0 {
            format!(
                "“{hear}” → “{write}” — also fixed in {}.",
                plural(fixed, "existing transcript", "existing transcripts")
            )
        } else {
            format!("“{hear}” → “{write}” added. It didn't appear in any existing transcript.")
        });
        // The Mac counts the rule's first firing at once, so a new rule shows
        // that it is live.
        self.record_hits(&[AppliedCorrection {
            hear: hear.to_string(),
            id: Uuid::new_v4(),
            matched: hear.to_string(),
            write: write.to_string(),
        }]);
        Some(id)
    }

    pub fn update_correction(&mut self, pair: CorrectionPair) -> bool {
        let Some(slot) = self
            .dictionary
            .corrections
            .iter_mut()
            .find(|p| p.id == pair.id)
        else {
            return false;
        };
        slot.hear = pair.hear.trim().to_string();
        slot.write = pair.write.trim().to_string();
        slot.enabled = pair.enabled;
        slot.hit_count = pair.hit_count;
        self.save_dictionary();
        true
    }

    pub fn set_correction_enabled(&mut self, id: Uuid, on: bool) {
        if let Some(pair) = self.dictionary.corrections.iter_mut().find(|p| p.id == id) {
            pair.enabled = on;
            self.save_dictionary();
        }
    }

    pub fn delete_correction(&mut self, id: Uuid) {
        self.dictionary.corrections.retain(|p| p.id != id);
        self.save_dictionary();
    }

    /// Counts each correction that fired against the rule it came from, so the
    /// dictionary can show which entries are earning their place.
    ///
    /// Matched on the trigger, ignoring case, as the Mac's
    /// `DictionaryStore.recordHits` matches. A rule derived from a person's
    /// alias lives in `people.json` and keeps no count, so it is not looked for,
    /// and nothing is written when no rule in the dictionary fired.
    pub fn record_hits(&mut self, applied: &[AppliedCorrection]) {
        let mut changed = false;
        for hit in applied {
            let trigger = hit.hear.to_lowercase();
            if let Some(pair) = self
                .dictionary
                .corrections
                .iter_mut()
                .find(|pair| pair.hear.to_lowercase() == trigger)
            {
                pair.hit_count += 1;
                changed = true;
            }
        }
        if changed {
            self.save_dictionary();
        }
    }

    pub fn dismiss_retro_note(&mut self) {
        self.retro_note = None;
    }

    /* ── People ── */

    pub fn person_named(&self, name: &str) -> Option<&Person> {
        let wanted = name.trim().to_lowercase();
        self.people
            .people
            .iter()
            .find(|p| p.name.trim().to_lowercase() == wanted)
    }

    /// Adds someone, or, when they are already here, gives them the alias.
    /// Every alias starts rewriting to the name at once, in the history too.
    pub fn add_person(
        &mut self,
        name: &str,
        alias: Option<&str>,
        note: &str,
        learned: bool,
    ) -> Option<Uuid> {
        let name = name.trim();
        if name.is_empty() {
            return None;
        }
        if let Some(existing) = self.person_named(name).map(|p| p.id) {
            if let Some(alias) = alias {
                self.add_alias(alias, name);
            }
            return Some(existing);
        }
        let aliases: Vec<String> = alias
            .map(str::trim)
            .filter(|a| !a.is_empty() && a.to_lowercase() != name.to_lowercase())
            .map(str::to_string)
            .into_iter()
            .collect();
        let id = Uuid::new_v4();
        self.people.people.push(Person {
            added_at: Utc::now(),
            aliases: aliases.clone(),
            enabled: true,
            id,
            learned,
            name: name.to_string(),
            note: note.trim().to_string(),
        });
        self.save_people();
        for alias in aliases {
            self.apply_retroactively(&CorrectionPair::new(alias, name));
        }
        Some(id)
    }

    /// Adds one more way of mishearing someone. An unknown name is added as a
    /// person the learning pass found.
    pub fn add_alias(&mut self, alias: &str, for_name: &str) -> bool {
        let alias = alias.trim();
        if alias.is_empty() {
            return false;
        }
        let Some(index) = self
            .people
            .people
            .iter()
            .position(|p| p.name.trim().to_lowercase() == for_name.trim().to_lowercase())
        else {
            return self.add_person(for_name, Some(alias), "", true).is_some();
        };
        let person = &mut self.people.people[index];
        let lowered = alias.to_lowercase();
        if person.name.trim().to_lowercase() == lowered
            || person
                .aliases
                .iter()
                .any(|a| a.trim().to_lowercase() == lowered)
        {
            return true;
        }
        person.aliases.push(alias.to_string());
        let name = person.name.trim().to_string();
        self.save_people();
        self.apply_retroactively(&CorrectionPair::new(alias, name));
        true
    }

    /// An edit from the sheet: the name, the aliases and the note change; who
    /// they are, when they arrived and how they were found do not.
    pub fn update_person(&mut self, person: Person) -> bool {
        let Some(slot) = self.people.people.iter_mut().find(|p| p.id == person.id) else {
            return false;
        };
        slot.name = person.name.trim().to_string();
        slot.aliases = person
            .aliases
            .iter()
            .map(|a| a.trim().to_string())
            .filter(|a| !a.is_empty())
            .collect();
        slot.note = person.note.trim().to_string();
        self.save_people();
        true
    }

    pub fn set_person_enabled(&mut self, id: Uuid, on: bool) {
        if let Some(person) = self.people.people.iter_mut().find(|p| p.id == id) {
            person.enabled = on;
            self.save_people();
        }
    }

    pub fn delete_person(&mut self, id: Uuid) {
        self.people.people.retain(|p| p.id != id);
        self.save_people();
    }

    /// Whether a word is someone's name or one of their other spellings.
    pub fn knows(&self, token: &str) -> bool {
        let wanted = token.trim().to_lowercase();
        !wanted.is_empty()
            && self.people.people.iter().any(|person| {
                person
                    .all_spellings()
                    .iter()
                    .any(|spelling| spelling.trim().to_lowercase() == wanted)
            })
    }

    /* ── Rules ── */

    /// The dictionary comes first, so a rule written by hand wins over one
    /// derived from an alias.
    pub fn corrections(&self) -> Vec<CorrectionPair> {
        let mut out = self.dictionary.corrections.clone();
        for person in &self.people.people {
            out.extend(person.correction_rules());
        }
        out
    }

    fn dictionary_bias(&self) -> Vec<String> {
        let terms = self
            .dictionary
            .terms
            .iter()
            .filter(|t| t.enabled)
            .map(|t| t.text.as_str());
        let writes = self
            .dictionary
            .corrections
            .iter()
            .filter(|p| p.enabled)
            .map(|p| p.write.as_str());
        distinct(terms.chain(writes), DICTIONARY_BIAS_LIMIT)
    }

    fn people_bias(&self) -> Vec<String> {
        distinct(
            self.people
                .people
                .iter()
                .filter(|p| p.enabled)
                .map(|p| p.name.as_str()),
            PEOPLE_BIAS_LIMIT,
        )
    }

    /// What the recogniser is given as hints: names first, then words.
    pub fn bias(&self) -> Vec<String> {
        let people = self.people_bias();
        let dictionary = self.dictionary_bias();
        distinct(
            people.iter().chain(dictionary.iter()).map(String::as_str),
            BIAS_LIMIT,
        )
    }

    pub fn has_correction_targeting(&self, text: &str) -> bool {
        let wanted = text.trim().to_lowercase();
        !wanted.is_empty()
            && self
                .dictionary
                .corrections
                .iter()
                .any(|p| p.enabled && p.write.trim().to_lowercase() == wanted)
    }

    /// Words that rely on the hint alone, with no correction behind them.
    pub fn terms_without_corrections(&self) -> usize {
        self.dictionary
            .terms
            .iter()
            .filter(|t| t.enabled && !self.has_correction_targeting(&t.text))
            .count()
    }

    pub fn bias_overflow(&self) -> usize {
        let entries = self.dictionary.terms.iter().filter(|t| t.enabled).count()
            + self
                .dictionary
                .corrections
                .iter()
                .filter(|p| p.enabled)
                .count();
        entries.saturating_sub(BIAS_LIMIT)
    }

    /// Everything already accounted for, lowercased: words, both sides of
    /// every correction, names and their spellings, and every ruling.
    pub fn accounted_for(&self) -> HashSet<String> {
        let mut known = HashSet::new();
        for term in &self.dictionary.terms {
            known.insert(term.text.trim().to_lowercase());
        }
        for pair in &self.dictionary.corrections {
            known.insert(pair.hear.trim().to_lowercase());
            known.insert(pair.write.trim().to_lowercase());
        }
        for person in &self.people.people {
            for spelling in person.all_spellings() {
                known.insert(spelling.trim().to_lowercase());
                // A full name accounts for its parts too: "Okonkwo" alone is
                // still someone already known.
                for part in spelling.split_whitespace() {
                    known.insert(part.to_lowercase());
                }
            }
        }
        known.extend(self.ledger.keys().cloned());
        known
    }

    /* ── History ── */

    pub fn add_transcript(&mut self, transcript: Transcript) {
        self.history.retain(|t| t.id != transcript.id);
        self.history.insert(0, transcript);
        self.save_history();
    }

    pub fn update_transcript(&mut self, transcript: Transcript) -> bool {
        let Some(slot) = self.history.iter_mut().find(|t| t.id == transcript.id) else {
            return false;
        };
        *slot = transcript;
        self.save_history();
        true
    }

    /// Deletes for good, as the Mac does: no confirmation, no undo, and the
    /// copy of an unreadable history goes too.
    pub fn delete_transcripts(&mut self, ids: &[Uuid]) {
        self.history.retain(|t| !ids.contains(&t.id));
        let _ = std::fs::remove_file(self.stores.history_corrupt_path());
        self.save_history();
    }

    /// Applies one rule to every kept transcript: the text, each line, and the
    /// record of what was changed. What the recogniser actually wrote, `raw`,
    /// is never touched. Returns how many transcripts changed.
    pub fn apply_retroactively(&mut self, pair: &CorrectionPair) -> usize {
        if !pair.enabled || pair.hear.trim().is_empty() || pair.write.is_empty() {
            return 0;
        }
        let rules = std::slice::from_ref(pair);
        let mut changed = 0;
        for transcript in &mut self.history {
            let result = corrections::apply(&transcript.text, rules);
            if result.applied.is_empty() {
                continue;
            }
            transcript.text = result.text;
            transcript.corrections.extend(result.applied);
            for segment in &mut transcript.segments {
                segment.text = corrections::apply(&segment.text, rules).text;
            }
            changed += 1;
        }
        if changed > 0 {
            self.save_history();
        }
        changed
    }

    pub fn mark_analysed(&mut self, id: Uuid, findings: u32) {
        if let Some(transcript) = self.history.iter_mut().find(|t| t.id == id) {
            transcript.analyzed_at = Some(Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true));
            transcript.analysis_findings = findings;
            self.save_history();
        }
    }

    /// Transcripts the learning pass has not read, newest first.
    pub fn pending_analysis(&self) -> Vec<Uuid> {
        self.history
            .iter()
            .filter(|t| t.analyzed_at.is_none())
            .map(|t| t.id)
            .collect()
    }

    /* ── Decisions ── */

    pub fn decide(&mut self, token: &str, decision: Decision, resolved: &str) {
        self.ledger.record(token, decision, resolved);
        self.save_ledger();
    }

    pub fn restore_ignored(&mut self) -> usize {
        let restored = self.ledger.restore_ignored();
        if restored > 0 {
            self.save_ledger();
        }
        restored
    }
}

/// Trimmed, first spelling kept, case-insensitively distinct, at most `limit`.
fn distinct<'a>(values: impl Iterator<Item = &'a str>, limit: usize) -> Vec<String> {
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    for value in values {
        let text = value.trim();
        if text.is_empty() || !seen.insert(text.to_lowercase()) {
            continue;
        }
        out.push(text.to_string());
        if out.len() == limit {
            break;
        }
    }
    out
}

/// Splits what was typed under "Also heard as": commas or new lines.
pub fn split_aliases(raw: &str) -> Vec<String> {
    raw.split([',', '\n'])
        .map(str::trim)
        .filter(|piece| !piece.is_empty())
        .map(str::to_string)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::TranscriptSource;

    fn scratch() -> Library {
        let root = std::env::temp_dir().join(format!("huh-library-{}", Uuid::new_v4()));
        Library::open(Stores::new(root))
    }

    fn transcript(text: &str) -> Transcript {
        Transcript {
            analysis_findings: 0,
            analyzed_at: None,
            cleanup_removed: 0,
            corrections: Vec::new(),
            date: Utc::now(),
            duration: 1.0,
            engine: "test".into(),
            id: Uuid::new_v4(),
            raw: text.into(),
            segments: Vec::new(),
            source: TranscriptSource::Dictation,
            source_name: String::new(),
            source_path: String::new(),
            summary: String::new(),
            summary_date: None,
            text: text.into(),
        }
    }

    fn cleanup(library: &Library) {
        let _ = std::fs::remove_dir_all(&library.stores.root);
    }

    #[test]
    fn an_edit_made_elsewhere_is_read_and_the_libraries_own_writes_are_not() {
        let mut library = scratch();
        // Its own write: nothing to read again.
        library.add_term("Terraform", "");
        assert_eq!(library.reread(), Reread::default());

        // A text editor's: a term added by hand, and the file one byte longer
        // than anything this library wrote.
        let path = library.stores.dictionary_path();
        let mut file = store::load::<DictionaryFile>(&path);
        let Loaded::Read(ref mut edited) = file else {
            panic!("the dictionary should read");
        };
        edited.terms.push(VocabularyTerm {
            enabled: true,
            id: Uuid::new_v4(),
            note: "typed in by hand".into(),
            text: "Pulumi".into(),
        });
        store::write_json(&path, edited).unwrap();
        let changed = library.reread();
        assert!(changed.dictionary && !changed.people);
        assert!(library.dictionary.terms.iter().any(|t| t.text == "Pulumi"));

        // Half-written: refused, and nothing written over it until it reads.
        std::fs::write(&path, "{ \"terms\": [").unwrap();
        assert!(library.reread().dictionary);
        assert!(library.dictionary_error.is_some());
        library.add_term("Ansible", "");
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "{ \"terms\": [");
        cleanup(&library);
    }

    #[test]
    fn a_first_run_is_seeded_and_written() {
        let library = scratch();
        assert_eq!(library.dictionary.terms.len(), 5);
        assert_eq!(library.dictionary.corrections.len(), 5);
        assert!(library.stores.dictionary_path().exists());
        cleanup(&library);
    }

    #[test]
    fn a_new_correction_fixes_the_history_and_says_so() {
        let mut library = scratch();
        library.add_transcript(transcript("we shipped it to jeepity last week"));
        library.add_transcript(transcript("nothing to see here"));
        library.add_correction("jeepity", "GPT");
        assert_eq!(library.history[1].text, "we shipped it to GPT last week");
        assert_eq!(library.history[1].raw, "we shipped it to jeepity last week");
        assert_eq!(library.history[1].corrections.len(), 1);
        assert_eq!(
            library.retro_note.as_deref(),
            Some("“jeepity” → “GPT” — also fixed in 1 existing transcript.")
        );
        let rule = library
            .dictionary
            .corrections
            .iter()
            .find(|p| p.hear == "jeepity")
            .unwrap();
        assert_eq!(rule.hit_count, 1);
        cleanup(&library);
    }

    #[test]
    fn a_name_learned_with_an_alias_corrects_from_then_on() {
        let mut library = scratch();
        library.add_transcript(transcript("I spoke to Ayda about the launch"));
        library.add_person("Ada Okonkwo", Some("Ayda"), "", true);
        // The kept transcript is fixed at once…
        assert_eq!(
            library.history[0].text,
            "I spoke to Ada Okonkwo about the launch"
        );
        // …and the alias is a rule for every transcript after it.
        let fixed = corrections::apply("Ayda says hello", &library.corrections());
        assert_eq!(fixed.text, "Ada Okonkwo says hello");
        assert!(library.knows("ayda"));
        cleanup(&library);
    }

    #[test]
    fn an_alias_for_someone_unknown_adds_them_as_learned() {
        let mut library = scratch();
        assert!(library.add_alias("Leena", "Lena Vasquez"));
        let lena = library.person_named("lena vasquez").unwrap();
        assert!(lena.learned);
        assert_eq!(lena.aliases, vec!["Leena".to_string()]);
        // Adding it again changes nothing.
        assert!(library.add_alias("leena", "Lena Vasquez"));
        assert_eq!(
            library.person_named("Lena Vasquez").unwrap().aliases.len(),
            1
        );
        cleanup(&library);
    }

    #[test]
    fn an_unreadable_dictionary_is_never_overwritten() {
        let root = std::env::temp_dir().join(format!("huh-library-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(root.join("dictionary.json"), "{ not json").unwrap();
        let mut library = Library::open(Stores::new(&root));
        assert!(library
            .dictionary_error
            .as_deref()
            .unwrap()
            .starts_with("dictionary.json couldn't be read:"));
        library.add_term("Supabase", "");
        assert_eq!(
            std::fs::read_to_string(root.join("dictionary.json")).unwrap(),
            "{ not json"
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn an_unreadable_history_is_kept_aside_and_not_overwritten() {
        let root = std::env::temp_dir().join(format!("huh-library-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(root.join("history.json"), "[{ broken").unwrap();
        let mut library = Library::open(Stores::new(&root));
        assert!(library.history_error.is_some());
        assert!(root.join("history.corrupt.json").exists());
        library.add_transcript(transcript("new words"));
        assert_eq!(
            std::fs::read_to_string(root.join("history.json")).unwrap(),
            "[{ broken"
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn hints_are_names_first_and_counted_as_the_mac_counts_them() {
        let mut library = scratch();
        library.add_person("Ada Okonkwo", Some("Ayda"), "", false);
        let bias = library.bias();
        assert_eq!(bias[0], "Ada Okonkwo");
        // Seeded: five terms and five correction targets that repeat them.
        assert_eq!(bias.len(), 6);
        assert!(!bias.iter().any(|b| b == "Ayda"));
        cleanup(&library);
    }

    #[test]
    fn aliases_split_on_commas_and_lines() {
        assert_eq!(
            split_aliases("Ayda, Ada Oconquo\n ,Ade "),
            vec!["Ayda", "Ada Oconquo", "Ade"]
        );
    }
}
