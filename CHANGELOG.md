# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.4.2] — 2026-10-02

### Changed

- The session panel and the collapsed mark no longer carry a coloured border
  or glow, and the waveform is drawn in a flat tint rather than a gradient.
  The accent stays where it means something: the centre bar of the mark, and
  the rail beside a line of transcript.

## [0.4.1] — 2026-10-02

### Fixed

- **The live waveform was a row of fat dots that barely moved.** Bar width was
  derived by dividing the available width across a fixed number of bars, and
  the resting height of a bar was its own width -- so a wide trace produced
  bars as wide as the trace was tall, which cannot be a thin line at rest and
  has almost nowhere to travel when someone speaks. The pitch is fixed now and
  as many bars as fit are drawn, with a resting height that has nothing to do
  with how wide they are. The history is interpolated across however many bars
  there is room for rather than repeated, so the trace moves smoothly instead
  of in steps, and the upper range is compressed less, so loud and quiet no
  longer look alike.

## [0.4.0] — 2026-10-02

It can hear your Mac now, not just you. Hold the key over a video and the video
is transcribed; leave it running through a call and both sides are, each into
its own recogniser so every line knows who said it.

### Added

- **System audio capture.** *Your Mac as well as you* in Settings, off by
  default, makes the push-to-talk key capture the microphone and whatever the
  machine is playing, summed into one stream. Built on a Core Audio process tap
  rather than ScreenCaptureKit, so the permission it asks for is audio
  recording and not the ability to watch your screen. Playback is never muted.
- **Live sessions.** Start one from the window, the menu bar or ⇧⌘M and leave
  it running. You and the room go to separate recognisers, so the transcript
  keeps the two apart, and the session lands in the library when you stop it,
  ready to summarise.
- **A panel that stays out of the way.** While a session runs it sits at the
  edge of the screen as the product mark, moving to whoever is speaking and
  tinted for which of you it is. Click it to open the whole session: both
  waveforms, the transcript arriving as it is spoken, and the time. Drag it
  anywhere, and it stays there.
- **It notices when a call starts.** Core Audio knows which processes have the
  microphone open, and a call is exactly that: another application listening.
  One fact catches Google Meet or anything else in a browser tab, Slack
  huddles, Zoom, Teams, FaceTime and Discord, with nothing to integrate per
  application and nothing to maintain when any of them ships a new version.
  Spotting a call needs no permission at all. A spotted call is offered, never
  recorded: automatic capture is a setting, and it is off until you turn it on.
- **The overlay answers the press.** A ring leaves the pill and the pill gives
  under it, and with system audio on it widens into two labelled traces so a
  flat line tells you the video is paused before the transcript does.

### Changed

- The entitlement set is two entries instead of one, both about audio:
  `device.audio-input` for the microphone and `device.audio-capture` for the
  Mac's own output. `SECURITY.md` and `PRIVACY.md` say what the second one
  does and when it is asked for.
- Levels are drawn against the loudest thing in the visible window rather than
  against full scale. A microphone a foot from a mouth and a video at a third
  of system volume differ by more than an order of magnitude, and a meter drawn
  from the raw figure is pinned for one and flat for the other.
- Which conferencing applications you use, and when, is no longer written to
  the system log as public data.

### Fixed

- System audio levels were measured on the converted buffer, whose format is
  whatever the engine asked for -- several of which are integer, for which
  `floatChannelData` is nil. The level silently never arrived and both traces
  sat flat while transcription worked perfectly. Measured on the tap's own
  buffer now, as the microphone path always was.

## [0.3.1] — 2026-08-24

A security release. Nothing user-facing changes except one refusal: dictation
into a password field now stops rather than falling back to the clipboard.

### Security

- **Dictation is refused when a password field has focus, or when any
  application has engaged secure input.** An `NSSecureTextField` reports
  `kAXTextFieldRole` exactly as an ordinary text field does; only its subrole
  distinguishes it, and nothing checked. Worse, when accessibility insertion
  failed the fallback wrote the spoken text to the system pasteboard first, and
  secure input makes the window server discard the synthetic paste — so the
  text was left on the clipboard and typed nowhere. Both halves failed toward
  the worst outcome.
