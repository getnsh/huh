//! What a misheard word was probably meant to be, worked out from what is
//! already known rather than by a model.
//!
//! On the Mac a language model reads each passage and guesses. Windows has no
//! on-device model to ask, so these answer the narrower question that needs
//! none: does this sound like a name, a word or a product the dictionary and
//! the people list already hold? A recogniser's mistakes are mostly the same
//! few names and terms heard slightly differently each time, which is exactly
//! the case this catches.
use crate::distance;
use crate::vocabulary::SpellCheck;

/// The spelling with letters that sound alike folded together, so "Oconquo"
/// and "Okonkwo", "Ayda" and "Aida", "Leena" and "Lena" compare as the same.
fn fold(word: &str) -> String {
    let lower: String = word
        .to_lowercase()
        .chars()
        .filter(|c| c.is_alphabetic())
        .collect();
    let replaced = lower
        .replace("qu", "kw")
        .replace("ph", "f")
        .replace("ck", "k");
    let mapped: String = replaced
        .chars()
        .map(|c| match c {
            'c' | 'q' => 'k',
            'z' => 's',
            'y' => 'i',
            other => other,
        })
        .collect();
    // Doubled letters are a spelling choice, not a sound.
    let mut out = String::with_capacity(mapped.len());
    for c in mapped.chars() {
        if !out.ends_with(c) {
            out.push(c);
        }
    }
    out
}

/// 0 for the same, 1 for nothing in common: the closer of the plain and the
/// sound-alike comparisons.
pub fn closeness(heard: &str, known: &str) -> f64 {
    distance::normalised(heard, known).min(distance::normalised(&fold(heard), &fold(known)))
}

/// How close is close enough. Short words get a stricter bar: two four-letter
/// names a letter apart are usually two different people.
fn acceptable(heard: &str, known: &str, score: f64) -> bool {
    let shorter = heard.chars().count().min(known.chars().count());
    let bar = if shorter <= 4 {
        0.26
    } else {
        distance::PLAUSIBILITY_THRESHOLD
    };
    score <= bar
}

/// Known spellings `heard` might be, closest first. A single word can match
/// one part of a full name, "Ayda" for "Ada Okonkwo", and the full name is
/// what is offered.
pub fn alternatives(heard: &str, known: &[String], limit: usize) -> Vec<String> {
    let heard = heard.trim();
    let single = heard.split_whitespace().count() == 1;
    let mut scored: Vec<(f64, &String)> = known
        .iter()
        .filter(|k| k.trim().to_lowercase() != heard.to_lowercase())
        .filter_map(|k| {
            let mut best = (closeness(heard, k), k.as_str());
            if single {
                for part in k.split_whitespace() {
                    let score = closeness(heard, part);
                    if score < best.0 {
                        best = (score, part);
                    }
                }
            }
            acceptable(heard, best.1, best.0).then_some((best.0, k))
        })
        .collect();
    scored.sort_by(|a, b| a.0.total_cmp(&b.0).then(a.1.cmp(b.1)));
    let mut out: Vec<String> = Vec::new();
    for (_, k) in scored {
        if !out.iter().any(|o| o.eq_ignore_ascii_case(k)) {
            out.push(k.clone());
        }
        if out.len() == limit {
            break;
        }
    }
    out
}

/// A span of the text that sounds like something known but is not it.
#[derive(Debug, Clone, PartialEq)]
pub struct NearMiss {
    /// The words as they appear in the text.
    pub heard: String,
    /// The known spelling it sounds like.
    pub known: String,
    pub score: f64,
}

