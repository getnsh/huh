# Contributing

## Requirements

- macOS 27 or later to build (the app itself runs on macOS 26 — see
  [Compatibility](README.md#compatibility) for why those differ)
- Xcode, and the Metal toolchain: `xcodebuild -downloadComponent MetalToolchain`

The bundle is assembled by `scripts/build.sh` rather than by Xcode, but Xcode is
still required: the summary model runs through MLX, whose GPU kernels are Metal
source compiled at build time, and the `metal` compiler ships only with Xcode —
as a separate download even there. `build.sh` checks for it and says so plainly
if it is missing.

One consequence worth knowing: Command Line Tools do not ship
`libSwiftUIMacros.dylib`, so `@State`, `@StateObject` and `@FocusState` will not
compile. View state is held in `ObservableObject` types instead — see
`UI/UIState.swift`. Code that introduces those property wrappers will build under
Xcode and fail under Command Line Tools.

## Build and run

```bash
./scripts/install.sh      # build and install to /Applications
./scripts/test.sh         # run all verification suites
./scripts/make-icon.sh    # regenerate the app icon
./scripts/uninstall.sh    # remove the app (add --all to delete stored data)
```

For local development, create a stable signing certificate once so that macOS
permission grants survive rebuilds:

```bash
sudo ./scripts/make-signing-cert.sh
SIGN_ID="Huh Dev" ./scripts/install.sh
```

Without this, the ad-hoc signature changes on every build and Microphone and
Accessibility must be granted again each time.

## Tests

Suites compile the shipping sources directly and assert against them; there are
no mocks and no duplicated logic.

| Suite | Covers |
|---|---|
| `verify-corrections.sh` | Matching, separator tolerance, precedence, non-overlap, safety warnings |
| `verify-cleanup.sh` | Disfluency removal, and the words it must not touch |
| `verify-plausibility.sh` | Edit-distance rejection of implausible corrections |
| `verify-extraction.sh` | Model reply parsing, validation, collapse detection, observation consolidation, token budgeting |

Add a case to the relevant suite for any change to matching, cleanup or
validation behaviour. The negative cases matter as much as the positive ones:
most of these suites exist because a rule was once too broad.

## Style

- Comments explain *why*, not *what*. A comment that restates the code is noise.
- Where a decision has a non-obvious rationale — an API that behaves
  unexpectedly, a threshold chosen from measurement — record it at the decision
  site.
- No `TODO` or `FIXME` in committed code. Open an issue instead.
- Keep user-facing strings in the view that renders them; keep product naming in
  `Core/Branding.swift`.

## Pull requests

State what changed and why. If behaviour changed, say how it was verified. If a
threshold or heuristic changed, include the measurement that motivated it.
