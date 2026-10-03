//! A transcript in pieces small enough to read one at a time, and the words
//! around a word.
//!
//! The Mac's `TranscriptExtractor` cuts a transcript into 320-word passages so
//! a word is judged with the sentences around it, and each passage carries the
//! timecode of its first line so a suggestion can say where it came from.
use crate::model::Transcript;

/// The Mac's passage size, in words.
pub const PASSAGE_WORDS: usize = 320;

#[derive(Debug, Clone, PartialEq)]
pub struct Passage {
    pub text: String,
    /// `mm:ss` of the passage's first line, when the transcript has lines.
    pub timecode: Option<String>,
}

pub fn passages(transcript: &Transcript) -> Vec<Passage> {
    if transcript.segments.is_empty() {
        let words: Vec<&str> = transcript.text.split_whitespace().collect();
        return words
            .chunks(PASSAGE_WORDS)
            .map(|chunk| Passage {
                text: chunk.join(" "),
                timecode: None,
            })
            .collect();
    }

    let mut out = Vec::new();
    let mut current: Vec<&str> = Vec::new();
    let mut count = 0usize;
    let mut timecode: Option<String> = None;
    for segment in &transcript.segments {
        let words = segment.text.split_whitespace().count();
        if count + words > PASSAGE_WORDS && !current.is_empty() {
            out.push(Passage {
                text: current.join(" "),
                timecode: timecode.take(),
            });
            current.clear();
            count = 0;
        }
        if current.is_empty() {
            timecode = Some(segment.timecode());
        }
        current.push(segment.text.trim());
        count += words;
    }
    if !current.is_empty() {
        out.push(Passage {
            text: current.join(" "),
            timecode,
        });
    }
    out
}

/// About ninety characters either side of the first mention, with an
/// ellipsis wherever the text was cut.
pub fn excerpt(text: &str, token: &str) -> String {
    let lowered = text.to_lowercase();
    let Some(at) = lowered.find(&token.to_lowercase()) else {
        return text.chars().take(160).collect();
    };
    let chars: Vec<(usize, char)> = text.char_indices().collect();
    let start_char = chars.iter().position(|(i, _)| *i >= at).unwrap_or(0);
    let token_chars = token.chars().count();
    let from = start_char.saturating_sub(90);
    let to = (start_char + token_chars + 90).min(chars.len());
    let body: String = chars[from..to].iter().map(|(_, c)| c).collect();
    let mut out = String::new();
    if from > 0 {
        out.push('…');
    }
    out.push_str(body.trim());
    if to < chars.len() {
        out.push('…');
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{TranscriptSegment, TranscriptSource};
    use chrono::Utc;
    use uuid::Uuid;

    fn transcript(text: &str, segments: Vec<(f64, &str)>) -> Transcript {
        Transcript {
            analysis_findings: 0,
            analyzed_at: None,
            cleanup_removed: 0,
            corrections: Vec::new(),
            date: Utc::now(),
            duration: 0.0,
            engine: String::new(),
            id: Uuid::new_v4(),
            raw: text.into(),
            segments: segments
                .into_iter()
                .map(|(start, text)| TranscriptSegment {
                    id: Uuid::new_v4(),
                    start,
                    text: text.into(),
                })
                .collect(),
            source: TranscriptSource::File,
            source_name: String::new(),
            source_path: String::new(),
            summary: String::new(),
            summary_date: None,
            text: text.into(),
        }
    }

    #[test]
    fn plain_text_is_cut_every_320_words() {
        let text = vec!["word"; 700].join(" ");
        let pieces = passages(&transcript(&text, vec![]));
        assert_eq!(pieces.len(), 3);
        assert_eq!(pieces[0].text.split(' ').count(), 320);
        assert!(pieces[0].timecode.is_none());
    }

    #[test]
    fn lines_keep_the_time_of_the_first_line_in_each_passage() {
        // 318 words, so the second line's seven no longer fit in 320.
        let long = vec!["word"; 318].join(" ");
        let pieces = passages(&transcript(
            "",
            vec![
                (0.0, &long),
                (61.0, "the second line, which does not fit"),
                (75.0, "and a third"),
            ],
        ));
        assert_eq!(pieces.len(), 2);
        assert_eq!(pieces[0].timecode.as_deref(), Some("00:00"));
        assert_eq!(pieces[1].timecode.as_deref(), Some("01:01"));
        assert!(pieces[1].text.ends_with("and a third"));
    }

    #[test]
    fn an_excerpt_is_cut_around_the_word() {
        let text = format!("{} Ayda said yes {}", "a".repeat(200), "b".repeat(200));
        let quote = excerpt(&text, "ayda");
        assert!(quote.starts_with('…') && quote.ends_with('…'));
        assert!(quote.contains("Ayda said yes"));
    }
}
