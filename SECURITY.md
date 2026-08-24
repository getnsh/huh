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
| Network | Four paths, all opt-in and none carrying user content: the Parakeet model download, the Qwen3 model download, opening ChatGPT or Claude in your browser, and opening a blank Google Doc. The last two put the text on your clipboard and open a tab; the application transmits nothing. No user content is transmitted by any code path. |

### Release integrity

Release downloads are not notarised; the project has no Apple Developer Program
membership. Every release publishes a SHA-256 in its notes and as a
`SHASUMS.txt` asset, and the install instructions ask you to check it *before*
clearing quarantine. Verify it. See
[docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) for the reasoning and the limits of
what a checksum can do.

### Design decisions

**No user content leaves the device.** Transcription, correction, summarisation
and vocabulary learning all run on-device. The application contains no
`URLSession`, no sockets and no subprocess execution; the only outbound
requests it can cause are the two optional model downloads, which carry no user
data, and the default engine makes neither. The two hand-off actions place text
on your clipboard and open a browser tab -- what happens next is yours, and the
application is not part of it.

**Downloaded weights are pinned.** `LocalLanguageModel.modelConfiguration`
names an exact commit rather than a branch, so a force-push or a compromised
upstream account cannot silently change the weights that run on your machine.
The Parakeet download, which lives in a dependency, still tracks a branch. `SummaryService` and `CorrectionSuggester` bind to
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

**Two model downloads, no content.** Selecting Parakeet or Qwen3 fetches weights
once. Neither request carries audio, transcripts or dictionary entries. Sending a
transcript to ChatGPT or Claude is a separate, explicitly chosen action: the text
goes to your clipboard and the site opens, so the application transmits nothing
and you see what you are sending.

**The clipboard is restored, and guarded.** Text inserted by the paste path is
marked with the concealed type clipboard managers honour, and the previous
contents are put back only if nothing else has written to the pasteboard in the
meantime — a copy you make during those milliseconds is never overwritten.

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
