# Architecture

## Overview

```
                    ┌──────────────────────────────────────────┐
 right ⌥  ────────▶ │ HotkeyMonitor        CGEventTap, listen  │
                    └───────────────┬──────────────────────────┘
                                    ▼
                    ┌──────────────────────────────────────────┐
                    │ DictationController                      │
                    │ idle → starting → listening → …          │
                    └───┬───────────┬───────────┬──────────────┘
                        ▼           ▼           ▼
              AudioCapture   TranscriptionEngine   HUDController
              AVAudioEngine   ├ AppleSpeechEngine   non-activating
              + conversion    └ ParakeetEngine      NSPanel
                                    │
                                    ▼
                    CorrectionEngine ─▶ TextCleanup ─▶ TextInjector
                                    │                  AX, else paste
                                    ▼
                              HistoryStore
                                    │
              ┌─────────────────────┼─────────────────────┐
              ▼                     ▼                     ▼
        SearchIndex           LearningScan          SummaryService
        inverted index        per-transcript        map-reduce over
                              analysis queue        SystemLanguageModel
```

## Module map

| Directory | Responsibility |
|---|---|
| `Core/` | Product identity, design tokens, preferences, the dictation state machine, token budgeting, logging |
| `Input/` | Global hotkey observation |
| `Audio/` | Capture and format conversion |
| `Transcription/` | Engine protocol and implementations |
| `Output/` | Text insertion into other applications |
| `Model/` | Persisted value types |
| `Services/` | Everything with a lifetime longer than a view |
| `UI/` | SwiftUI views and view state |

## The dictation path

1. `HotkeyMonitor` observes a global `CGEventTap` for the push-to-talk modifier.
2. `DictationController` transitions `idle → starting`, supplies the dictionary
   to the engine as contextual bias, and begins an utterance.
3. `AudioCapture` taps the default input, converts to the engine's requested
   format, and delivers buffers on the audio thread.
4. On release, the engine finalises and returns text.
5. `CorrectionEngine` applies dictionary rules; `TextCleanup` removes disfluency.
6. `TextInjector` delivers the result; `HistoryStore` persists the transcript.
7. `LearningScan` queues the transcript for analysis — **after** persistence, so
   transcription latency never depends on model availability.

### Design decisions

**The overlay must not take focus.** Text insertion targets the frontmost
application, so the overlay is a `.nonactivatingPanel` `NSPanel` with
`becomesKeyOnlyIfNeeded`. It is a fixed oversized transparent canvas; all
resizing happens in SwiftUI within it rather than by animating the window frame,
which avoids a window-server round trip per frame.

**Device-dependent modifier bits.** The hotkey reads the raw modifier bits from
`IOLLEvent.h` rather than `CGEventFlags`, because only the former distinguish
left from right. The tap is `listenOnly`, so events are never consumed.

**Model residency.** The speech analyzer runs with
`modelRetention: .processLifetime`, which keeps the model resident between
utterances and reduces time-to-first-word from roughly one second to under fifty
milliseconds.

**Volatile results are requested with `.fastResults`.** This trades accuracy in
the live preview for lower latency. Finalised results are unaffected.

## The dictionary

Two mechanisms, because neither is sufficient alone.

### Mechanism one: recogniser bias

Dictionary terms are passed to `SpeechAnalyzer` as
`AnalysisContext.contextualStrings`. This is advisory: the model may ignore it
entirely, and on clean audio it frequently does. The list is capped
(`DictionaryStore.biasLimit`) because long context lists cause these models to
drift and emit spurious text on near-silent audio.

Ordering matters because the list is truncated: explicit terms first, then
correction *targets*, so the recogniser is biased toward the corrected spelling
and the correction pass has less to do.

### Mechanism two: the correction pass

`CorrectionEngine` applies substitution rules deterministically. Four properties,
each preventing a specific failure:

| Property | Failure prevented |
|---|---|
| Whole-word matching, fenced by lookarounds rejecting adjacent letters, digits, hyphens and apostrophes | A trigger matching inside a longer or hyphenated word |
| Separator tolerance — any run of whitespace, hyphen or underscore, including none | Missing a match the recogniser emitted without spaces |
| Longest trigger wins | A specific rule losing to a prefix of itself |
| Single non-overlapping pass, collected against the original text and applied in reverse | One rule consuming another rule's output |

