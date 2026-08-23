# Security

## Reporting a vulnerability

Report suspected vulnerabilities privately using GitHub's **Report a
vulnerability** button under the Security tab, rather than opening a public
issue. Please include the macOS version, the application version, and a
reproduction if one exists.

Expect an acknowledgement within seven days.

## Threat model

The application processes speech and inserts text into other applications. The
assets worth protecting are the audio, the transcripts derived from it, and the
privileged capabilities the application holds.

### Trust boundaries

| Boundary | Description |
|---|---|
| Microphone | Audio is captured only while the push-to-talk key is held or a session is explicitly started. |
| Accessibility | Grants the ability to observe global key events and to read and write the focused element of other processes. |
| Filesystem | Reads user-selected media files; writes only to its own Application Support directory. |
| Network | One outbound path only: downloading Parakeet models, if that engine is selected. No user content is transmitted by any code path. |

### Design decisions

**No user content leaves the device.** Transcription, correction, summarisation
and vocabulary learning all run on-device. The single outbound request the
application can make is the optional Parakeet model download, which carries no
user data; the default engine makes none. `SummaryService` and `CorrectionSuggester` bind to
`SystemLanguageModel` and never reference `PrivateCloudComputeLanguageModel`,
which would transmit input to Apple's servers. The on-device guarantee is
enforced by the types used, not by configuration.

**Hardened Runtime, minimal entitlements.** Builds are signed with the Hardened
Runtime enabled. The entitlement set is a single entry,
`com.apple.security.device.audio-input`. There is no JIT entitlement, no
unsigned-executable-memory entitlement, no library-validation exemption and no
debugger entitlement.

**The App Sandbox is not enabled.** The application's primary function requires
the Accessibility API to read the focused element of another process and insert
text into it, which a sandboxed process cannot do. This is the same constraint
that applies to text expanders, window managers and clipboard utilities. The
trade-off is stated explicitly rather than worked around.

**Event tap is listen-only.** The global hotkey uses a `listenOnly` `CGEventTap`.
Events are observed, never consumed or modified, so the chosen modifier
continues to behave normally in every other application.

**The clipboard is restored.** When text is inserted via the pasteboard, the
previous contents are captured and restored afterwards. When no editable target
has focus, the text is left on the pasteboard and reported, rather than
synthesising a keystroke into an unknown destination.

**Deletion is reversible.** Source media is moved to the Trash via
`NSWorkspace.recycle`, never unlinked. Transcripts retain the unmodified
recogniser output in `raw`, so corrections and cleanup are always recoverable.

### Known limitations

- Accessibility permission is broad by construction. It is granted to the
  application as a whole; macOS provides no narrower scope.
- Ad-hoc signed builds are not verifiable by third parties. The signature
  establishes only that the bundle has not changed since it was built on that
  machine; it says nothing about who built it.
- Dictionary and history files are stored unencrypted under Application Support,
  protected by the user's account and FileVault where enabled. Encrypting them
  separately would prevent the documented workflow of editing the dictionary by
  hand.
