# huh? for Windows

Push-to-talk dictation and meeting transcription for Windows 10 and 11, built to
look and feel like [the Mac app](../README.md) rather than like a port of it.

The Mac app stays native Swift and is untouched by anything in this folder.

## How it is put together

A Rust core and a web interface, through [Tauri 2](https://tauri.app). Web
rendering is the only route that gives the same control over a pixel, a curve
and a shadow that SwiftUI gives on the Mac, so matching the Mac becomes a matter
of matching numbers rather than fighting a widget toolkit. WebView2 ships with
Windows, so nothing bundles a browser.

```
windows/
  crates/huh-core/     corrections, cleanup, edit distance, the stores
  app/src-tauri/       the Tauri app, the keyboard hook, audio, insertion
  app/src/             the interface, in Svelte 5
  setup/               the installer and uninstaller, one program
```

Everything timing-sensitive is in Rust. The interface only draws and sends
commands, so a busy interface can never delay a keypress or a paste.

`huh-core` holds the parts of the Mac app that are plain logic. It builds and
tests on any platform, which is what makes the port verifiable on the machine it
is written on, and it is held to
[one fixtures file](../shared/correction-fixtures.json) that the Swift engine is
held to as well. A case added there fails on whichever engine has not learned it
yet, which is the only way two implementations in two languages stay one
implementation.

## Decisions already taken

| Question | Taken |
|---|---|
| Push-to-talk key | **Right Ctrl.** Right Alt is AltGr on many layouts, and Win and Alt open Start or the menu bar when released on their own |
| Caption buttons | Minimise, maximise and close on the right, in the huh? greys, because that is where a Windows hand goes |
| Type | Bundled Inter and JetBrains Mono at the Mac's sizes and weights. SF Pro cannot ship on Windows |
| Name on disk | `Huh`. The display name has a `?` in it, which a Windows path cannot hold. The window, the tray and the installer still say huh? |
| Licence | GPL-3.0-or-later, the same as the rest of the repository |
| Signing | Unsigned with a published SHA-256, the same as the Mac releases |

## Building

Needs [Rust](https://rustup.rs), Node 22, and on Windows the
[WebView2 runtime](https://developer.microsoft.com/microsoft-edge/webview2/)
(already present on Windows 11 and on an up-to-date Windows 10).

```bash
cd windows/app
npm install
npm run tauri dev       # or: cargo run -p huh
```

The setup, with the app inside it, lands in
`windows/target/release/huh-setup.exe`:

```bash
cd windows/app
npm run setup           # tauri build, then the setup around it
```

The portable core can be tested anywhere, including on a Mac:

```bash
cargo test --manifest-path windows/Cargo.toml -p huh-core
```

## The setup

A program of its own rather than the stock NSIS wizard, so the first thing
anyone sees of huh? looks like huh?: the website's Chladni plate fills the
window, and the sand is retuned toward a more intricate figure as each step of
the install runs, then settles. Once it is installed, the overlay demonstrates
itself beside the key to hold. Windows' Animation effects switch is followed
while the window is open; with it off, every state is drawn still.

- **Per user, no administrator.** The app goes to `%LOCALAPPDATA%\Huh`, the
  folder the stock installer used, so it updates over either. It adds a Start
  entry, an optional desktop shortcut, and the entry in Installed apps.
- **Update and reinstall** say so, and say what they keep. A copy that is
  running is closed first.
- **Uninstall** is the same program, copied beside the app as `uninstall.exe`;
  Installed apps starts it, and so does the Uninstall button the setup shows
  once huh? is installed. Transcripts, the dictionary and the downloaded
  models stay unless the person asks for them to go. It removes itself last.
- **Without a window**, for package managers: `--silent` (or `/S`) installs,
  `--uninstall --silent` removes, with the exit code to say how it went.

`HUH_SETUP_TEST=<folder>` redirects every path and the registry entry into
that folder and a private key, so the setup can be run end to end without
touching a real install.

## Speech recognition

Parakeet TDT 0.6B v3, the model the Mac runs on its Neural Engine. Here it is
NVIDIA's network exported to ONNX and quantised to int8
([istupakov/parakeet-tdt-0.6b-v3-onnx](https://huggingface.co/istupakov/parakeet-tdt-0.6b-v3-onnx)),
run on the CPU by ONNX Runtime through
[transcribe-rs](https://github.com/cjpais/transcribe-rs). The model is NVIDIA's,
under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).

It is not in the installer. On first launch the app fetches 670 MB from one
pinned revision, checks every file against a SHA-256 compiled into it, and keeps
it in `%LOCALAPPDATA%\Huh\Models`, where a roaming profile will not copy it
around. That download is the only request the app makes over the network, and
it carries nothing of yours. An interrupted download resumes where it stopped.

Parakeet does not stream, so while the key is held the overlay's words come from
reading the utterance again, its last twelve seconds at most, as often as the
machine can, and the final pass reads the whole of it when the key comes up.
Only one preview is ever under way, and one that has not started is dropped
rather than put ahead of the final pass, so the most a preview can delay the
text is the second or so it takes to finish.

To check the recogniser without a microphone, or without anyone to talk into one:

```bash
cargo run --manifest-path windows/Cargo.toml -p huh --example transcribe -- speech.wav
```

## What works today

Everything the Mac app does, on a physical PC.

- **Dictation.** Hold Right Ctrl (or tap it, in toggle mode) and the overlay
  appears without taking focus from the window being dictated into. The words
  so far show in the pill while you speak. On release the text goes through
  the dictionary and cleanup, is typed or pasted into whatever has focus, and
  is kept in the history. A muted microphone, or one that Windows' privacy
  settings keep from desktop apps, is named at the press rather than
  discovered as silence. With "Your PC as well as you" on, what the PC is
  playing is summed in, and the overlay shows the two as separate traces.
- **Live sessions.** Start Meeting, or a call noticed in Teams, Zoom, Slack,
  Discord, Webex or a browser, transcribes the microphone and the PC's own
  sound separately, through WASAPI loopback, which needs no permission. A
  small mark sits at the top right of the screen; click it and it opens into
  the running transcript, drag it and it stays where it is put. The session is
  saved line by line, with timestamps, when it stops.
- **Importing recordings.** Drop an audio or video file on the window, or use
  the import button. Media Foundation decodes it, it is cut at pauses into
  pieces Parakeet can take, and the transcript comes back line by line with
  timestamps, playable from the original file.
- **Learning.** Transcripts are read for names and words the dictionary
  doesn't know. A word that sounds like a known term is offered as a fix; a
  name that sounds like someone already known is asked about as that person;
  any other unfamiliar capitalised word is asked about as a possible name.
  An answer is filed in the dictionary or with the person, applied to the
  transcripts already kept, and from then on to everything new. Questions
  survive a restart.
- **Summaries.** Summarise on an open transcript writes it up under the Mac's
  five headings, with Qwen3 4B running on this PC through ONNX Runtime: the
  same model the Mac downloads for the same job, as an int4 build for the
  CPU. It is fetched the first time a summary asks for it (2.9 GB, pinned to a
  commit and checked against its hashes), reads the whole meeting in one
  pass, and streams the write-up as it goes. On a laptop processor it reads
  about fifty tokens a second, so an hour of meeting takes five or six
  minutes, where the Mac's GPU takes one. It leaves memory after ten idle
  minutes, or from Settings.
- **Everything around it.** Transcripts with search, export (plain text, with
  timestamps, Markdown, SRT, WebVTT) and copy; the dictionary's Words,
  Corrections and People; Settings; the notification-area icon with the Mac's
  menu; feedback sounds; start at sign-in.

The portable core is done and tested: corrections, cleanup, edit distance, the
learning pass, the models and the stores, reading and writing the same files
the Mac does, so a folder copied from one opens on the other.

What can't come across: Apple's own on-device model, the Mac's other summary
engine, which exists only on a Mac. Qwen3 4B, its alternative there, is the
only one here.
