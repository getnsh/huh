/* The shapes the core sends and takes, field for field with huh-core's serde
   output (camelCase). Every screen reads these; none invents its own. */

export type Uuid = string;

/* ── Dictation ──────────────────────────────────────────────────────────── */

export type DictationState =
  | { kind: "idle" }
  | { kind: "starting" }
  | { kind: "listening" }
  | { kind: "transcribing" }
  | { kind: "failed"; message: string };

/* The recogniser: downloading on a first launch, then loading, then ready. */
export type EngineStatus =
  | { kind: "waiting" }
  | { kind: "downloading"; percent: number }
  | { kind: "loading" }
  | { kind: "ready" }
  | { kind: "failed"; message: string };

/* What the overlay confirms once text has gone, or could not go. */
export type Delivery = { label: string; delivered: boolean };

/* ── Transcripts ────────────────────────────────────────────────────────── */

export type TranscriptSource = "dictation" | "file" | "meeting";

export type TranscriptSegment = { id: Uuid; start: number; text: string };

export type AppliedCorrection = { hear: string; id: Uuid; matched: string; write: string };

export type Transcript = {
  analysisFindings: number;
  analyzedAt?: string | null;
  cleanupRemoved: number;
  corrections: AppliedCorrection[];
  date: string;
  duration: number;
  engine: string;
  id: Uuid;
  raw: string;
  segments: TranscriptSegment[];
  source: TranscriptSource;
  sourceName: string;
  sourcePath: string;
  summary: string;
  summaryDate?: string | null;
  text: string;
};

/* ── Dictionary ─────────────────────────────────────────────────────────── */

export type VocabularyTerm = { enabled: boolean; id: Uuid; note: string; text: string };

export type CorrectionPair = {
  enabled: boolean;
  hear: string;
  hitCount: number;
  id: Uuid;
  write: string;
};

export type Person = {
  addedAt: string;
  aliases: string[];
  enabled: boolean;
  id: Uuid;
  learned: boolean;
  name: string;
  note: string;
};

/* Everything the Dictionary section draws, in one read. */
export type DictionaryState = {
  terms: VocabularyTerm[];
  corrections: CorrectionPair[];
  people: Person[];
  loadError: string | null;
  retroNote: string | null;
  dictionaryPath: string;
  peoplePath: string;
  hintCount: number;
  termsWithoutCorrections: number;
  biasOverflow: number;
};

export type Severity = "caution" | "danger";
export type Warning = { message: string; severity: Severity };

/* ── Learning ───────────────────────────────────────────────────────────── */

/* A word heard often and in no dictionary, or a word that looks like a name. */
export type Candidate = { word: string; count: number; isName: boolean };

/* "We heard X; it is probably Y" — a fix to confirm. */
export type Proposal = { heard: string; write: string; context: string; warnings: Warning[] };

/* "We heard X; is that someone's name?" — `name` is the best guess at the
   spelling, which is `heard` itself when there is nothing better. */
export type PersonProposal = {
  heard: string;
  name: string;
  context: string;
  timecode: string | null;
  /* Known spellings this might be, closest first. */
  alternatives: string[];
};

export type Suggestions = {
  candidates: Candidate[];
  nameCandidates: Candidate[];
  suppressedCount: number;
  proposals: Proposal[];
  personProposals: PersonProposal[];
};

export type LearningState = {
  running: boolean;
  analysing: Uuid | null;
  stage: string;
  pending: number;
  pendingCount: number;
  result: string | null;
  ignoredCount: number;
  lastRunFoundNothing: boolean;
};

/* ── Files ──────────────────────────────────────────────────────────────── */

export type FileJob =
  | { kind: "idle" }
  | { kind: "running"; name: string; progress: number; stage: string }
  | { kind: "done"; id: Uuid; name: string; path: string }
  | { kind: "failed"; message: string };

/* ── Summaries ──────────────────────────────────────────────────────────── */

/* The one run there can be at a time. `stage` is ready to show as it is;
   `progress` is a number only while there is something real to measure, and
   null while the model writes; `streamed` is the summary so far. */
export type SummaryState = {
  runningFor: Uuid | null;
  stage: string;
  progress: number | null;
  streamed: string;
  /* The last failure, until it is dismissed or the next run starts. */
  failure: string | null;
};

/* The model that writes them: `busy` while it downloads or loads, `ready`
   once it is in memory, and `text` the sentence Settings shows either way. */
export type SummaryModel = { ready: boolean; busy: boolean; downloaded: boolean; text: string };

/* Named before anything is downloaded, so it lives here rather than in the
   core's sentences. Windows has this one writer and no other. */
export const SUMMARY_MODEL = { name: "Qwen3 4B", size: "2.9 GB" } as const;

/* ── Live sessions ──────────────────────────────────────────────────────── */

export type Voice = "you" | "room";

export type SessionLine = { id: Uuid; voice: Voice; text: string; at: number };

export type SessionState = {
  running: boolean;
  stopping: boolean;
  /* "Listening", or the app the call is in. */
  label: string;
  pastLabel: string;
  roomLabel: string;
  startedAt: string | null;
  finalDuration: number | null;
  hearsYou: boolean;
  hearsRoom: boolean;
  statusMessage: string | null;
  savedTranscript: Uuid | null;
  expanded: boolean;
  visible: boolean;
  offer: string | null;
  /* The call the core can see under way, offered or not. */
  call: string | null;
  lines: SessionLine[];
  youDraft: string;
  roomDraft: string;
};

export type SessionLevels = { you: number[]; room: number[] };

/* ── Settings ───────────────────────────────────────────────────────────── */

export type CleanupLevel = "off" | "standard" | "aggressive";
export type HotKey = "rightControl" | "leftControl" | "rightShift" | "rightAlt" | "capsLock";
export type TriggerMode = "hold" | "toggle";
export type InjectionMode = "auto" | "alwaysPaste";

export type Settings = {
  capturesMeetingsAutomatically: boolean;
  cleanupLevel: CleanupLevel;
  hasAskedLaunchAtLogin: boolean;
  hearsSystemAudio: boolean;
  hotkey: HotKey;
  injectionMode: InjectionMode;
  localeIdentifier: string;
  /* Where the session panel was last dragged to; the core keeps these. */
  panelAnchorX?: number;
  panelAnchorY?: number;
  playFeedbackSounds: boolean;
  startAtLogin: boolean;
  triggerMode: TriggerMode;
  watchesForMeetings: boolean;
};

/* The microphone, as the Settings window and the banners describe it. */
export type AudioInput = { hasInput: boolean; name: string | null; problem: string | null };

export const HOTKEY_LABELS: Record<HotKey, string> = {
  rightControl: "Right Ctrl",
  leftControl: "Left Ctrl",
  rightShift: "Right Shift",
  rightAlt: "Right Alt",
  capsLock: "Caps Lock",
};
