# Privacy

The application makes no network requests **except one**: selecting the Parakeet
engine downloads its models once, from the model registry, and caches them in
Application Support. No audio, transcript or dictionary content is transmitted at
any point, and the default engine requires no download at all.

Everything below describes data that stays on the machine.

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

## What never happens

- No audio, transcript or dictionary content is transmitted anywhere, by any
  engine, at any time.
- No analytics, telemetry, crash reporting or update check.
- No account, and no identifier of any kind is generated or stored.
- The only outbound request the application can make is the Parakeet model
  download, which occurs only if that engine is selected, only once, and
  transmits nothing about the user.

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
