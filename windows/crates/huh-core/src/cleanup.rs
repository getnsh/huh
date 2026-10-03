//! Removes disfluency from transcribed speech.
//!
//! The criterion for removing a token is that its absence cannot change
//! meaning. Interjections such as "uh" satisfy this; "like" does not, since it
//! is both a filler and a content word, and pattern matching cannot tell the
//! two apart reliably.
//!
//! Regular expressions only: no model, no network, no measurable cost.
use fancy_regex::Regex;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum CleanupLevel {
    Off,
    #[default]
    Standard,
    Aggressive,
}

impl CleanupLevel {
    pub fn title(&self) -> &'static str {
        match self {
            Self::Off => "Off",
            Self::Standard => "Fillers & stutters",
            Self::Aggressive => "Also hedges",
        }
    }

    pub fn detail(&self) -> &'static str {
        match self {
            Self::Off => "Keep the transcript exactly as spoken.",
            Self::Standard => "Drops \u{201C}uh\u{201D}, \u{201C}um\u{201D}, \u{201C}erm\u{201D} and collapses \u{201C}yeah, yeah, yeah\u{201D} into one. Conservative \u{2014} it only removes words that carry no meaning.",
            Self::Aggressive => "Also drops hedges: \u{201C}you know\u{201D}, \u{201C}I mean\u{201D}, \u{201C}sort of\u{201D}, \u{201C}basically\u{201D}, \u{201C}actually\u{201D}. Reads tighter, but it is editing you, not just cleaning you up.",
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct CleanupResult {
    pub text: String,
    pub removed: usize,
}

impl CleanupResult {
    /// Human-readable summary for the transcript audit trail.
    pub fn summary(&self) -> String {
        if self.removed == 0 {
            "nothing removed".into()
        } else {
            format!(
                "{} filler{} removed",
                self.removed,
                if self.removed == 1 { "" } else { "s" }
            )
        }
    }
}

/// Interjections that never carry meaning as standalone words.
const FILLERS: &[&str] = &[
    "uh", "uhh", "uhm", "um", "umm", "erm", "er", "ah", "hmm", "mmm", "mhm",
];

/// Discourse markers that are commonly repeated. A doubled discourse marker is
/// a verbal tic, whereas a doubled content word may be grammatical ("that had
/// had errors"), which is why this is an explicit list rather than a general
/// rule.
const STUTTER_PRONE: &[&str] = &[
    "yeah", "yes", "no", "okay", "ok", "right", "so", "well", "sure", "exactly", "true", "nope",
    "hey", "wait",
];

/// Hedges. Removing these edits meaning slightly, so it is opt-in.
const HEDGES: &[&str] = &[
    "you know",
    "i mean",
    "sort of",
    "kind of",
    "kinda",
    "sorta",
    "basically",
    "actually",
    "literally",
    "obviously",
    "essentially",
];

pub fn apply(text: &str, level: CleanupLevel) -> CleanupResult {
    if level == CleanupLevel::Off || text.is_empty() {
        return CleanupResult {
            text: text.to_string(),
            removed: 0,
        };
    }

    let mut working = text.to_string();
    let mut removed = 0usize;

    // 1. Standalone fillers, with any punctuation clinging to them.
    let filler = format!(
        "(?i)(?<![\\p{{L}}\\p{{N}}'\\-])(?:{})(?![\\p{{L}}\\p{{N}}'\\-])[\\s,]*",
        FILLERS.join("|")
    );
    removed += replace(&mut working, &filler, "");

    if level == CleanupLevel::Aggressive {
        let hedge = format!(
            "(?i)(?<![\\p{{L}}\\p{{N}}'\\-])(?:{})(?![\\p{{L}}\\p{{N}}'\\-])[\\s,]*",
            HEDGES
                .iter()
                .map(|h| h.replace(' ', "\\s+"))
                .collect::<Vec<_>>()
                .join("|")
        );
        removed += replace(&mut working, &hedge, "");
    }

    // 2. Doubled discourse words: "yeah, yeah, yeah" -> "yeah".
    let stutter = format!(
        "(?i)(?<![\\p{{L}}\\p{{N}}'\\-])({})((?:[,\\s]+\\1)+)(?![\\p{{L}}\\p{{N}}'\\-])",
        STUTTER_PRONE.join("|")
    );
    removed += replace(&mut working, &stutter, "$1");

    // 3. Any word repeated three or more times -- a stumble in any vocabulary.
    removed += replace(
        &mut working,
        "(?i)(?<![\\p{L}\\p{N}'\\-])(\\p{L}+)((?:[,\\s]+\\1){2,})(?![\\p{L}\\p{N}'\\-])",
        "$1",
    );

    // 4. Normalise punctuation and whitespace left behind by removals.
    replace(&mut working, "\\s+([,.!?;:])", "$1");
    replace(&mut working, "([,;:])\\s*([,.!?;:])", "$2");
    replace(&mut working, "([.!?])\\s*,", "$1");
    replace(&mut working, "[ \\t]{2,}", " ");
    replace(&mut working, "(?m)^[\\s,]+", "");

    // 5. Restore sentence capitalisation where a removal exposed a new start.
    working = capitalise_sentences(&working);

    CleanupResult {
        text: working.trim().to_string(),
        removed,
    }
}

fn replace(text: &mut String, pattern: &str, template: &str) -> usize {
    let Ok(re) = Regex::new(pattern) else {
        return 0;
    };
    let count = re.find_iter(text).flatten().count();
    if count == 0 {
        return 0;
    }
    *text = re.replace_all(text, template).into_owned();
    count
}

fn capitalise_sentences(text: &str) -> String {
    let Ok(re) = Regex::new("(^|[.!?]\\s+)(\\p{Ll})") else {
        return text.to_string();
    };
    let mut out = text.to_string();
    let spans: Vec<(usize, usize)> = re
        .captures_iter(text)
        .flatten()
        .filter_map(|caps| caps.get(2).map(|m| (m.start(), m.end())))
        .collect();
    for (start, end) in spans.into_iter().rev() {
        let upper = out[start..end].to_uppercase();
        out.replace_range(start..end, &upper);
    }
    out
}
