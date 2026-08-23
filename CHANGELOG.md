# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0] — Unreleased

### Added

- **People store.** Names are held in `people.json`, separately from vocabulary
  terms and correction rules, because a name settles once and should not be
  revised by a later pass. Each name biases the recogniser; each recorded alias
  becomes a rewrite rule, applied retroactively to existing transcripts.
- **Decision ledger.** Every outcome of the review queue — accepted as a term,
  filed as a person, added as a correction, or rejected — is recorded in
  `decisions.json` and consulted before anything is surfaced. The same word is
  never proposed twice.
- **Ask about a transcript.** A conversation beneath the summary, answered from
  the recording alone. Each question retrieves the passages that bear on it by
  inverse document frequency and sends only those. Answers cite the timecodes
  they drew on; a question the recording cannot answer is refused in plain terms
  rather than guessed at.
- `TokenBudget`, which makes the on-device model's 4,096-token context window
  explicit. Prompts are sized before they are sent rather than after they fail.
- `verify-extraction.sh`, covering model reply parsing, validation, collapse
  detection, observation consolidation and token budgeting.
- Microphone presence is detected at launch and reported in the window, the menu
  bar and Settings.

### Changed

- **Transcripts are now read in full.** The analysis pass divides a transcript
  into passages and sends the model each passage together with the unrecognised
  words found in it, instead of sending a list of tokens with one sentence of
  context each. Previously only the first twelve tokens of a recording were ever
  examined, and the model was asked to identify words with almost nothing to go
  on. Passages containing nothing unrecognised are skipped without a request.
- **Summaries are produced in three stages** — labelled observations per chunk,
  duplicate removal in code, then a single write-up with participants, decisions,
  owners and open questions. The previous map-reduce asked a small model to
  summarise prose and then summarise its own summaries, which read well and lost
  content at every step. Participants are assembled from the transcript rather
  than generated.
- Reply parsing and validation moved to `ModelReply`, which is pure and testable
  without a model present.
- A manual rescan now reads unread transcripts instead of clearing every
  transcript's analysis mark, which had the effect of re-asking every question
  that had already been answered.

### Fixed

- Asking a transcript a question refused outright whenever no passage matched
  the question word-for-word, which is most of the time: "What was decided?"
  never matched, because meetings contain "let us go with" and "that works", not
  "decided". Retrieval now expands a question into related terms, and a miss
  falls back to a spread of the recording rather than a refusal — the model is
  already instructed to admit when the excerpts fall short, so the worst case is
  the same answer reached honestly.
- Settings was pinned to a fixed height, so every group added after it was
  written — Microphone included — was clipped off the bottom with nothing to
  indicate content was missing. It scrolls now.
- Dictation failed with "No audio input device is available" only at the moment
  the push-to-talk key was pressed, on machines with no microphone — which is
  most desktop Macs. The absence is now detected up front and explained where the
  user is looking.
- Changing the engine or the language rebuilt the transcription engine twice, and
  rebuilt it even when the resulting configuration was identical — each rebuild
  re-entering model loading. Engine configuration is now compared as a whole and
  preparation is single-flight.
- Transcripts left unread because Apple Intelligence was unavailable were marked
  as read regardless, so they were never examined once it became available.

## [0.2.0] — Unreleased

### Added

- Parakeet TDT engine via FluidAudio, running on the Neural Engine, with
  word-level timings suitable for speaker attribution. Models are downloaded
  once on first use with progress reported throughout.

### Fixed

- The engine picker offered engines the build could not run, which silently
  disabled dictation. Unavailable engines are now excluded from selection, and a
  persisted selection this build cannot honour resets to a working engine.
- First-run speech model download reported no progress and was indistinguishable
  from a hang. Download progress is now surfaced.
- A developer-facing instruction ("uncomment the dependency in Package.swift")
  was reachable as a user-visible error string.

### Changed

- The privacy claim is now accurate rather than absolute: the application makes
  no network requests except the optional Parakeet model download, which
  transmits no user content.

## [0.1.0] — Unreleased

First packaged release.

### Added

- Push-to-talk dictation with a configurable modifier key, hold or toggle
  activation, and on-device transcription via `SpeechAnalyzer`.
- Text insertion through the Accessibility API with a pasteboard fallback, and
  confirmation of the destination used.
- Transcription of audio and video files at approximately 40× realtime, with
  timestamped segments and playback synchronised to the timeline.
- A dictionary with two entry types: vocabulary terms supplied to the recogniser
  as bias, and correction rules applied deterministically after transcription.
- Safety validation for correction rules, evaluated against a corpus of common
  words and proper nouns before a rule can be saved.
- Retroactive application of new corrections to existing transcripts.
- Automatic per-transcript analysis that identifies unrecognised vocabulary and
  proposes corrections using the on-device language model.
- Meeting summaries via chunked map-reduce over `SystemLanguageModel`.
- Full-text search across all transcripts using an inverted index.
- Disfluency cleanup with three levels.
- Export to plain text, Markdown, SubRip and WebVTT; rich-text clipboard export
  for pasting into Google Docs.
- Login item registration via `SMAppService`.
- Graceful degradation when the on-device language model is unavailable:
  model-backed controls remain available, state what is required, and link to
  the Apple Intelligence settings pane. Availability is re-evaluated whenever
  the application becomes active.

### Security

- Builds are signed with the Hardened Runtime and a single entitlement.
- No network access. All inference is on-device.