`\b` is deliberately not used: it treats a hyphen as a boundary, which would
allow a match inside a hyphenated compound.

### Safety validation

`CorrectionSafety` compiles the exact pattern the engine will use and evaluates
it against a corpus of common words and well-known proper nouns, reporting every
real collision before a rule can be saved. The check is empirical rather than
heuristic — it reports what the rule *will* do, not what it looks like.

### Retroactive application

Adding a correction applies it to all existing transcripts, including their
segments. Only the new rule is applied, never the full set, which makes the
operation idempotent. The unmodified recogniser output is retained in `raw`, so
the original is always recoverable.

## The context window

Every model-backed feature is built around one number. Apple's on-device
foundation model has a context window of **4,096 tokens per session**, and that
budget covers everything the session sees: instructions, every prompt, and the
response as it is generated. Overrunning it throws
`GenerationError.exceededContextWindowSize`, after which the session cannot
respond at all.

A token is roughly three to four characters of English, so the whole budget is
about 2,000 words — comfortably less than a ten-minute recording. No feature here
can hand the model a transcript.

`TokenBudget` makes that constraint explicit rather than implicit. It estimates
at three characters per token, the pessimistic end of Apple's range, reserves ten
percent as headroom for the estimate's error, and exposes the two operations
every call site needs: how much input room is left once instructions and the
anticipated response are accounted for, and whether an assembled request fits.
Prompts are sized before they are sent, so an oversized prompt is caught by the
code that built it rather than by the model.

Three strategies follow from the limit, one per feature:

| Feature | Strategy |
|---|---|
| Reading a transcript for names and errors | Passages, most of which never reach the model |
| Summarising | Observe, consolidate in code, then write once |
| Asking questions about a recording | Retrieval — only the passages that bear on the question |

## The learning pipeline

```
transcript persisted
        │
        ▼
LearningScan queue ── per transcript, durable, resumable
        │
        ▼
TranscriptExtractor
        │
        ├─ divide into passages sized to the window, on segment boundaries
        │
        ├─ per passage: NSSpellChecker + NLTagger locate unrecognised tokens
        │       │
        │       ├─ nothing unrecognised ─▶ no request made at all
        │       │
        │       └─ otherwise: one request carrying the passage AND its tokens
        │               │
        │               ▼
        │       ModelReply.classifications ── NAME / TERM / FIX / SKIP
        │               ├─▶ edit-distance filter   implausible answers rejected
        │               └─▶ collapse filter        one answer for many rejected
        │
        ▼
proposals ── names to PeopleStore, fixes to the dictionary, both awaiting confirmation
        │
        ▼
DecisionLedger ── every outcome recorded, so nothing is ever asked twice
```

### Why passages, not token lists

The earlier design sent the model a list of unrecognised tokens with one sentence
of context each. It failed in three ways that were only visible in use:

- A small model asked "what is *bundo*?" with nothing to go on invents an answer.
- Asked about twelve tokens at once, it tends to give them all the same answer.
- Only the first handful of tokens in a recording was ever examined, so most of a
  long transcript was never read.

The model now receives the passage itself alongside the tokens found in it, so it
answers with the surrounding conversation in front of it — which is the only way
`Lickup` is recognisable as a mis-hearing of a product name, or `critese` as a
person.

Passages are 320 words. The window would take roughly three times that; the limit
is about attention rather than capacity, since answers anchored to nearby
sentences are measurably better than answers drawn from a thousand words away.
Tokens are resolved once per transcript rather than once per passage, and a
passage with no unrecognised tokens is skipped without a request — which is what
makes reading an entire recording affordable.

### Detection

`NSSpellChecker` must be called with an **explicit language**. The
`checkSpelling(of:startingAt:)` overload relies on automatic language
identification, which cannot resolve a language from a single token in isolation
and consequently reports nearly every input as correctly spelled.

The spell checker alone is insufficient because it accepts many capitalised
unknown tokens as proper nouns — precisely the category that speech recognisers
transcribe worst. `NLTagger` named-entity recognition covers that gap using
sentence context. The two are complementary: NER requires surrounding text, while
the spell checker handles isolated tokens.

