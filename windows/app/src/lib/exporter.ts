/* Every way a transcript leaves the app: copied as plain text or with its
   timestamps, copied as rich text, handed to Google Docs, or saved in one of
   five formats. The formats are the Mac's TranscriptExporter, character for
   character, so a file exported on either platform reads the same anywhere.

   Google Docs is reached the way the Mac reaches it: rich text on the
   clipboard and a blank document opened in the browser. No Drive API, no
   sign-in, no consent screen, and the same formatted result once pasted. */
import { save as chooseDestination } from "@tauri-apps/plugin-dialog";
import { openUrl } from "@tauri-apps/plugin-opener";
import { api } from "./api";
import { clock, counted, mediumDateTime, timecode, wordCount } from "./format";
import type { Transcript } from "./types";

export type Format = "plain" | "timestamped" | "markdown" | "srt" | "vtt";

export type FormatSpec = { id: Format; title: string; extension: string };

export const FORMATS: readonly FormatSpec[] = [
  { id: "plain", title: "Plain Text", extension: "txt" },
  { id: "timestamped", title: "With Timestamps", extension: "txt" },
  { id: "markdown", title: "Markdown", extension: "md" },
  { id: "srt", title: "Subtitles (.srt)", extension: "srt" },
  { id: "vtt", title: "WebVTT (.vtt)", extension: "vtt" },
];

/* Plain text and Markdown suit anything. The rest are timelines, and a
   dictation has none. */
export const formatsFor = (transcript: Transcript) =>
  FORMATS.filter(
    (format) => format.id === "plain" || format.id === "markdown" || transcript.segments.length > 0,
  );

/* ── Labels ──────────────────────────────────────────────────────────────── */

/* A recording is called by its file name, without the extension. Everything
   else is called "Dictation", a live session included, as on the Mac. */
export function title(transcript: Transcript): string {
  if (transcript.source === "file" && transcript.sourceName) {
    const dot = transcript.sourceName.lastIndexOf(".");
    return dot > 0 ? transcript.sourceName.slice(0, dot) : transcript.sourceName;
  }
  return "Dictation";
}

export function subtitle(transcript: Transcript): string {
  const parts = [mediumDateTime(transcript.date)];
  if (transcript.duration > 0) parts.push(clock(transcript.duration));
  parts.push(`${wordCount(transcript.text)} words`);
  if (transcript.corrections.length > 0) {
    parts.push(counted(transcript.corrections.length, "dictionary correction"));
  }
  parts.push("transcribed on-device by huh?");
  return parts.join(" · ");
}

