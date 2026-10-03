//! The part of huh? that is not about any operating system.
//!
//! Corrections, cleanup, edit distance, the data models and the stores behind
//! them are plain logic on the Mac too. Keeping them in their own crate means
//! the port can be tested on whatever machine it is written on, and means the
//! two platforms can be held to one set of fixtures rather than two
//! implementations that agree only until someone edits one of them.
pub mod cleanup;
pub mod corrections;
pub mod distance;
pub mod ledger;
pub mod library;
pub mod model;
pub mod passages;
pub mod safety;
pub mod settings;
pub mod similar;
pub mod store;
pub mod vocabulary;

pub use cleanup::{CleanupLevel, CleanupResult};
pub use corrections::CorrectionResult;
pub use model::{
    AppliedCorrection, CorrectionPair, DictionaryFile, PeopleFile, Person, Transcript,
    TranscriptSegment, TranscriptSource, VocabularyTerm,
};

/// Trim, the way the Swift `String.trimmed` extension does it.
pub fn trimmed(value: &str) -> &str {
    value.trim()
}
