/* Things more than one control does: the top bar's button, Ctrl+O and a drop
   on the window all start the same file job. */
import { open } from "@tauri-apps/plugin-dialog";
import { api } from "./api";
import { ui } from "./state.svelte";

/* What the decoder reads: Media Foundation's audio and video containers. */
export const MEDIA = [
  "mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "ogg", "opus", "wma",
  "mp4", "m4v", "mov", "mkv", "webm", "avi", "wmv",
];

export const isMedia = (path: string) =>
  MEDIA.includes(path.split(".").pop()?.toLowerCase() ?? "");

export async function transcribe(path: string) {
  ui.section = "transcripts";
  ui.openTranscript = null;
  await api.transcribeFile(path);
}

export async function pickRecording() {
  const path = await open({
    title: "Transcribe a Recording",
    multiple: false,
    directory: false,
    filters: [{ name: "Audio and video", extensions: MEDIA }],
  });
  if (typeof path === "string") await transcribe(path);
}