- **Transcripts no longer reach the user's other devices.** Both pasteboard
  writes use `prepareForNewContents(with: .currentHostOnly)`. The
  `org.nspasteboard.ConcealedType` marker used previously is a convention that
  third-party clipboard managers honour; macOS does not consult it, and
  Universal Clipboard was carrying dictated sentences to other devices despite
  a comment claiming otherwise.
- **The clipboard fallback marks and confines what it leaves behind.** Reached
  by holding the key with a non-editable window focused, it previously wrote the
  transcript with no marker and no restore.
- **Downloaded summary weights are pinned to a commit** rather than tracking
  the `main` branch of a HuggingFace repository. Nothing verifies a digest
  after download, so the transport was the only integrity check; a force-push
  or a compromised upstream account could have substituted the weights that
  read a user's meetings.
- **Every release now publishes a SHA-256**, in the release notes and as a
  `SHASUMS.txt` asset, and the install instructions check it before clearing
  quarantine. `scripts/release.sh` builds, archives, and verifies the archive
  against its own checksum; it will notarise and staple once a Developer ID
  exists. See `docs/DEPLOYMENT.md` for what a checksum does and does not buy.
- Stored files are written `0600` inside a `0700` directory.

### Fixed

- **Three stores could overwrite a file they had failed to read.**
  `DecisionLedger` had no load-failure flag at all, so one damaged byte in
  `decisions.json` emptied it and the next write replaced a full history of
  answered questions with a single entry — every dismissed suggestion would
  return, permanently. `DictionaryStore` and `PeopleStore` set the flag and
  ignored it when saving; `DictionaryStore` carried a comment stating the
  invariant directly above the code that broke it.
- **Clearing history now clears the salvaged copy of it.**
  `history.corrupt.json` is a complete copy of the transcripts, written when
  `history.json` cannot be parsed, and nothing removed it — so deleting
  transcripts left them on disk under a name nobody looks for.
- **Data races between the CoreAudio render thread and the main thread.**
  `idleGrace` keeps buffers arriving after the key is released, so `stop()`
  released the closure receiving them while it was still being read. A racing
  read of a closure or class reference is an over-release, not a dropped
  buffer. `AudioCapture` and `AppleSpeechEngine` now lock the shared fields, as
  `ParakeetEngine` already did.
- `scripts/make-signing-cert.sh` exited 141 before generating anything: `tr`
  reading `/dev/urandom` took `SIGPIPE` when `head` exited, and `pipefail`
  propagated it. It had never produced the stable signing identity that keeps
  permission grants across rebuilds.
- `scripts/uninstall.sh` built `rm -rf` paths from an unguarded `$HOME`.

## [0.3.0] — 2026-08-23

### Added

- **People store.** Names are held in `people.json`, separately from vocabulary
  terms and correction rules, because a name settles once and should not be
  revised by a later pass. Each name biases the recogniser; each recorded alias
  becomes a rewrite rule, applied retroactively to existing transcripts.
- **Decision ledger.** Every outcome of the review queue — accepted as a term,
  filed as a person, added as a correction, or rejected — is recorded in
  `decisions.json` and consulted before anything is surfaced. The same word is
  never proposed twice.
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
- Detected personal names are reviewed on the People tab rather than alongside
  unrecognised words on the Words tab. They were previously distinguished only
  by a small icon in a shared list, so a colleague could be filed as vocabulary
  with one click — in a design whose whole point is that names live elsewhere.
  Separate limits also stop either kind crowding the other out of a short list.
- A manual rescan now reads unread transcripts instead of clearing every
  transcript's analysis mark, which had the effect of re-asking every question
  that had already been answered.

### Removed

- Transcript question-and-answer. It was never what this application is for, and
  keeping it meant carrying a retrieval system, a synonym table and a scope
  guard to serve a feature adjacent to the point. Summaries stay.

### Fixed

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
