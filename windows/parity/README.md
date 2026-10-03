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
| `main-transcripts.png` | The main window: title bar, section tabs, search, transcript rows, transport bar |
| `main-transcript-detail.png` | One transcript open: the back control, the header actions, the body |
| `dictionary-words.png` | Dictionary, Words tab: tabs with counts, switch rows, the file path footer |
| `dictionary-corrections.png` | Dictionary, Corrections tab: hear and write pairs with hit counts |
| `dictionary-people.png` | Dictionary, People tab: names, aliases, the learned badge, the suggestions banner |
| `dictionary-editor.png` | The editor sheet: field labels, inputs, explanatory note, Cancel and Save |

The numbers come first. The grey ladder, the radii and the two motion curves are
already in `../app/src/tokens.css`, generated from the Mac's `Theme.swift`, so
nothing here should be measured off a pixel that can be read from the source.
These images are for what numbers miss: tracking, optical weight, and how the
layout sits once Inter stands in for SF Pro.

Every word of content in these is invented. The app was run against a scratch
data folder seeded with made-up transcripts, terms and names so the layouts
could be photographed without putting anyone's real transcripts, vocabulary or
contacts in a public repository.