Thresholds differ by scope. Corpus-wide, a token must occur at least twice.
Within a passage the threshold is **one**, because a mis-transcribed proper noun
typically occurs once and a higher threshold suppresses the majority of true
positives.

### Validation

The language model's output is not trusted. Parsing and validation live in
`ModelReply`, which is pure, dependency-free, and the only part of the
model-backed features testable without a model present.

- **Edit distance** (`EditDistance`): a replacement must plausibly sound like the
  token it replaces. Genuine mis-transcriptions score below 0.35 normalised;
  unrelated substitutions score above 0.7. The threshold is 0.5.
- **Collapse detection**: a single answer proposed for several distinct inputs
  indicates the model has latched onto one term rather than answering each
  question independently, and the whole batch is discarded.
- **Format tolerance**: models add numbering, bullets, preamble and trailing
  commentary unprompted. All of it is stripped; lines that still do not parse are
  skipped rather than treated as fatal.

Structured generation would be preferable to text parsing, but the `@Generable`
macro is unavailable in a Command Line Tools toolchain, which this project builds
under by design.

Proposals are additionally annotated by `CorrectionSafety` and require explicit
acceptance.

## People, and never asking twice

Names are held in `people.json`, separate from the dictionary, because they
behave differently from everything else the application learns. A vocabulary term
is a hint and a correction is a rule the user wrote; a name, once established, is
a fact about the people being spoken about. It should bias the recogniser,
rewrite the spellings recognition produces for it, and never be revised by a
later pass.

A `Person` holds a canonical name plus the aliases recognition produces for it.
`Rules` assembles what dictation actually consumes — names lead the bias list,
and each alias becomes a rewrite rule applied by the existing correction engine —
so neither store needs to know the other exists.

`DecisionLedger` records the outcome of every token the reading pass has raised:
filed as a person, added as a term, added as a correction, or rejected. Every
producer of candidates consults it before surfacing anything.

This exists because being asked the same question repeatedly makes a review queue
worthless. Dismissal used to be the only recorded outcome and lived in user
defaults as a bare list of strings, which meant *accepting* a suggestion left no
trace and the next pass proposed it again. A manual rescan compounded it by
clearing every transcript's analysis mark and starting over. Now acceptance is
recorded too, and a rescan reads unread transcripts rather than re-asking
answered questions.

## Summarisation

`SummaryService` binds to `SystemLanguageModel`. The same framework vends
`PrivateCloudComputeLanguageModel`, which transmits input to Apple's servers;
that type is never referenced, so the on-device property is enforced by the type
system rather than by configuration.

Three passes, with different jobs:

1. **Observe.** Each 600-word chunk, split on segment boundaries, produces
   labelled lines — `TOPIC`, `DECISION`, `ACTION`, `QUESTION`, `PERSON`. This is
   a copying task rather than a writing one, which is what a small model is
   reliable at.
2. **Consolidate.** Duplicates are collapsed in ordinary code, by edit distance.
   "The same decision stated twice" is a string comparison, not a judgement call,
   and code cannot paraphrase while merging.
3. **Write.** One pass turns the consolidated list into fixed headings. By this
   point it is working from a short structured list rather than four thousand
   words.

Asking a small model to "summarise" a slice of transcript produces prose that
reads well and quietly drops half the content; asking it to summarise those
summaries compounds the loss. The staged form exists because the earlier
map-reduce did exactly that.

Participants are assembled deterministically from `PERSON` observations,
cross-checked against the transcript text and spelled the way `PeopleStore`
spells them. A model asked who attended a meeting will supply names.

A chunk that overflows despite budgeting is bisected and retried; an observation
list too long for the writing pass is condensed in batches rather than truncated,
so the end of a long meeting is not silently lost.

## Asking questions about a transcript

`TranscriptChat` answers questions about one recording. Handing the model the
transcript is not an option, so each question retrieves the passages that bear on
it — Apple's documented approach for exactly this case.

Retrieval is lexical rather than vector-based: passages of 110 words are scored
by inverse document frequency over the transcript's own vocabulary, so a word
appearing in every passage contributes nothing and a rare one dominates. That is
what makes a name or a product the deciding term in a question containing one. No
embedding model, no prepared index, no download. Selected passages are returned
to chronological order before assembly, since an answer built from passages in
relevance order reads as though the meeting happened backwards.

