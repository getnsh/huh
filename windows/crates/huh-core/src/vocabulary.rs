//! Finding the words worth teaching it: spellings no dictionary knows, and
//! words that look like someone's name.
//!
//! The Mac's `VocabularySuggester`, deterministic and model-free. The two
//! platform services it leans on -- a spell checker, and something that can
//! tell a name in running text -- are traits here, so the logic tests on any
//! machine and each platform brings its own. On Windows the spell checker is
//! the system's; the names come from `CapitalisedNames` below, because
//! Windows has no counterpart to the Mac's name tagger.
use std::collections::{HashMap, HashSet};

use serde::Serialize;

use crate::ledger::Ledger;

pub trait SpellCheck {
    /// Whether the word would be underlined.
    fn is_misspelled(&self, word: &str) -> bool;
}

pub trait NameTagger {
    /// The personal names in a passage, a multi-word name as one span.
    fn personal_names(&self, text: &str) -> Vec<String>;
}

/// No spell checker: nothing is ever misspelled, so only names are found.
pub struct NoSpellCheck;

impl SpellCheck for NoSpellCheck {
    fn is_misspelled(&self, _word: &str) -> bool {
        false
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Candidate {
    /// The first spelling seen.
    pub word: String,
    pub count: u32,
    pub is_name: bool,
}

/// What a scan found, and how many it held back because they were dismissed.
#[derive(Debug, Clone, Default)]
pub struct Found {
    pub candidates: Vec<Candidate>,
    pub suppressed: u32,
}

/// Graphemes are approximated by chars: close enough for 3–24 letter words.
fn length(word: &str) -> usize {
    word.chars().count()
}

fn starts_with_letter(word: &str) -> bool {
    word.chars()
        .next()
        .map(char::is_alphabetic)
        .unwrap_or(false)
}

/// The Mac's tokeniser: split on anything that is not a letter, an ASCII
/// apostrophe or a hyphen (a typographic apostrophe splits), trim apostrophes
/// and hyphens from the ends, and keep 3–24 character words that start with a
/// letter.
pub fn tokens(text: &str) -> impl Iterator<Item = &str> {
    text.split(|c: char| !(c.is_alphabetic() || c == '\'' || c == '-'))
        .map(|piece| piece.trim_matches(|c| c == '\'' || c == '-'))
        .filter(|piece| (3..=24).contains(&length(piece)) && starts_with_letter(piece))
}

/// Counts words across `texts` and returns the unknown ones a person should
/// see: misspelled words heard at least `threshold` times, and anything that
/// looks like a name, however rarely. Names first, then the most frequent.
pub fn scan(
    texts: &[&str],
    threshold: u32,
    known: &HashSet<String>,
    ledger: &Ledger,
    spell: &dyn SpellCheck,
    names: &dyn NameTagger,
) -> Found {
    let mut counts: HashMap<String, (String, u32)> = HashMap::new();
    for text in texts {
        for token in tokens(text) {
            let entry = counts
                .entry(token.to_lowercase())
                .or_insert_with(|| (token.to_string(), 0));
            entry.1 += 1;
        }
    }

    let mut misspelled_cache: HashMap<String, bool> = HashMap::new();
    let mut misspelled = |key: &str, display: &str| -> bool {
        *misspelled_cache
            .entry(key.to_string())
            .or_insert_with(|| spell.is_misspelled(display))
    };

    let mut found: HashMap<String, Candidate> = HashMap::new();
    let mut suppressed = 0u32;
    for (key, (display, count)) in &counts {
        if *count < threshold {
            continue;
        }
        if ledger.is_ignored(key) {
            if misspelled(key, display) {
                suppressed += 1;
            }
            continue;
        }
        if known.contains(key) {
            continue;
        }
        if misspelled(key, display) {
            found.insert(
                key.clone(),
                Candidate {
                    word: display.clone(),
                    count: *count,
                    is_name: false,
                },
            );
        }
    }

    let mut name_counts: HashMap<String, (String, u32)> = HashMap::new();
    for text in texts {
        for span in names.personal_names(text) {
            let span = span.trim_matches(|c| c == '\'' || c == '-').to_string();
            if !(3..=24).contains(&length(&span)) || !starts_with_letter(&span) {
                continue;
            }
            let key = span.to_lowercase();
            if known.contains(&key) || ledger.is_decided(&key) {
                continue;
            }
            let entry = name_counts.entry(key).or_insert_with(|| (span.clone(), 0));
            entry.1 += 1;
        }
    }
    for (key, (display, count)) in name_counts {
        match found.get_mut(&key) {
            Some(candidate) => candidate.is_name = true,
            None => {
                found.insert(
                    key,
                    Candidate {
                        word: display,
                        count,
                        is_name: true,
                    },
                );
            }
        }
    }

    let mut candidates: Vec<Candidate> = found.into_values().collect();
    candidates.sort_by(|a, b| {
        b.is_name
            .cmp(&a.is_name)
            .then(b.count.cmp(&a.count))
            .then(a.word.cmp(&b.word))
    });
    Found {
        candidates,
        suppressed,
    }
}

/// Names in running text, told by their capitals.
///
/// Parakeet capitalises proper nouns, which gives a name away: a capitalised
/// word in the middle of a sentence that is not an ordinary word written with
/// a capital. Neighbouring capitalised words join into one name, up to three.
/// A word at the start of a sentence is only taken as part of a longer name,
/// because every sentence starts with a capital. Excluded: words the spell
/// checker accepts in lower case (so "Will" and "Mark" are lost, and "Monday"
/// and "Thursday" are not mistaken for people), the days and months, "I", and
/// acronyms written in capitals throughout.
pub struct CapitalisedNames<'a> {
    pub spell: &'a dyn SpellCheck,
}

const NOT_NAMES: &[&str] = &[
    "i",
    "i'm",
    "i've",
    "i'll",
    "i'd",
    "ok",
    "okay",
    "monday",
    "tuesday",
    "wednesday",
    "thursday",
    "friday",
    "saturday",
    "sunday",
    "january",
    "february",
    "march",
    "april",
    "may",
    "june",
    "july",
    "august",
    "september",
    "october",
    "november",
    "december",
    "mr",
    "mrs",
    "ms",
    "dr",
    "english",
    "american",
    "british",
    "european",
    "christmas",
    "easter",
];

/// Closes a run of capitalised words: kept as a name unless it is one word
/// that only had its capital because it opened a sentence.
fn flush(run: &mut Vec<(&str, bool)>, names: &mut Vec<String>) {
    let lone_opener = run.len() == 1 && run[0].1;
    if !run.is_empty() && !lone_opener {
        let span: Vec<&str> = run.iter().take(3).map(|(word, _)| *word).collect();
        names.push(span.join(" "));
    }
    run.clear();
}

impl NameTagger for CapitalisedNames<'_> {
    fn personal_names(&self, text: &str) -> Vec<String> {
        let mut names = Vec::new();
        let mut run: Vec<(&str, bool)> = Vec::new();
        let mut sentence_start = true;

        for raw in text.split_whitespace() {
            let opens = sentence_start;
            let word = raw.trim_matches(|c: char| !c.is_alphanumeric() && c != '\'' && c != '-');
            let ends_sentence = raw.ends_with(['.', '!', '?']) || raw.ends_with(".\"");
            let breaks_run = ends_sentence || raw.ends_with([',', ';', ':']);
            sentence_start = ends_sentence;

            if self.looks_like_a_name(word) {
                run.push((word, opens && run.is_empty()));
                if breaks_run {
                    flush(&mut run, &mut names);
                }
            } else {
                flush(&mut run, &mut names);
            }
        }
        flush(&mut run, &mut names);
        names
    }
}

