//! Normalised Levenshtein distance, used to reject implausible corrections.
//!
//! A proposed correction must plausibly sound like the token it replaces. Small
//! language models supplied with a reference list will confidently map
//! unrelated tokens onto a listed term; edit distance rejects those results
//! structurally rather than relying on the model to behave.

/// Returns 0 for identical strings and 1 for strings with nothing in common.
/// Comparison is case-insensitive.
pub fn normalised(a: &str, b: &str) -> f64 {
    let lhs: Vec<char> = a.to_lowercase().chars().collect();
    let rhs: Vec<char> = b.to_lowercase().chars().collect();
    if lhs.is_empty() || rhs.is_empty() {
        return 1.0;
    }

    let mut previous: Vec<usize> = (0..=rhs.len()).collect();
    let mut current: Vec<usize> = vec![0; rhs.len() + 1];

    for i in 1..=lhs.len() {
        current[0] = i;
        for j in 1..=rhs.len() {
            let cost = usize::from(lhs[i - 1] != rhs[j - 1]);
            current[j] = (previous[j] + 1)
                .min(current[j - 1] + 1)
                .min(previous[j - 1] + cost);
        }
        std::mem::swap(&mut previous, &mut current);
    }

    previous[rhs.len()] as f64 / lhs.len().max(rhs.len()) as f64
}

/// Maximum normalised distance for a correction to be considered plausible.
/// Calibrated against real recogniser output: genuine mis-transcriptions of a
/// term score below 0.35, while unrelated substitutions score above 0.7.
pub const PLAUSIBILITY_THRESHOLD: f64 = 0.5;

pub fn is_plausible_correction(heard: &str, write: &str) -> bool {
    normalised(heard, write) <= PLAUSIBILITY_THRESHOLD
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identical_is_zero() {
        assert_eq!(normalised("terraform", "Terraform"), 0.0);
    }

    #[test]
    fn unrelated_is_far() {
        assert!(normalised("kubernetes", "banana") > 0.7);
    }

    #[test]
    fn a_mishearing_is_plausible() {
        assert!(is_plausible_correction("terra form", "Terraform"));
    }

    #[test]
    fn an_unrelated_word_is_not() {
        assert!(!is_plausible_correction("meeting", "Terraform"));
    }
}
