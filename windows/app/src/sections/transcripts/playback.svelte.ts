/* Playback of a recording in step with its timeline: the Mac's
   PlaybackController. Every timecode is a seek target.

   One player for the whole window, held here rather than in a view, so a
   recording keeps playing while the list is browsed or the Dictionary is
   open, as it does on the Mac. The audio element is never put in the page;
   it needs no controls of its own, only the transcript's.

   Only the active line is published, and only when it changes. Publishing
   the time itself would redraw every line of an hour-long timeline several
   times a second. */
import { convertFileSrc } from "@tauri-apps/api/core";
import { untrack } from "svelte";
import { api } from "../../lib/api";
import type { Transcript, Uuid } from "../../lib/types";

export const playback = $state({
  transcriptId: null as Uuid | null,
  isPlaying: false,
  activeSegmentId: null as Uuid | null,
});

/* Whether each recording is still where it was, as last asked. A missing
   original quietly disables playback rather than raising anything: deleting
   it once transcribed is an expected thing to do. */
const present = $state({} as Record<Uuid, boolean>);

let audio: HTMLAudioElement | null = null;
let timeline: { id: Uuid; start: number }[] = [];

/* True or false once known; null while the core is being asked. Only a
   recording ever has an original to play. */
export function playable(transcript: Transcript): boolean | null {
  if (transcript.source !== "file" || !transcript.sourcePath) return false;
  return present[transcript.id] ?? null;
}

/* Asks the core whether the original is still on disk. `again` asks even
   when the answer is already known, as opening a transcript does. */
export async function checkPlayable(transcript: Transcript, again = false): Promise<void> {
  const id = transcript.id;
  if (transcript.source !== "file" || !transcript.sourcePath) return;
  if (!again && untrack(() => present[id]) !== undefined) return;
  try {
    present[id] = await api.isPlayable(id);
  } catch {
    present[id] = false;
  }
}

export function play(transcript: Transcript, start: number): void {
  if (playable(transcript) !== true) return;

  if (playback.transcriptId !== transcript.id || !audio) {
    teardown();
    const element = new Audio(convertFileSrc(transcript.sourcePath));
    element.preload = "auto";
    // Each listener checks it still belongs to the current player: a late
    // event from one that was replaced must not move the new one's state.
    element.addEventListener("timeupdate", () => {
      if (audio === element) tick(element.currentTime);
    });
    element.addEventListener("ended", () => {
      if (audio === element) playback.isPlaying = false;
    });
    // A format WebView2 cannot decode plays nothing, as AVPlayer would.
    element.addEventListener("error", () => {
      if (audio === element) teardown();
    });
    audio = element;
    playback.transcriptId = transcript.id;
    timeline = transcript.segments.map((segment) => ({ id: segment.id, start: segment.start }));
  }

  audio.currentTime = start;
  audio.play().catch(() => {});
  playback.isPlaying = true;
  tick(start);
}

export function toggle(): void {
  if (!audio) return;
  if (playback.isPlaying) {
    audio.pause();
    playback.isPlaying = false;
  } else {
    audio.play().catch(() => {});
    playback.isPlaying = true;
  }
}

export function stop(): void {
  teardown();
}

/* A segment runs until the next begins; the last is given five seconds. A
   scan is enough at four times a second. */
function tick(time: number): void {
  let found: Uuid | null = null;
  for (let index = 0; index < timeline.length; index += 1) {
    const segment = timeline[index];
    const end = index + 1 < timeline.length ? timeline[index + 1].start : segment.start + 5;
    if (time >= segment.start && time < end) {
      found = segment.id;
      break;
    }
  }
  if (found !== playback.activeSegmentId) playback.activeSegmentId = found;
}

function teardown(): void {
  if (audio) {
    audio.pause();
    // Lets go of the file, so it can be moved or recycled while the
    // transcript stays open.
    audio.removeAttribute("src");
    audio.load();
  }
  audio = null;
  timeline = [];
  playback.transcriptId = null;
  playback.isPlaying = false;
  playback.activeSegmentId = null;
}
