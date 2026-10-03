//! Whether a correction is safe to add, said before it is added.
//!
//! The Mac's `CorrectionSafety`, check for check and word for word. A
//! correction rewrites every whole-word match in every transcript from then
//! on, and in every existing one at the moment it is added, so a trigger that
//! also matches everyday English would quietly vandalise the history. The
//! check runs the trigger's real pattern against a corpus of common words
//! and the names of things people dictate about, and says which it would hit.
use serde::{Deserialize, Serialize};

use crate::corrections;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Severity {
    Caution,
    Danger,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Warning {
    pub message: String,
    pub severity: Severity,
}

impl Warning {
    fn danger(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
            severity: Severity::Danger,
        }
    }

    fn caution(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
            severity: Severity::Caution,
        }
    }
}

/// The words a trigger is checked against. Order matters: the first four
/// collisions are the ones named.
pub const CORPUS: &[&str] = &[
    "the",
    "be",
    "to",
    "of",
    "and",
    "a",
    "in",
    "that",
    "have",
    "it",
    "for",
    "not",
    "on",
    "with",
    "he",
    "as",
    "you",
    "do",
    "at",
    "this",
    "but",
    "his",
    "by",
    "from",
    "they",
    "we",
    "say",
    "her",
    "she",
    "or",
    "an",
    "will",
    "my",
    "one",
    "all",
    "would",
    "there",
    "their",
    "what",
    "so",
    "up",
    "out",
    "if",
    "about",
    "who",
    "get",
    "which",
    "go",
    "me",
    "when",
    "make",
    "can",
    "like",
    "time",
    "no",
    "just",
    "him",
    "know",
    "take",
    "people",
    "into",
    "year",
    "your",
    "good",
    "some",
    "could",
    "them",
    "see",
    "other",
    "than",
    "then",
    "now",
    "look",
    "only",
    "come",
    "its",
    "over",
    "think",
    "also",
    "back",
    "after",
    "use",
    "two",
    "how",
    "our",
    "work",
    "first",
    "well",
    "way",
    "even",
    "new",
    "want",
    "because",
    "any",
    "these",
    "give",
    "day",
    "most",
    "us",
    "read",
    "write",
    "run",
    "call",
    "send",
    "open",
    "close",
    "start",
    "stop",
    "build",
    "ship",
    "fix",
    "test",
    "check",
    "review",
    "meet",
    "meeting",
    "email",
    "note",
    "notes",
    "team",
    "project",
    "product",
    "design",
    "code",
    "data",
    "file",
    "files",
    "app",
    "apps",
    "user",
    "users",
    "client",
    "server",
    "cloud",
    "load",
    "save",
    "print",
    "sound",
    "voice",
    "text",
    "word",
    "words",
    "line",
    "page",
    "site",
    "link",
    "list",
    "board",
    "sheet",
    "doc",
    "docs",
    "plan",
    "task",
    "issue",
    "bug",
    "story",
    "sprint",
    "release",
    "branch",
    "merge",
    "commit",
    "push",
    "pull",
    "deploy",
    "log",
    "logs",
    "error",
    "warning",
    "model",
    "models",
    "token",
    "tokens",
    "prompt",
    "agent",
    "chat",
    "Cloudflare",
    "iCloud",
    "CloudKit",
    "Soundcloud",
    "Claude",
    "Clod",
    "Cloudy",
    "Google",
    "Apple",
    "Amazon",
    "Microsoft",
    "Meta",
    "OpenAI",
    "Anthropic",
    "GitHub",
    "Slack",
    "Notion",
    "Figma",
    "Linear",
    "Vercel",
    "Supabase",
    "Stripe",
    "Postgres",
    "Docker",
    "Kubernetes",
    "Swift",
    "Python",
    "Rust",
    "Node",
    "React",
    "Next",
];

