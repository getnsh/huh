//! Applies dictionary corrections to a completed transcript.
//!
//! A line-for-line port of the Mac's `CorrectionEngine`, with the same four
//! properties and the same failure each one prevents:
//!
//!  * **Whole-word matching.** A multi-word trigger must never match inside a
//!    longer word. Patterns are fenced with lookarounds rejecting an adjacent
//!    letter, digit, hyphen or apostrophe. A word boundary is insufficient
//!    because it treats a hyphen as a boundary, which would allow a match
//!    inside a hyphenated compound.
//!
//!  * **Separator tolerance.** Recognisers emit the same utterance with and
//!    without separators. Any run of whitespace, hyphens or underscores --
//!    including none -- is accepted between the words of a trigger.
//!
//!  * **Longest trigger wins.** A more specific trigger takes precedence over
//!    a prefix of itself.
//!
//!  * **Single non-overlapping pass.** Matches are collected against the
//!    original text and applied in reverse order. Applying rules sequentially
//!    would let one rule's output be consumed by another.
//!
//! `fancy-regex` rather than `regex`, because the fences are lookarounds and
//! `regex` has none. The pattern is then character-for-character the Swift one,
//! which is the point: two engines reading one pattern cannot disagree about
//! what it means.
use crate::model::{AppliedCorrection, CorrectionPair};
use fancy_regex::Regex;
use serde::{Deserialize, Serialize};

/// Serialisable because the dictionary editor previews a rule before it is
/// saved, and the preview is computed in the core rather than reimplemented in
/// the interface.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CorrectionResult {
    pub text: String,
    pub applied: Vec<AppliedCorrection>,
}

/// Builds the pattern for a trigger phrase. Returns `None` if unusable.
pub fn pattern(hear: &str) -> Option<String> {
    let words: Vec<String> = hear
        .split(|c: char| c.is_whitespace() || c == '-' || c == '_')
        .filter(|w| !w.is_empty())
        .map(fancy_regex::escape)
        .map(|w| w.into_owned())
        .collect();
    if words.is_empty() {
        return None;
    }
    let core = words.join("[\\s\\-_]*");
    // Reject an adjacent letter, digit, hyphen or apostrophe. Hyphens matter
    // in both directions: a hyphen *within* the trigger is accepted as a
    // separator, while one immediately before or after the match indicates a
    // different compound word.
    Some(format!(
        "(?<![\\p{{L}}\\p{{N}}'\\-]){core}(?![\\p{{L}}\\p{{N}}'\\-])"
    ))
}

pub fn regex(hear: &str) -> Option<Regex> {
    let pattern = pattern(hear)?;
    Regex::new(&format!("(?i){pattern}")).ok()
}

pub fn apply(text: &str, corrections: &[CorrectionPair]) -> CorrectionResult {
    if text.is_empty() {
        return CorrectionResult {
            text: text.to_string(),
            applied: Vec::new(),
        };
    }

    let mut active: Vec<&CorrectionPair> = corrections
        .iter()
        .filter(|pair| pair.enabled && !pair.hear.trim().is_empty() && !pair.write.is_empty())
        .collect();
    // Longest trigger wins. Swift compares `String.count`, which is characters.
    active.sort_by_key(|pair| std::cmp::Reverse(pair.hear.chars().count()));

    struct Hit<'a> {
        start: usize,
        end: usize,
        pair: &'a CorrectionPair,
        matched: String,
    }

    let mut hits: Vec<Hit> = Vec::new();
    let mut claimed: Vec<(usize, usize)> = Vec::new();

    for pair in active {
        let Some(re) = regex(&pair.hear) else {
            continue;
        };
        for found in re.find_iter(text).flatten() {
            let (start, end) = (found.start(), found.end());
            // Skip ranges already claimed by a longer trigger.
            if claimed.iter().any(|(s, e)| start < *e && *s < end) {
                continue;
            }
            claimed.push((start, end));
            hits.push(Hit {
                start,
                end,
                pair,
                matched: text[start..end].to_string(),
            });
        }
    }

    if hits.is_empty() {
        return CorrectionResult {
            text: text.to_string(),
            applied: Vec::new(),
        };
    }

    // Apply in reverse so earlier ranges stay valid.
    hits.sort_by_key(|hit| hit.start);
    let mut out = text.to_string();
    for hit in hits.iter().rev() {
        out.replace_range(hit.start..hit.end, &hit.pair.write);
    }

    let applied = hits
        .iter()
        .map(|hit| AppliedCorrection {
            hear: hit.pair.hear.clone(),
            id: uuid::Uuid::new_v4(),
            matched: hit.matched.clone(),
            write: hit.pair.write.clone(),
        })
        .collect();

    CorrectionResult { text: out, applied }
}