Each question opens a fresh session with the previous exchange restated in the
prompt. A persistent session would accumulate every excerpt from every earlier
question and overflow within a few turns.

Two guards keep answers honest. If nothing in the transcript matches the
question, no request is made. If the model is given passages that do not contain
the answer, it is instructed to reply in a form this code recognises, which is
replaced with a plain admission. For a local model working from one recording
that is the correct outcome, and much better than a confident invention — one
fabricated answer makes every other answer untrustworthy.

## Search

An inverted index over transcript text and source filenames, rebuilt whenever
history changes. A linear substring scan is adequate for a handful of transcripts
but degrades at the store's capacity; tokenising once and intersecting posting
lists keeps query latency roughly constant. The final query term is matched by
prefix so results update as the query is typed.

For imported recordings, results are timecoded segments rather than whole
documents.

## File transcription

Two code paths, because the relevant API arrived across two OS releases:

- macOS 27 provides `AssetInputSequenceProvider`, which accepts an `AVAsset`
  directly, including video containers.
- macOS 26 does not, so the audio track is exported to a temporary m4a and
  processed through `analyzeSequence(from:)`.

The deployment target remains macOS 26. Throughput is approximately 40× realtime
on Apple silicon.

## Persistence

| File | Contents |
|---|---|
| `~/Library/Application Support/Huh/dictionary.json` | Terms and correction rules |
| `~/Library/Application Support/Huh/people.json` | Names and the spellings recognition produces for them |
| `~/Library/Application Support/Huh/decisions.json` | Every token the reading pass has already asked about |
| `~/Library/Application Support/Huh/history.json` | Transcripts, bounded to 500 entries |

Both are pretty-printed with sorted keys so hand edits produce clean diffs. The
dictionary is watched with a `DispatchSource` file-system observer; because most
editors replace files by rename rather than writing in place, `.delete` and
`.rename` re-arm the watch on a fresh descriptor.

### Schema evolution

Swift's synthesised `Decodable` conformance throws on a missing key rather than
falling back to a property's default value. Adding a field to `Transcript` would
therefore render every previously persisted transcript undecodable, and a naive
store would load an empty list and then persist it, destroying the history.
`Transcript` implements `init(from:)` explicitly using `decodeIfPresent`, and
`HistoryStore` reports decode failures rather than silently loading empty.

## Performance

**Long transcripts.** `LazyVStack` is lazy only with respect to its direct
children, so expanding a row inline instantiated every segment of a recording at
once. Transcripts open into a detail view with its own `ScrollView` and
`LazyVStack`, so only visible rows are constructed.

**Playback observation.** `PlaybackController` publishes the active segment
identifier and only when it changes. Publishing raw playback time invalidated
every observing view several times per second, which is untenable on a timeline
of several hundred segments.

**Analysis scheduling.** Transcripts are persisted first and queued second.
Analysis is debounced, so a burst of short dictations produces a single pass.

## Platform constraints

**Command Line Tools do not ship `libSwiftUIMacros.dylib`.** `@State`,
`@StateObject` and `@FocusState` therefore fail to compile. All view state is
held in `ObservableObject` types reached via `@ObservedObject` — see
`UI/UIState.swift`. This keeps the interface's entire state inspectable in one
place; it is also a hard constraint for contributors building without Xcode.

**Display name versus filesystem name.** The product is displayed as `huh?` and
stored as `Huh`. `?` is both a shell glob and a regular-expression
metacharacter, so it appears only in quoted paths and never in executable names,
script paths or process-matching patterns. `Brand.name` and `Brand.productName`
formalise the split.

## Testing

Suites compile the shipping sources directly and assert against them — no mocks,
no duplicated logic. Run with `./scripts/test.sh`.

| Suite | Covers |
|---|---|
| `verify-corrections.sh` | Matching, separator tolerance, precedence, non-overlap, audit trail, safety warnings |
| `verify-cleanup.sh` | Disfluency removal, and the words that must survive it |
| `verify-plausibility.sh` | Edit-distance rejection of implausible corrections |
| `verify-extraction.sh` | Model reply parsing, validation, collapse detection, observation consolidation, token budgeting |

The negative cases carry most of the value: each suite exists because a rule was
once broader than intended.
