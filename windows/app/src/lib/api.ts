/* Every command the interface can send the core, and every event it hears
   back, typed in one place. The interface only draws and asks; the core owns
   every file and every decision, so two windows can never disagree. */
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import type {
  AudioInput,
  CorrectionPair,
  Delivery,
  DictationState,
  DictionaryState,
  EngineStatus,
  FileJob,
  LearningState,
  Person,
  SessionLevels,
  SessionState,
  Voice,
  Settings,
  Suggestions,
  SummaryModel,
  SummaryState,
  Transcript,
  Uuid,
  VocabularyTerm,
  Warning,
} from "./types";

export const api = {
  /* Dictation */
  dictationState: () => invoke<DictationState>("state"),
  engineStatus: () => invoke<EngineStatus>("engine_status"),
  toggleDictation: () => invoke<void>("toggle_dictation"),

  /* Transcripts */
  history: () => invoke<Transcript[]>("get_history"),
  deleteTranscripts: (ids: Uuid[]) => invoke<void>("delete_transcripts", { ids }),
  writeExport: (path: string, contents: string) =>
    invoke<void>("write_export", { path, contents }),
  isPlayable: (id: Uuid) => invoke<boolean>("is_playable", { id }),

  /* Files */
  transcribeFile: (path: string) => invoke<void>("transcribe_file", { path }),
  fileJob: () => invoke<FileJob>("file_job"),
  keepOriginal: () => invoke<void>("keep_original"),
  recycleOriginal: () => invoke<void>("recycle_original"),
  dismissFileFailure: () => invoke<void>("dismiss_file_failure"),

  /* Summaries. `summarise` starts a run, or is turned down in words that can
     be shown as they are: another transcript already being summarised. */
  summarise: (id: Uuid) => invoke<void>("summarise", { id }),
  summaryState: () => invoke<SummaryState>("summary_state"),
  dismissSummaryFailure: () => invoke<void>("dismiss_summary_failure"),
  summaryModel: () => invoke<SummaryModel>("summary_model"),
  unloadSummaryModel: () => invoke<void>("unload_summary_model"),
  /* Copies the meeting and a prompt, and opens the assistant's site. */
  summaryHandoff: (id: Uuid, provider: "chatGPT" | "claude") =>
    invoke<void>("summary_handoff", { id, provider }),

  /* Dictionary */
  dictionary: () => invoke<DictionaryState>("dictionary_state"),
  addTerm: (text: string, note: string) => invoke<void>("add_term", { text, note }),
  updateTerm: (term: VocabularyTerm) => invoke<void>("update_term", { term }),
  setTermEnabled: (id: Uuid, on: boolean) => invoke<void>("set_term_enabled", { id, on }),
  deleteTerm: (id: Uuid) => invoke<void>("delete_term", { id }),
  addCorrection: (hear: string, write: string) => invoke<void>("add_correction", { hear, write }),
  updateCorrection: (pair: CorrectionPair) => invoke<void>("update_correction", { pair }),
  setCorrectionEnabled: (id: Uuid, on: boolean) =>
    invoke<void>("set_correction_enabled", { id, on }),
  deleteCorrection: (id: Uuid) => invoke<void>("delete_correction", { id }),
  addPerson: (name: string, aliases: string[], note: string) =>
    invoke<void>("add_person", { name, aliases, note }),
  updatePerson: (person: Person) => invoke<void>("update_person", { person }),
  setPersonEnabled: (id: Uuid, on: boolean) => invoke<void>("set_person_enabled", { id, on }),
  deletePerson: (id: Uuid) => invoke<void>("delete_person", { id }),
  dismissRetroNote: () => invoke<void>("dismiss_retro_note"),
  checkCorrection: (hear: string, write: string) =>
    invoke<Warning[]>("check_correction", { hear, write }),
  correctionContext: (word: string) => invoke<string>("correction_context", { word }),
  revealFile: (which: "dictionary" | "people") => invoke<void>("reveal_file", { which }),

  /* Learning */
  suggestions: () => invoke<Suggestions>("suggestions"),
  learning: () => invoke<LearningState>("learning_state"),
  runLearning: () => invoke<void>("run_learning"),
  acceptCandidate: (word: string) => invoke<void>("accept_candidate", { word }),
  acceptCandidateAsPerson: (word: string) => invoke<void>("accept_candidate_as_person", { word }),
  dismissCandidate: (word: string) => invoke<void>("dismiss_candidate", { word }),
  resetDismissed: () => invoke<void>("reset_dismissed"),
  acceptProposal: (heard: string) => invoke<void>("accept_proposal", { heard }),
  proposalAsPerson: (heard: string) => invoke<void>("proposal_as_person", { heard }),
  takeProposalForEdit: (heard: string) => invoke<void>("take_proposal_for_edit", { heard }),
  dismissProposal: (heard: string) => invoke<void>("dismiss_proposal", { heard }),
  acceptPersonProposal: (heard: string, name: string) =>
    invoke<void>("accept_person_proposal", { heard, name }),
  dismissPersonProposal: (heard: string) => invoke<void>("dismiss_person_proposal", { heard }),
  restoreDismissed: () => invoke<void>("restore_dismissed"),
  dismissScanResult: () => invoke<void>("dismiss_scan_result"),

  /* Settings and the machine */
  settings: () => invoke<Settings>("get_settings"),
  setSettings: (settings: Settings) => invoke<void>("set_settings", { settings }),
  audioInput: () => invoke<AudioInput>("audio_input"),
  openSettings: () => invoke<void>("open_settings"),
  openSystemSettings: (page: "microphone" | "sound" | "startup") =>
    invoke<void>("open_system_settings", { page }),
  launchAtLogin: () => invoke<boolean>("launch_at_login"),
  setLaunchAtLogin: (on: boolean) => invoke<void>("set_launch_at_login", { on }),

  /* Live sessions */
  session: () => invoke<SessionState>("session_state"),
  toggleSession: () => invoke<void>("toggle_session"),
  setVoicePaused: (voice: Voice, paused: boolean) =>
    invoke<void>("set_voice_paused", { voice, paused }),
  acceptOffer: () => invoke<void>("accept_offer"),
  declineOffer: () => invoke<void>("decline_offer"),
  dismissPanel: () => invoke<void>("dismiss_panel"),
  openSaved: () => invoke<void>("open_saved"),
  setPanelExpanded: (on: boolean) => invoke<void>("set_panel_expanded", { on }),
  /* The panel window is sized to its card: the page measures, the core
     resizes the window around a fixed top-left corner. */
  panelMeasured: (width: number, height: number) =>
    invoke<void>("panel_measured", { width, height }),
  /* A drag on the panel: the core follows the pointer between the two. */
  panelDrag: (phase: "began" | "ended") => invoke<void>("panel_drag", { phase }),
};

/* Events, by name, with what each carries. */
export type Events = {
  dictation: DictationState;
  engine: EngineStatus;
  levels: number[];
  partial: string;
  delivered: Delivery;
  transcript: Transcript;
  history: Transcript[];
  dictionary: DictionaryState;
  suggestions: Suggestions;
  learning: LearningState;
  "file-job": FileJob;
  /* Several times a second while the text streams. */
  summary: SummaryState;
  "summary-model": SummaryModel;
  settings: Settings;
  "audio-input": AudioInput;
  session: SessionState;
  "session-levels": SessionLevels;
  navigate: { section: "transcripts" | "dictionary"; transcript?: Uuid; tab?: string };
};

/* Subscribes and returns the unsubscribe, synchronously, for an $effect. */
export function on<K extends keyof Events>(event: K, handler: (payload: Events[K]) => void) {
  const pending = listen<Events[K]>(event, (message) => handler(message.payload));
  return () => {
    pending.then((off) => off());
  };
}
