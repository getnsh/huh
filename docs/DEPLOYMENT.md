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

## Installing on another machine

huh? is distributed two ways: a zip attached to each GitHub release, and source
you build yourself. Neither is notarised yet — see **Release integrity** below
for what that means and what stands in for it.

```bash
git clone https://github.com/getnsh/huh.git
cd huh
./scripts/install.sh
```

This builds with the Hardened Runtime, assembles the bundle, signs it ad hoc and
installs to `/Applications`. The build takes a couple of minutes; the first
launch asks for Microphone and Accessibility access.

An ad-hoc signature is tied to the machine that produced it, which has one
consequence worth knowing during development: the signature changes on every
rebuild, so macOS treats each build as a different application and asks for both
permissions again. Creating a stable local certificate once fixes that — see
[CONTRIBUTING.md](../CONTRIBUTING.md).

Because the signature is local, a bundle copied from one Mac to another is
rejected by Gatekeeper. Build on the machine you intend to run it on.

## What does not transfer between machines

**Permissions.** Microphone, Speech Recognition and Accessibility are granted per
machine and cannot be pre-authorised. Each installation prompts on first launch,
and Accessibility must be enabled manually.

**Signature-bound grants.** macOS records permission grants against the code
signature, and an ad-hoc signature changes with every build, so a rebuild asks
again. A stable local certificate keeps grants across rebuilds — see
[CONTRIBUTING.md](../CONTRIBUTING.md).

**User data.** The dictionary and history live in
`~/Library/Application Support/Huh/` and are not synced. To move a dictionary to
another machine, copy `dictionary.json` — it is plain JSON and is read on launch.

## Release integrity

Downloaded builds are **not notarised**. Apple's notary service requires a paid
Developer Program membership and a Developer ID Application certificate, and
this project has neither yet.

That absence is not cosmetic. Without notarisation, macOS refuses to open the
app at all until the quarantine flag is cleared, so the install instructions
have to tell people to run `xattr -cr` — which is precisely the step that
removes the warning they would otherwise get about an unverified binary. The
app then asks for the microphone and for Accessibility, which is permission to
read and write text in every other application. A swapped release asset, with
those instructions, would install silently.

Until notarisation is possible, a published SHA-256 stands in for it:

* `./scripts/release.sh` builds, stages, archives with `ditto` (so the
  signature and extended attributes survive, and there is no `__MACOSX`
  directory), computes the digest, and verifies the archive against its own
  checksum before reporting success.
* `./scripts/release.sh --publish` attaches the archive and `SHASUMS.txt` to
  the GitHub release. **The digest must also go in the release notes**, because
  a checksum stored beside the file it describes proves nothing — an attacker
  who can replace one can replace the other. The release notes are a separate
  surface with its own audit log.
* Both `README.md` and the bundled `INSTALL.txt` tell users to check the
  checksum *before* running `xattr`, and say why that order matters.

What this does and does not buy: it makes a swap detectable by anyone who
checks, and it gives every past download a fixed identity. It does not stop a
swap, and it does nothing for users who skip the step. Notarisation remains the
correct fix — once a Developer ID exists, set `SIGN_ID` and store a notarytool
profile, and `release.sh` will notarise and staple automatically, at which point
the `xattr` instruction can be deleted outright.

## Release checklist

1. Update `VERSION` and `CHANGELOG.md`.
2. `./scripts/test.sh` — all suites pass.
3. `./scripts/build.sh` — bundle assembles and the signature verifies.
4. Verify on a machine that has never run the application, to catch anything
   that depends on existing permission grants or local state.
5. Tag the release.
6. `./scripts/release.sh --publish` — archive, checksum, attach.
7. Paste the SHA-256 into the release notes.
