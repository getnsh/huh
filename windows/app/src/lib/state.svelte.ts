/* The main window's state, held once and read by every view, as the Mac's
   UIState is. The core is the source of truth; this is its latest word plus
   the few things that belong to the window alone: which section is showing,
   what is typed in the search field, which transcript is open. */
import { api, on } from "./api";
import type {
  AudioInput,
  DictationState,
  DictionaryState,
  EngineStatus,
  FileJob,
  LearningState,
  Settings,
  Suggestions,
  SummaryModel,
  SummaryState,
  Transcript,
  Uuid,
} from "./types";

export type Section = "transcripts" | "dictionary";
export type DictionaryTab = "words" | "corrections" | "people";

/* What the editor sheet is asked to open with. */
export type EditorRequest =
  | { mode: "word"; id?: Uuid; text?: string; note?: string }
  | { mode: "correction"; id?: Uuid; hear?: string; write?: string; context?: string; hitCount?: number; enabled?: boolean }
  | { mode: "person"; id?: Uuid; name?: string; aliases?: string; note?: string };

export const ui = $state({
  section: "transcripts" as Section,
  tab: "words" as DictionaryTab,
  transcriptQuery: "",
  dictionaryQuery: "",
  openTranscript: null as Uuid | null,
  editor: null as EditorRequest | null,
  /* Session-only: the IntelligenceNotice stays once asked for. */
  askedForModel: false,
});

export const core = $state({
  phase: { kind: "idle" } as DictationState,
  engine: { kind: "waiting" } as EngineStatus,
  levels: [] as number[],
  partial: "",
  history: [] as Transcript[],
  settings: null as Settings | null,
  dictionary: null as DictionaryState | null,
  suggestions: {
    candidates: [],
    nameCandidates: [],
    suppressedCount: 0,
    proposals: [],
    personProposals: [],
  } as Suggestions,
  learning: {
    running: false,
    analysing: null,
    stage: "",
    pending: 0,
    pendingCount: 0,
    result: null,
    ignoredCount: 0,
    lastRunFoundNothing: false,
  } as LearningState,
  fileJob: { kind: "idle" } as FileJob,
  summary: {
    runningFor: null,
    stage: "",
    progress: null,
    streamed: "",
    failure: null,
  } as SummaryState,
  summaryModel: { ready: false, busy: false, text: "" } as SummaryModel,
  input: { hasInput: true, name: null, problem: null } as AudioInput,
});

export const isLive = () => core.phase.kind === "listening" || core.phase.kind === "starting";

/* Reads everything once and keeps it current. Returns the unsubscribe. */
export function connect(): () => void {
  const settle = <T>(promise: Promise<T>, apply: (value: T) => void) =>
    promise.then(apply).catch(() => {});

  settle(api.dictationState(), (v) => (core.phase = v));
  settle(api.engineStatus(), (v) => (core.engine = v));
  settle(api.history(), (v) => (core.history = v));
  settle(api.settings(), (v) => (core.settings = v));
  settle(api.dictionary(), (v) => (core.dictionary = v));
  settle(api.suggestions(), (v) => (core.suggestions = v));
  settle(api.learning(), (v) => (core.learning = v));
  settle(api.fileJob(), (v) => (core.fileJob = v));
  settle(api.summaryState(), (v) => (core.summary = v));
  settle(api.summaryModel(), (v) => (core.summaryModel = v));
  settle(api.audioInput(), (v) => (core.input = v));

  const stops = [
    on("dictation", (v) => {
      core.phase = v;
      if (v.kind === "starting") core.partial = "";
      if (v.kind === "idle") {
        core.partial = "";
        core.levels = [];
      }
    }),
    on("engine", (v) => (core.engine = v)),
    on("levels", (v) => (core.levels = v)),
    on("partial", (v) => (core.partial = v)),
    on("transcript", (t) => (core.history = [t, ...core.history.filter((x) => x.id !== t.id)])),
    on("history", (v) => (core.history = v)),
    on("settings", (v) => (core.settings = v)),
    on("dictionary", (v) => (core.dictionary = v)),
    on("suggestions", (v) => (core.suggestions = v)),
    on("learning", (v) => (core.learning = v)),
    on("file-job", (v) => (core.fileJob = v)),
    on("summary", (v) => (core.summary = v)),
    on("summary-model", (v) => (core.summaryModel = v)),
    on("audio-input", (v) => (core.input = v)),
    on("navigate", (v) => {
      ui.section = v.section;
      if (v.transcript) ui.openTranscript = v.transcript;
      if (v.tab) ui.tab = v.tab as DictionaryTab;
    }),
  ];
  return () => stops.forEach((stop) => stop());
}