/// Spans of one to three words that, run together, sound like a known term
/// -- "cuber netties" for "Kubernetes", "versal" for "Vercel".
///
/// Only spans with a misspelled word in them are considered. A recogniser that
/// mishears a name writes letters, not a dictionary word; a span of real
/// English that happens to be near a term ("vessel", for "Vercel") is left
/// alone, because rewriting it would vandalise the sentence.
pub fn near_misses(text: &str, known: &[String], spell: &dyn SpellCheck) -> Vec<NearMiss> {
    let words: Vec<&str> = text
        .split_whitespace()
        .map(|w| w.trim_matches(|c: char| !c.is_alphanumeric() && c != '\'' && c != '-'))
        .collect();
    let targets: Vec<(&String, String)> = known
        .iter()
        .map(|k| (k, k.split_whitespace().collect::<String>().to_lowercase()))
        .filter(|(_, joined)| joined.chars().count() >= 5)
        .collect();

    let mut misses: Vec<NearMiss> = Vec::new();
    for start in 0..words.len() {
        for span_len in 1..=3usize {
            let end = start + span_len;
            if end > words.len() {
                break;
            }
            let span = &words[start..end];
            if span.iter().any(|w| w.is_empty()) {
                break;
            }
            if !span.iter().any(|w| spell.is_misspelled(w)) {
                continue;
            }
            let joined: String = span.concat().to_lowercase();
            let heard = span.join(" ");
            for (known_spelling, target) in &targets {
                if joined == *target || heard.eq_ignore_ascii_case(known_spelling) {
                    continue;
                }
                let ratio = joined.chars().count() as f64 / target.chars().count() as f64;
                if !(0.75..=1.34).contains(&ratio) {
                    continue;
                }
                let score = closeness(&joined, target);
                if score <= 0.34 {
                    misses.push(NearMiss {
                        heard: heard.clone(),
                        known: (*known_spelling).clone(),
                        score,
                    });
                }
            }
        }
    }
    // One answer per span, the best one, and no span inside a better one.
    misses.sort_by(|a, b| a.score.total_cmp(&b.score));
    let mut kept: Vec<NearMiss> = Vec::new();
    for miss in misses {
        let lowered = miss.heard.to_lowercase();
        let overlaps = kept.iter().any(|k| {
            let other = k.heard.to_lowercase();
            other.contains(&lowered) || lowered.contains(&other)
        });
        if !overlaps {
            kept.push(miss);
        }
    }
    kept
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Tiny;
    impl SpellCheck for Tiny {
        fn is_misspelled(&self, word: &str) -> bool {
            const KNOWN: &[&str] = &[
                "we", "the", "to", "deploy", "config", "vessel", "a", "big", "on", "it", "moved",
                "cuber", "sailed",
            ];
            !KNOWN.contains(&word.to_lowercase().as_str())
        }
    }

    fn known(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn a_misheard_first_name_finds_the_full_name() {
        let people = known(&["Ada Okonkwo", "Lena Vasquez", "Priya Raman"]);
        assert_eq!(alternatives("Ayda", &people, 3), vec!["Ada Okonkwo"]);
        assert_eq!(alternatives("Oconquo", &people, 3), vec!["Ada Okonkwo"]);
        assert_eq!(alternatives("Leena", &people, 3), vec!["Lena Vasquez"]);
    }

    #[test]
    fn a_stranger_has_no_alternatives() {
        let people = known(&["Ada Okonkwo", "Lena Vasquez"]);
        assert!(alternatives("Marguerite", &people, 3).is_empty());
        // Close, but short words need to be closer than this.
        assert!(alternatives("Ana", &known(&["Ada"]), 3).is_empty());
    }

    #[test]
    fn a_term_heard_as_two_words_is_found() {
        let terms = known(&["Kubernetes", "Vercel"]);
        let misses = near_misses("we deploy the config to cuber netties today", &terms, &Tiny);
        assert_eq!(misses.len(), 1);
        assert_eq!(misses[0].heard, "cuber netties");
        assert_eq!(misses[0].known, "Kubernetes");
    }

    #[test]
    fn real_english_near_a_term_is_left_alone() {
        let terms = known(&["Vercel"]);
        assert!(near_misses("a big vessel sailed", &terms, &Tiny).is_empty());
        let misses = near_misses("deploy it on versal", &terms, &Tiny);
        assert_eq!(misses[0].heard, "versal");
    }
}
