<div align="center">

# huh?

**Push-to-talk dictation for macOS. Entirely on-device.**

Hold a key, speak, release. The text appears wherever the cursor is.

[Install](#install) · [Usage](#usage) · [Architecture](docs/ARCHITECTURE.md) · [Deployment](docs/DEPLOYMENT.md) · [Privacy](PRIVACY.md) · [Security](SECURITY.md)

</div>

---

## What it does

Dictation into any application, transcription of meeting recordings, and a
dictionary that learns the words and names your recogniser keeps getting wrong.

No user content leaves the machine. There is no account and no telemetry. Speech
recognition, correction, summarisation and vocabulary learning all run on-device;
the only outbound request the app can make is downloading the optional Parakeet
models, once, if you choose that engine.

## Features

**Dictation**
Hold a modifier key anywhere and speak. Text is inserted into the focused field
via the Accessibility API, falling back to the pasteboard when an application
does not support direct insertion. A floating overlay shows the live
transcription and confirms where the text was delivered.

**File transcription**
Drop an audio or video file onto the window, or press ⌘O. Roughly **40× realtime**
on Apple silicon, so an hour-long recording completes in about ninety seconds.
Produces timestamped segments; clicking a timecode seeks the source recording.

**A dictionary that actually enforces itself**
Two entry types, because one alone is insufficient:

- *Terms* are supplied to the recogniser as contextual bias before transcription.
  This is advisory — the model may ignore it.
- *Corrections* are substitution rules applied deterministically afterwards. This
  is the guarantee.

Corrections match whole words only, tolerate missing or hyphenated separators,
prefer the longest trigger, and apply in a single non-overlapping pass. Adding a
rule also rewrites every transcript already stored.

**Learning, over the whole recording**
Each transcript is read once in the background after it is saved — all of it, in
passages, not just the opening. Within each passage, tokens absent from the
system dictionary are found by `NSSpellChecker` and personal names by `NLTagger`
named-entity recognition; the on-device language model then sees the passage
*and* its unrecognised words together, so it answers with the surrounding
conversation in front of it. Passages containing nothing unrecognised never reach
the model at all. Every proposal is validated by edit distance and collision
analysis before it is shown, and nothing is applied without confirmation.

**People, kept separate**
Names live in their own store rather than in the dictionary, because a name
settles once and should not move again. Each name biases the recogniser and
rewrites the spellings recognition produces for it. Every review decision —
accepted, filed as a person, or rejected — is recorded permanently, so you are
never asked about the same word twice.

**Summaries**
Participants, decisions, action items with owners, and open questions. The model
extracts labelled observations from each chunk, duplicates are merged in code
rather than by a model, and a single final pass writes it up. Participants are
assembled from the transcript itself, never generated.

**Search**
Full-text search across every transcript using an inverted index. Results for
imported recordings are timecoded segments rather than whole documents.

**Cleanup**
Removes disfluency — "uh", "um", repeated discourse markers — at three
configurable levels, using pattern matching rather than a model.

## Compatibility

| | Requirement |
|---|---|
| macOS, to run | 26.0 or later |
| macOS, to build | 27.0 or later, with Xcode — see below |
| Architecture | Apple silicon (`arm64`) |
| Memory | 8 GB or more |
| Building | Xcode, plus `xcodebuild -downloadComponent MetalToolchain` |

**Running and building have different requirements.** File transcription uses
`AssetInputSequenceProvider` where it exists and falls back to exporting the
audio track on macOS 26. The fallback is chosen at runtime by
`if #available(macOS 27.0, *)`, so a binary built once runs correctly on either
version — but `#available` is a runtime check, and resolving the symbol at all
needs the macOS 27 SDK. Building on macOS 26 therefore fails to compile, while
the binary produced on macOS 27 runs on macOS 26 unmodified.

This is why continuous integration verifies the logic suites but does not build:
GitHub-hosted runners currently ship macOS 26.

Summarisation and correction proposals additionally require Apple Intelligence.
Without it, both controls stay visible, explain what is needed, and offer to open
the relevant settings pane; nothing else is affected. Vocabulary detection in
particular needs no language model — it uses the system spell checker and
named-entity recogniser.

Intel Macs are not supported. A few can run macOS 26, but none can run Apple
Intelligence, and macOS 27 drops Intel entirely. See
[docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) for the full matrix.

## Install

### Download it

Grab the latest zip from [Releases](https://github.com/getnsh/huh/releases), then:

```bash
cd ~/Downloads
unzip huh-*.zip
xattr -cr "huh-0.3.0/huh?.app"
mv "huh-0.3.0/huh?.app" /Applications/
open "/Applications/huh?.app"
```

The `xattr` step is required. Builds are signed on the machine that produced
them rather than by Apple, so macOS refuses to open the app until the quarantine
flag it attached on download is cleared. Nothing else is needed — no Xcode, no
Swift, no build.

`uninstall.sh` is in the same folder. Run it bare to remove the app and keep your
data, or with `--all` to delete the transcripts and dictionaries too.

### Or build it yourself

Only if you want to change something. This needs **Xcode** — not just the
Command Line Tools — plus the Metal toolchain, because the optional summary
model compiles Metal shaders at build time:

```bash
xcodebuild -downloadComponent MetalToolchain   # once, ~840 MB
git clone https://github.com/getnsh/huh.git
cd huh
./scripts/install.sh
```

Roughly two minutes from a clean clone. `build.sh` locates Xcode itself and
stops with a clear message if the Metal toolchain is missing.

### Permissions

| Permission | Why | How it is granted |
|---|---|---|
| Microphone | Capturing speech | Prompted at first launch |
| Speech Recognition | On-device transcription | Prompted at first launch |
| Accessibility | Observing the push-to-talk key **and** inserting text | Manually, in System Settings ▸ Privacy & Security ▸ Accessibility |

Accessibility is checked every two seconds until granted, so no relaunch is
needed after enabling it.

> **Note**
> macOS records permission grants against an application's code signature. An
> ad-hoc signature changes on every build, so a rebuild requires granting
> permissions again. For active development, run
> `sudo ./scripts/make-signing-cert.sh` once and build with `SIGN_ID="Huh Dev"`.

## Usage

### Dictating

Hold **right ⌥** (configurable) and speak. Release to insert. Activations shorter
than 180 ms are ignored as stray keypresses.

Insertion reports its outcome: *Inserted at cursor* via the Accessibility API,
*Pasted at cursor* via the pasteboard, or *Copied to clipboard* when no editable
field has focus — in which case no keystroke is synthesised and the text is left
where it can be retrieved.

### Transcribing a recording

⌘O, the toolbar button, or drag a file onto the window. Afterwards the source
file may be moved to the Trash — offered inline rather than as a dialog, and only
after the transcript has been written to disk.

### Teaching it a word

Press **Learn** (⌘L) to analyse the whole history, or wait: every new transcript
is analysed automatically. Unrecognised tokens appear in the Dictionary tab with
two options, because there are two opposite correct answers:

- **Add as a word** when the spelling is right and the recogniser simply does not
  know it.
- **It's a mis-hearing** when the spelling is wrong, which opens a correction
  rule with the trigger prefilled and requests a suggested replacement.

### Editing the dictionary by hand

The dictionary is plain JSON at
`~/Library/Application Support/Huh/dictionary.json`, pretty-printed with sorted
keys so hand edits diff cleanly. The file is watched: external changes appear in
the interface without relaunching. A file that fails to parse is reported and
left untouched rather than overwritten.

### Exporting

Copy includes timecodes when the transcript has them. The share menu adds plain
text, rich text, and export to `.txt`, `.md`, `.srt` and `.vtt`. *Send to Google
Docs* writes rich text to the pasteboard and opens a blank document — the same
result as an API integration, without an OAuth flow.

## Configuration

Settings (⌘,) covers the push-to-talk key, hold versus toggle activation, the
recognition engine and language, cleanup level, insertion strategy, and login
item registration.

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md) for the build and test workflow, and
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the design.

```bash
./scripts/test.sh
```

## Diagnostics

```bash
log stream --predicate 'subsystem == "com.getnsh.huh"' --level debug --style compact
```

Categories: `app` (state machine, permissions, persistence, analysis), `audio`
(device format, buffer counts, levels), `asr` (engine preparation, bias, results,
corrections), `inject` (insertion strategy and outcome).

## Roadmap

- Speaker diarisation for multi-speaker recordings, which Apple's speech
  framework does not provide. The `TranscriptionEngine` abstraction and the
  stubbed `ParakeetEngine` exist for this.

## License

Free to use, on as many of your own machines as you like. Please don't ship
modified or rebranded copies — see [LICENSE](LICENSE).