impl CapitalisedNames<'_> {
    fn looks_like_a_name(&self, word: &str) -> bool {
        let mut chars = word.chars();
        let Some(first) = chars.next() else {
            return false;
        };
        if !first.is_uppercase() || word.chars().count() < 2 {
            return false;
        }
        // "API", "NASA": an acronym, not a person.
        if word
            .chars()
            .filter(|c| c.is_alphabetic())
            .all(char::is_uppercase)
        {
            return false;
        }
        let lowered = word.to_lowercase();
        if NOT_NAMES.contains(&lowered.as_str()) {
            return false;
        }
        // An ordinary word that happens to be capitalised is not a name.
        self.spell.is_misspelled(&lowered)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A tiny English: these words are spelled right in lower case.
    struct Tiny;
    impl SpellCheck for Tiny {
        fn is_misspelled(&self, word: &str) -> bool {
            const KNOWN: &[&str] = &[
                "we", "the", "to", "spoke", "about", "launch", "and", "on", "will", "send",
                "notes", "with", "met", "it", "deploy", "today", "standup", "moved", "mark",
                "this", "that", "is", "ship", "config",
            ];
            !KNOWN.contains(&word.to_lowercase().as_str())
        }
    }

    #[test]
    fn the_tokeniser_keeps_words_and_their_inner_apostrophes() {
        let found: Vec<&str> = tokens("Don't ship -- it's 'quoted', a an x-ray, ok").collect();
        assert_eq!(found, vec!["Don't", "ship", "it's", "quoted", "x-ray"]);
    }

    #[test]
    fn names_are_told_by_their_capitals_but_not_at_a_sentence_start() {
        let tagger = CapitalisedNames { spell: &Tiny };
        let names = tagger.personal_names(
            "We spoke to Priya about the launch. Mark will send notes to Ada Okonkwo on Thursday.",
        );
        assert_eq!(names, vec!["Priya", "Ada Okonkwo"]);
    }

    #[test]
    fn a_two_word_name_counts_even_at_the_start() {
        let tagger = CapitalisedNames { spell: &Tiny };
        assert_eq!(
            tagger.personal_names("Lena Vasquez met with it."),
            vec!["Lena Vasquez"]
        );
        assert!(tagger.personal_names("Priya met with it.").is_empty());
    }

    #[test]
    fn a_scan_ranks_names_first_and_respects_what_is_known() {
        let tagger = CapitalisedNames { spell: &Tiny };
        let mut known = HashSet::new();
        known.insert("vercel".to_string());
        let mut ledger = Ledger::default();
        ledger.record("kubectl", crate::ledger::Decision::Ignored, "");
        let texts = [
            "deploy the cuberconfig to versel today with Priya",
            "deploy the cuberconfig to vercel and kubectl and kubectl",
            "Priya moved the standup",
        ];
        let found = scan(&texts, 2, &known, &ledger, &Tiny, &tagger);
        let words: Vec<(&str, u32, bool)> = found
            .candidates
            .iter()
            .map(|c| (c.word.as_str(), c.count, c.is_name))
            .collect();
        assert_eq!(words, vec![("Priya", 2, true), ("cuberconfig", 2, false)]);
        // "kubectl" was dismissed: held back, and counted as held back.
        assert_eq!(found.suppressed, 1);
    }
}
