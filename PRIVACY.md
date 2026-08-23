# Privacy

The application makes no network requests of its own **except two model
downloads**, and neither carries any of your content:

1. Selecting the **Parakeet** speech engine downloads its models once.
2. Selecting **Qwen3 4B** for summaries downloads its weights once (~2.5 GB).

Both are optional, both are off by default, and after either download the
feature runs offline.

There is one further path, and it only happens when you ask for it: **sending a
transcript to ChatGPT or Claude**. That copies the transcript to your clipboard
and opens the site so you can paste it. The application transmits nothing — you
do, deliberately, and you can see exactly what you are pasting. It is offered
because a long meeting exceeds what the built-in model can read, and because not
everyone wants a 2.5 GB download.

Everything else stays on the machine.

## What is processed

| Data | Where it goes | Retention |
|---|---|---|
| Microphone audio | Held in memory, delivered to the on-device recogniser | Discarded when the utterance ends; never written to disk |
| Transcripts | `~/Library/Application Support/Huh/history.json` | Bounded to the most recent 500 entries |
| Dictionary | `~/Library/Application Support/Huh/dictionary.json` | Until deleted |
| People | `~/Library/Application Support/Huh/people.json` | Until deleted |
| Review decisions | `~/Library/Application Support/Huh/decisions.json` | Until deleted |
| Imported media | Read from the path selected; optionally moved to the Trash afterwards | Not copied |
| Preferences | `UserDefaults` under `com.getnsh.huh` | Until reset |
| Downloaded models | `~/.cache/huggingface` | Until deleted; shared with other apps using that cache |
| Transcript sent to ChatGPT or Claude | Your clipboard, then wherever you paste it | Governed by that provider, not by this application |

## What never happens

- No audio, transcript or dictionary content is transmitted by this application,
  by any engine, at any time. The one way your content reaches a third party is
  the hand-off described above, which you trigger and paste yourself.
- No audio is ever uploaded, under any setting.
- No analytics, telemetry, crash reporting or update check.
- No account, and no identifier of any kind is generated or stored.
- The only outbound requests the application makes are the two optional model
  downloads, each only if selected, each once, neither carrying user content.

## Language models

Two on-device models are used, both supplied by macOS:

- **Speech recognition** — `SpeechAnalyzer` and `SpeechTranscriber`. Models are
  provided by the system asset catalog and downloaded by macOS, not by this
  application.
- **Summaries, transcript questions and correction proposals** —
  `SystemLanguageModel` via the Foundation Models framework. The same framework
  vends `PrivateCloudComputeLanguageModel`, which sends input to Apple's servers.
  This application never references that type, so the on-device guarantee is
  enforced by the code rather than by a setting.
- **Parakeet (optional)** — Parakeet TDT via FluidAudio, running on the Neural
  Engine. Unlike the two above, its models are not supplied by macOS and are
  downloaded on first use. Once cached it runs entirely offline.

The same framework also vends `PrivateCloudComputeLanguageModel`, which sends
input to Apple's servers. This application does not reference that type
anywhere, which can be confirmed with:

```bash
grep -r PrivateCloudCompute Sources/
```

## Permissions and why each is required

| Permission | Requirement |
|---|---|
| Microphone | Capturing speech. Requested at first launch. |
| Speech Recognition | On-device transcription. Requested at first launch. |
| Accessibility | Observing the global push-to-talk key, and inserting text into the focused application. Granted manually in System Settings. |

Accessibility is the broadest of the three. It is required twice over: a
`CGEventTap` cannot observe the hotkey without it, and text cannot be inserted
into another application without it. macOS offers no narrower grant.

## Removing all data

```bash
rm -rf ~/Library/Application\ Support/Huh
defaults delete com.getnsh.huh
```
