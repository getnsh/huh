# Parity references

Screenshots of the macOS app, captured at native resolution from a running
build. They exist so the Windows interface can be checked against the thing it
is copying rather than against a description of it.

| File | What it shows |
|---|---|
| `hud.png` | The dictation overlay, in mixed mode: both traces, the caption, the pill radius |
| `pill.png` | The collapsed session mark |
| `panel.png` | The session panel, expanded: header, controls, trace rows, transcript rail |
| `settings.png` | Settings: group cards, row labels, pickers, switches, note type |

The numbers come first. The grey ladder, the radii and the two motion curves are
already in `../app/src/tokens.css`, generated from the Mac's `Theme.swift`, so
nothing here should be measured off a pixel that can be read from the source.
These images are for what numbers miss: tracking, optical weight, and how the
layout sits once Inter stands in for SF Pro.

The main window is deliberately absent. It shows real transcripts.