/* The Mac swaps only "/"; Windows refuses eight more characters in a name. */
export function suggestedFilename(transcript: Transcript): string {
  const safe = title(transcript).replace(/[/\\:*?"<>|]/g, "-");
  return safe || "transcript";
}

/* ── Text ────────────────────────────────────────────────────────────────── */

export function exportString(transcript: Transcript, format: Format): string {
  const segments = transcript.segments;

  switch (format) {
    case "plain":
      return transcript.text;

    case "timestamped":
      if (segments.length === 0) return transcript.text;
      return segments.map((segment) => `[${timecode(segment.start)}]  ${segment.text}`).join("\n");

    case "markdown": {
      let out = `# ${title(transcript)}\n\n`;
      out += `*${subtitle(transcript)}*\n\n`;
      if (segments.length === 0) {
        out += transcript.text + "\n";
      } else {
        for (const segment of segments) out += `**${timecode(segment.start)}** ${segment.text}\n\n`;
      }
      if (transcript.corrections.length > 0) {
        out += "\n---\n\n## Dictionary changes\n\n";
        for (const correction of transcript.corrections) {
          out += `- \`${correction.matched}\` → **${correction.write}**\n`;
        }
      }
      return out;
    }

    case "srt":
      return subtitles(transcript, false);

    case "vtt":
      return subtitles(transcript, true);
  }
}

/* Segments carry a start time only, so each runs until the next begins, and
   the last is given a nominal three seconds. */
function subtitles(transcript: Transcript, webVTT: boolean): string {
  const segments = transcript.segments;
  if (segments.length === 0) return transcript.text;

  let out = webVTT ? "WEBVTT\n\n" : "";
  segments.forEach((segment, index) => {
    const end = index + 1 < segments.length ? segments[index + 1].start : segment.start + 3;
    if (!webVTT) out += `${index + 1}\n`;
    out += `${stamp(segment.start, webVTT)} --> ${stamp(end, webVTT)}\n`;
    out += `${segment.text}\n\n`;
  });
  return out;
}

/* Truncated, not rounded, to the millisecond, as `Int(seconds)` is. */
function stamp(seconds: number, webVTT: boolean): string {
  const whole = Math.trunc(seconds);
  const millis = Math.trunc((seconds - whole) * 1000);
  const two = (n: number) => String(n).padStart(2, "0");
  const separator = webVTT ? "." : ",";
  return `${two(Math.floor(whole / 3600))}:${two(Math.floor((whole % 3600) / 60))}:${two(whole % 60)}${separator}${String(millis).padStart(3, "0")}`;
}

/* ── Rich text ───────────────────────────────────────────────────────────── */

const html = (text: string) =>
  text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

/* The Mac's attributed string as HTML, which is what Google Docs and Word
   read from a Windows clipboard: an 18 pt semibold title, an 11 pt grey line
   under it, a blank line, then the text at 12 pt with any timecodes in grey
   monospace. No typeface is named for the text, as the Mac's system font
   means nothing to a document either. */
export function richText(transcript: Transcript): string {
  const paragraph = (style: string, content: string) => `<p style="margin:0;${style}">${content}</p>`;
  const body =
    transcript.segments.length === 0
      ? paragraph("font-size:12pt", html(transcript.text).replace(/\n/g, "<br>"))
      : transcript.segments
          .map((segment) =>
            paragraph(
              "font-size:12pt",
              `<span style="font-family:'Courier New',monospace;font-size:11pt;color:#808080">${timecode(segment.start)}&nbsp;&nbsp;</span>${html(segment.text)}`,
            ),
          )
          .join("");
  return (
    `<meta charset="utf-8">` +
    paragraph("font-size:18pt;font-weight:600", html(title(transcript))) +
    paragraph("font-size:11pt;color:#808080", html(subtitle(transcript))) +
    paragraph("", "<br>") +
    body
  );
}

/* ── Actions ─────────────────────────────────────────────────────────────── */

export async function copy(transcript: Transcript, format: Format): Promise<void> {
  await navigator.clipboard.writeText(exportString(transcript, format));
}

/* Rich and plain together, so pasting into something that takes only text
   behaves normally: the plain half is the timestamped text. */
export async function copyRich(transcript: Transcript): Promise<void> {
  const item = new ClipboardItem({
    "text/html": new Blob([richText(transcript)], { type: "text/html" }),
    "text/plain": new Blob([exportString(transcript, "timestamped")], { type: "text/plain" }),
  });
  await navigator.clipboard.write([item]);
}

export async function sendToGoogleDocs(transcript: Transcript): Promise<void> {
  await copyRich(transcript);
  await openUrl("https://docs.new");
}

/* Asks where, then writes UTF-8 with the Mac's line endings. Cancelling the
   dialog is not an error. */
export async function save(transcript: Transcript, format: Format): Promise<void> {
  const spec = FORMATS.find((candidate) => candidate.id === format) ?? FORMATS[0];
  const path = await chooseDestination({
    title: "Export Transcript",
    defaultPath: `${suggestedFilename(transcript)}.${spec.extension}`,
    filters: [{ name: spec.title, extensions: [spec.extension] }],
  });
  if (!path) return;
  await api.writeExport(path, exportString(transcript, format));
}
