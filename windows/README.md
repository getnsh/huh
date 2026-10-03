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

The portable core can be tested anywhere, including on a Mac:

```bash
cargo test --manifest-path windows/Cargo.toml -p huh-core
```

## What works today

The portable core is done and tested: corrections, cleanup, edit distance, the
models and the stores, reading and writing the same files the Mac does, so a
folder copied from one opens on the other. The Windows modules -- the keyboard
hook with its watchdog, the capture path, and the UI Automation plus SendInput
plus clipboard insertion ladder -- are written and compile under CI, and have not
yet been run on a physical PC. Speech recognition is not wired in yet.
