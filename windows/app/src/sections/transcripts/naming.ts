/* What a transcript is called, and the glyph that goes with the name. */
import type { Transcript } from "../../lib/types";

/* A recording carries its file name and a session what it was listening to;
   dictation has neither and is named for what it is. */
export function displayName(transcript: Transcript): string {
  switch (transcript.source) {
    case "file":
      return transcript.sourceName;
    case "meeting":
      return transcript.sourceName || "Live session";
    default:
      return "Dictation";
  }
}

export type Glyph = "waveform" | "mic" | "meeting";

/* The Mac's `listSymbol`, used where a transcript is named: search results. */
export function listSymbol(transcript: Transcript): Glyph {
  switch (transcript.source) {
    case "file":
      return "waveform";
    case "meeting":
      return "meeting";
    default:
      return "mic";
  }
}
