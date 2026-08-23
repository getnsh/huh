# Deployment

## Compatibility

### Hard requirements

| Requirement | Value | Enforced by |
|---|---|---|
| Operating system | macOS 26.0 or later | `LC_BUILD_VERSION minos 26.0`; the loader refuses to start on anything older |
| Architecture | `arm64` — Apple silicon only | The binary contains a single slice. Rosetta translates Intel to Apple silicon, not the reverse, so an Intel Mac cannot run it |
| Memory | 8 GB | Practical floor for the on-device speech and language models |

macOS 26 does run on a small number of Intel Macs — MacBook Pro 16-inch (2019),
MacBook Pro 13-inch (2020, four Thunderbolt ports) and iMac (2020) — but Apple
Intelligence is unavailable on all of them, and macOS 27 drops Intel entirely. An
Intel slice would therefore ship a build that cannot summarise, cannot propose
corrections, and has no future. The project is Apple silicon only by decision,
not by omission.

If an Intel slice is ever wanted:

```bash
swift build -c release --arch arm64 --arch x86_64
```

### Feature matrix

| Feature | macOS 26 | macOS 27 | Additional requirement |
|---|---|---|---|
| Push-to-talk dictation | ✅ | ✅ | Microphone, Speech Recognition, Accessibility |
| Text insertion | ✅ | ✅ | Accessibility |
| File transcription | ✅ | ✅ | Uses an audio-export fallback on 26 |
| Timeline playback | ✅ | ✅ | Source file must still exist |
| Dictionary and corrections | ✅ | ✅ | None |
| Cleanup, search, export | ✅ | ✅ | None |
| Login item | ✅ | ✅ | User approval in Login Items |
| Vocabulary detection | ✅ | ✅ | None — `NSSpellChecker` and `NLTagger` are always available |
| **Summaries** | ⚠️ | ⚠️ | Apple Intelligence enabled |
| **Correction proposals** | ⚠️ | ⚠️ | Apple Intelligence enabled |

### Behaviour without Apple Intelligence

There is one build, not two. `FoundationModels.framework` is present on every
macOS 26 installation regardless of whether Apple Intelligence is enabled, and
`SystemLanguageModel.default.availability` reports `.unavailable` rather than
trapping, so linking it never prevents the application from launching.

The two model-backed controls remain visible and enabled. Using one explains
what is required and offers to open the Apple Intelligence settings pane
directly. `ModelAvailability` is the single source of truth for this and
re-evaluates whenever the application becomes active, so enabling Apple
Intelligence and switching back is enough — no relaunch.

Every other capability is unaffected, including vocabulary detection, which uses
`NSSpellChecker` and `NLTagger` and needs no language model at all.

### Network

The application makes no network requests. macOS itself downloads speech
recognition assets for a locale on first use, and Apple Intelligence models
through Software Update. Both are system operations outside the application's
control; after they complete, the application runs fully offline.

## Distribution

### Option 1 — Developer ID and notarisation (recommended)

The only route that produces a build others can open without warnings or manual
overrides. Requires membership of the Apple Developer Program.

```bash
# once
xcrun notarytool store-credentials huh-notary \
    --apple-id "you@example.com" --team-id "TEAMID" \
    --password "app-specific-password"

# per release
SIGN_ID="Developer ID Application: Your Name (TEAMID)" ./scripts/notarize.sh
```

The script builds with the Hardened Runtime, archives with `ditto` — `zip` does
not preserve the signature — submits to Apple, staples the ticket, re-archives,
and confirms the result with `spctl`. The output in `dist/` can be attached to a
GitHub release.

A stapled ticket means the build validates offline, so a first launch works
without network access.

### Option 2 — Build from source

Appropriate for a repository whose audience can run a build.

```bash
git clone https://github.com/<user>/huh.git && cd huh
./scripts/install.sh
```

Requires Xcode Command Line Tools. Produces an ad-hoc signed build, which is
trusted on the machine that produced it. No developer account needed.

### Option 3 — Unsigned distribution

Possible, but the recipient experience is poor and worth stating plainly.
An ad-hoc signed build is rejected by Gatekeeper on any other machine:

```
spctl --assess --type execute "/Applications/huh?.app"
→ rejected
```

Since macOS 15, Control-clicking an application no longer bypasses this. The
recipient must open **System Settings ▸ Privacy & Security**, find the blocked
application, and choose **Open Anyway** — or strip the quarantine attribute
themselves:

```bash
xattr -dr com.apple.quarantine "/Applications/huh?.app"
```

Asking users to disable a security control in order to install a tool that
requests Accessibility permission is a bad combination. Prefer option 1 or 2.

### Option 4 — Homebrew cask

Convenient once a notarised release exists:

```ruby
cask "huh" do
  version "0.1.0"
  sha256 "..."
  url "https://github.com/<user>/huh/releases/download/v#{version}/Huh-#{version}.zip"
  name "huh?"
  desc "On-device push-to-talk dictation"
  homepage "https://github.com/<user>/huh"
  depends_on macos: ">= :tahoe"
  app "huh?.app"
end
```

### Not viable — the Mac App Store

The App Store requires the App Sandbox. A sandboxed process cannot use the
Accessibility API to read the focused element of another process or insert text
into it, which is the application's primary function. This is the same reason
text expanders and window managers are distributed outside the store.

## What does not transfer between machines

**Permissions.** Microphone, Speech Recognition and Accessibility are granted per
machine and cannot be pre-authorised. Each installation prompts on first launch,
and Accessibility must be enabled manually.

**Signature-bound grants.** macOS records permission grants against the code
signature. With a stable Developer ID identity, grants survive updates. With
ad-hoc signing they do not, because the signature changes with every build.

**User data.** The dictionary and history live in
`~/Library/Application Support/Huh/` and are not synced. To move a dictionary to
another machine, copy `dictionary.json` — it is plain JSON and is read on launch.

## Release checklist

1. Update `VERSION` and `CHANGELOG.md`.
2. `./scripts/test.sh` — all suites pass.
3. `SIGN_ID="Developer ID Application: …" ./scripts/notarize.sh`.
4. Confirm `spctl --assess` reports **accepted**.
5. Verify on a machine that has never run the application, to catch anything
   that depends on existing permission grants or local state.
6. Tag the release and attach `dist/Huh-<version>.zip`.
