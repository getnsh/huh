/* The Settings window's state: the core's latest word on the settings and on
   the machine, held once and read by every group.

   The core owns settings.json. This is a copy that moves the moment a control
   does, as the Mac's @Published properties move, and then defers to the core
   again once nothing it sent is still on the way there. */
import { api, on } from "../lib/api";
import type { AudioInput, EngineStatus, SessionState, Settings } from "../lib/types";

export const page = $state({
  settings: null as Settings | null,
  engine: { kind: "waiting" } as EngineStatus,
  input: null as AudioInput | null,
  /* Whether Windows will start the app at sign-in, read from Windows itself
     and never from settings.json: the Mac reads SMAppService for the same
     reason, so a change made in Windows' own Startup apps page cannot leave
     the switch saying something untrue. */
  launch: null as boolean | null,
  launchFailure: null as string | null,
  /* Only for the line under "Notice when a call starts". */
  session: null as SessionState | null,
});

/* Writes sent and not yet answered. The core echoes every write as a
   "settings" event, and an echo of an earlier write arriving after a later
   change would flick a switch back for a moment, so echoes are let through
   only when nothing of ours is in flight. */
let writing = 0;
let launching = false;

/* One setting changed: shown at once, then sent whole, which is the shape
   set_settings takes. A refusal hands the switch back to the core's word. */
export function change<K extends keyof Settings>(key: K, value: Settings[K]) {
  const current = page.settings;
  if (!current || current[key] === value) return;
  const next = $state.snapshot(current) as Settings;
  next[key] = value;
  page.settings = next;
  writing += 1;
  api
    .setSettings(next)
    .catch(() =>
      api.settings().then((settled) => {
        if (writing === 1) page.settings = settled;
      }),
    )
    .catch(() => {})
    .finally(() => {
      writing -= 1;
    });
}

/* Start at sign-in. The switch moves at once; whatever happens, it then shows
   what Windows holds, as the Mac refreshes the login item's status after
   every attempt. A failure is said in the status line until the next try. */
export async function setLaunch(enabled: boolean) {
  page.launchFailure = null;
  page.launch = enabled;
  launching = true;
  try {
    await api.setLaunchAtLogin(enabled);
  } catch (error) {
    page.launchFailure = describe(error);
  }
  launching = false;
  await readLaunch();
}

export function checkInput() {
  api
    .audioInput()
    .then((input) => (page.input = input))
    .catch(() => {});
}

async function readLaunch() {
  try {
    page.launch = await api.launchAtLogin();
  } catch {
    page.launch = null;
  }
}

function describe(error: unknown): string {
  if (typeof error === "string") return error;
  if (error instanceof Error) return error.message;
  return String(error);
}

/* Reads everything once and keeps it current. Returns the unsubscribe. */
export function connect(): () => void {
  api
    .settings()
    .then((settings) => {
      if (writing === 0) page.settings = settings;
    })
    .catch(() => {});
  api
    .engineStatus()
    .then((status) => (page.engine = status))
    .catch(() => {});
  api
    .session()
    .then((session) => (page.session = session))
    .catch(() => {});
  checkInput();
  readLaunch();

  /* The Mac looks at the microphone again whenever the app comes forward, for
     the headset paired while something else had focus. The sign-in setting is
     read again too, because Windows' Startup apps page can change it while
     this window is behind another. */
  const refocus = () => {
    checkInput();
    if (!launching) readLaunch();
  };
  window.addEventListener("focus", refocus);

  const stops = [
    on("settings", (settings) => {
      if (writing === 0) page.settings = settings;
    }),
    on("engine", (status) => (page.engine = status)),
    on("audio-input", (input) => (page.input = input)),
    on("session", (session) => (page.session = session)),
  ];

  return () => {
    window.removeEventListener("focus", refocus);
    stops.forEach((stop) => stop());
  };
}
