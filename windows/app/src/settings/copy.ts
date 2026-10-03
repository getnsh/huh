/* Every sentence the Settings window says, in one place, so it can be held
   against the Mac's SettingsView line by line.

   Where Windows needs other words, the Mac's sentence is rewritten in its own
   voice rather than translated: a PC for a Mac, sign-in for login, Discord for
   FaceTime, and no mention of a permission Windows never asks for. Everything
   else is the Mac's, character for character, dashes and curly quotes
   included. */
import type { AudioInput, CleanupLevel, EngineStatus, HotKey, InjectionMode, TriggerMode } from "../lib/types";
import { HOTKEY_LABELS } from "../lib/types";

export type Choice<T extends string> = { value: T; label: string };

/* In HOTKEY_LABELS' own order, so the default, Right Ctrl, leads the list as
   Right ⌥ leads the Mac's. */
export const KEYS: Choice<HotKey>[] = (Object.keys(HOTKEY_LABELS) as HotKey[]).map((value) => ({
  value,
  label: HOTKEY_LABELS[value],
}));

export const BEHAVIOURS: Choice<TriggerMode>[] = [
  { value: "hold", label: "Hold to talk" },
  { value: "toggle", label: "Tap to toggle" },
];

export const CLEANUP: Choice<CleanupLevel>[] = [
  { value: "off", label: "Off" },
  { value: "standard", label: "Fillers & stutters" },
  { value: "aggressive", label: "Also hedges" },
];

/* TextCleanup.swift's details, which cleanup.rs carries word for word too. */
export const CLEANUP_DETAIL: Record<CleanupLevel, string> = {
  off: "Keep the transcript exactly as spoken.",
  standard:
    "Drops “uh”, “um”, “erm” and collapses “yeah, yeah, yeah” into one. Conservative — it only removes words that carry no meaning.",
  aggressive:
    "Also drops hedges: “you know”, “I mean”, “sort of”, “basically”, “actually”. Reads tighter, but it is editing you, not just cleaning you up.",
};

/* The Mac names its mechanism, "Accessibility, then paste". Windows' ladder
   types short text and pastes the rest, so it is named for that. */
export const INSERTION: Choice<InjectionMode>[] = [
  { value: "auto", label: "Type, then paste" },
  { value: "alwaysPaste", label: "Always paste" },
];

export const TEXT = {
  title: "huh? Settings",

  keyNote:
    "The key still works normally in every other app — huh? only listens for it, it never swallows it.",
  /* The hook only listens, so Caps Lock keeps doing what Caps Lock does. The
     note above would be true and still mislead without this. */
  capsLock: "Caps Lock still turns capitals on and off with every press.",

  openMicrophone: "Open Microphone Settings…",
  openSound: "Open Sound Settings…",
  noInputNote:
    "Many desktop PCs have no built-in microphone. Transcribing an existing recording works regardless.",

  hearsPC: "Your PC as well as you",
  hearsPCDetail: "Hold the key over a video or a call and both get transcribed.",
  notice: "Notice when a call starts",
  startsOwn: "Start listening on its own",
  startsOwnOn: "A call starts and huh? begins transcribing it without asking.",
  startsOwnOff: "A call starts and huh? asks first. Nothing is recorded until you say so.",
  spotting:
    "Spotting a call means reading the list of processes using audio, nothing more: no screen, no window titles, no browser tabs. Capturing what the PC plays needs no permission on Windows.",
  consent:
    "Recording a conversation is your call to make. In some places everyone on it has to be told first.",

  engine: "Parakeet TDT (CPU)",
  /* The Mac's Parakeet note, less its last sentence: word timings for
     speaker attribution are a promise Windows does not keep yet. */
  engineNote:
    "Downloads about 670 MB from the model registry the first time huh? starts, then runs entirely offline.",

  startAtSignIn: "Start at sign-in",

  feedbackSounds: "Feedback sounds",
  insertionNote:
    "Short text is typed, which leaves the clipboard alone; longer text is pasted and the clipboard put back afterwards. Windows won't let either reach an app running as administrator.",
} as const;

/* The microphone line. The Mac's two sentences, and between them what Windows
   adds: a microphone that is there and still cannot be heard, which says why
   in the core's own words. */
export function microphoneText(input: AudioInput): string {
  if (!input.hasInput) return "No audio input device is connected.";
  if (input.problem) return input.problem;
  return `Input: ${input.name ?? "Windows default"}`;
}

/* The recogniser, in the words the Mac's Settings uses for Parakeet while it
   prepares. */
export function engineText(status: EngineStatus): string {
  switch (status.kind) {
    case "ready":
      return "Model loaded and warm";
    case "downloading":
      return `Downloading Parakeet models… ${status.percent}%`;
    case "loading":
      return "Preparing Parakeet…";
    case "failed":
      return status.message;
    case "waiting":
      return "Loading…";
  }
}

/* Under "Notice when a call starts": off, a call in progress, or the apps it
   listens for. Windows has no FaceTime, so Discord takes its place. */
export function callText(watching: boolean, app: string | null): string {
  if (!watching) return "Calls are ignored.";
  if (app) return `A ${app} call is running right now.`;
  return "Google Meet, Slack, Zoom, Teams, Discord. No call right now.";
}

export function launchText(enabled: boolean): string {
  return enabled
    ? "huh? starts automatically when you sign in."
    : "The push-to-talk key only works while huh? is running.";
}