/// What adding `hear → write` would do, in the order the Mac reports it.
pub fn check(hear: &str, write: &str) -> Vec<Warning> {
    let trigger = hear.trim();
    if trigger.is_empty() {
        return vec![Warning::danger("Enter the text you want corrected.")];
    }
    let target = write.trim();
    if target.is_empty() {
        return vec![Warning::danger("Enter what it should be replaced with.")];
    }

    let mut warnings = Vec::new();
    if trigger.to_lowercase() == target.to_lowercase() {
        warnings.push(Warning::caution(
            "This replaces the text with itself — it will never change anything.",
        ));
    }

    let Some(pattern) = corrections::regex(trigger) else {
        return vec![Warning::danger(
            "This can't be turned into a usable pattern.",
        )];
    };
    let collisions: Vec<&str> = CORPUS
        .iter()
        .copied()
        .filter(|word| matches_whole(&pattern, word))
        .collect();

    if !collisions.is_empty() {
        let named = collisions
            .iter()
            .take(4)
            .copied()
            .collect::<Vec<_>>()
            .join(", ");
        let more = if collisions.len() > 4 {
            format!(" and {} more", collisions.len() - 4)
        } else {
            String::new()
        };
        warnings.push(Warning::danger(format!(
            "This also matches everyday text: {named}{more}. Every one of those would be rewritten to “{target}”."
        )));
    } else if trigger.chars().count() < 4 {
        warnings.push(Warning::caution(
            "Very short triggers fire more often than you expect. Consider adding a second word.",
        ));
    } else if trigger.split_whitespace().count() == 1 {
        warnings.push(Warning::caution(format!(
            "Single-word trigger. It only fires as a whole word, so “{trigger}” inside a longer word is safe."
        )));
    }
    warnings
}

fn matches_whole(pattern: &fancy_regex::Regex, word: &str) -> bool {
    pattern
        .find(word)
        .ok()
        .flatten()
        .map(|found| found.start() == 0 && found.end() == word.len())
        .unwrap_or(false)
}

pub fn is_risky(warnings: &[Warning]) -> bool {
    warnings
        .iter()
        .any(|warning| warning.severity == Severity::Danger)
}

/// The spellings a trigger also catches, as the editor lists them: the words
/// apart, run together, and hyphenated.
pub fn catches_variants(hear: &str) -> Vec<String> {
    let words: Vec<&str> = hear
        .trim()
        .split(|c: char| c.is_whitespace() || c == '-')
        .filter(|piece| !piece.is_empty())
        .collect();
    let mut variants: Vec<String> = match words.len() {
        0 => Vec::new(),
        1 => vec![words[0].to_string()],
        _ => vec![words.join(" "), words.join(""), words.join("-")],
    };
    variants.sort();
    variants.dedup();
    variants
}

#[cfg(test)]
mod tests {
    use super::*;

    fn messages(warnings: &[Warning]) -> Vec<&str> {
        warnings.iter().map(|w| w.message.as_str()).collect()
    }

    #[test]
    fn an_empty_trigger_is_the_only_complaint() {
        assert_eq!(
            messages(&check("  ", "Supabase")),
            vec!["Enter the text you want corrected."]
        );
        assert_eq!(
            messages(&check("super base", "")),
            vec!["Enter what it should be replaced with."]
        );
    }

    #[test]
    fn a_trigger_that_is_an_everyday_word_is_dangerous() {
        let warnings = check("cloud", "Claude");
        assert!(is_risky(&warnings));
        assert!(warnings[0]
            .message
            .starts_with("This also matches everyday text: cloud."));
        assert!(warnings[0].message.ends_with("rewritten to “Claude”."));
    }

    #[test]
    fn a_whole_word_trigger_does_not_collide_inside_a_longer_word() {
        // "Cloudflare" contains "cloud", but the fences keep it whole-word.
        let warnings = check("clowd", "Claude");
        assert!(!is_risky(&warnings));
        assert_eq!(warnings[0].severity, Severity::Caution);
        assert!(warnings[0].message.starts_with("Single-word trigger."));
    }

    #[test]
    fn short_and_identity_triggers_are_cautioned() {
        let short = check("abc", "ABC Corp");
        assert!(short
            .iter()
            .any(|w| w.message.starts_with("Very short triggers")));
        let identity = check("terraform", "Terraform");
        assert!(identity
            .iter()
            .any(|w| w.message.starts_with("This replaces the text with itself")));
    }

    #[test]
    fn variants_are_apart_together_and_hyphenated() {
        assert_eq!(
            catches_variants("cuber netties"),
            vec!["cuber netties", "cuber-netties", "cubernetties"]
        );
        assert_eq!(catches_variants("versal"), vec!["versal"]);
        assert!(catches_variants("  ").is_empty());
    }
}
