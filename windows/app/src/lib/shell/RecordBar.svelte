<script lang="ts">
  /* The transport bar along the bottom: the meter, what dictation is doing,
     the key to hold, and the two ways to start — a meeting, or dictation.
     When the microphone opens the bar grows, lifts a step on the grey ladder
     and widens its meter, all on the spring, and the words so far run along
     under the status, newest kept. */
  import Mic from "@lucide/svelte/icons/mic";
  import Square from "@lucide/svelte/icons/square";
  import Speech from "@lucide/svelte/icons/speech";
  import CircleStop from "@lucide/svelte/icons/circle-stop";
  import LevelMeter from "../LevelMeter.svelte";
  import Button from "../ui/Button.svelte";
  import Icon from "../ui/Icon.svelte";
  import Keycap from "../ui/Keycap.svelte";
  import Truncate from "../ui/Truncate.svelte";
  import { api } from "../api";
  import { core, isLive } from "../state.svelte";
  import { HOTKEY_LABELS, type SessionState } from "../types";
  import { on } from "../api";

  // Cast, not annotated: a `$state(null)` annotation still narrows to null.
  let session = $state(null as SessionState | null);

  $effect(() => {
    api.session().then((s) => (session = s)).catch(() => {});
    return on("session", (s) => (session = s));
  });

  const live = $derived(isLive());

  const status = $derived.by(() => {
    switch (core.phase.kind) {
      case "starting":
        return "Starting…";
      case "listening":
        return "Listening";
      case "transcribing":
        return "Transcribing…";
      case "failed":
        return core.phase.message;
    }
    // The first launch downloads 670 MB; saying how far along is kinder than
    // the Mac's bare "Loading model…", which never has to wait that long.
    switch (core.engine.kind) {
      case "downloading":
        return `Downloading Parakeet models… ${core.engine.percent}%`;
      case "loading":
      case "waiting":
        return "Loading model…";
      case "failed":
        return core.engine.message;
      default:
        return "Ready";
    }
  });

  const keyLabel = $derived(HOTKEY_LABELS[core.settings?.hotkey ?? "rightControl"]);
  const verb = $derived(core.settings?.triggerMode === "toggle" ? "Tap" : "Hold");
  const sessionRunning = $derived(session?.running ?? false);
</script>

<footer class:live>
  <span class="meter">
    <LevelMeter
      history={core.levels}
      active={live}
      bars={live ? 44 : 22}
      maxHeight={live ? 26 : 16}
    />
  </span>

  <div class="status-column">
    <div class="status-row">
      {#if live}<span class="pulse"></span>{/if}
      <span class="status" class:on={live}>{status}</span>
    </div>
    {#if core.phase.kind === "listening" && core.partial}
      <Truncate text={core.partial} mode="head" class="partial" />
    {/if}
  </div>

  <span class="spacer"></span>

  {#if !live}
    <span class="hint">
      <span class="hold">{verb}</span>
      <Keycap label={keyLabel} />
    </span>
    <span class="credit">made by getnsh with <span class="heart">♥</span></span>
  {/if}

  <Button
    variant="secondary"
    disabled={session?.stopping ?? false}
    title={sessionRunning
      ? "Stop transcribing and save the session"
      : "Transcribe you and your PC until you stop it"}
    onclick={() => api.toggleSession()}
  >
    <Icon of={sessionRunning ? CircleStop : Speech} size={11} weight="semibold" />
    <span>{sessionRunning ? "Stop Meeting" : "Start Meeting"}</span>
  </Button>

  <Button variant="primary" onclick={() => api.toggleDictation()}>
    <span class="dictate">
      <Icon of={live ? Square : Mic} size={10.5} weight="semibold" fill={live} />
      <span>{live ? "Stop" : "Start"}</span>
    </span>
  </Button>
</footer>

<style>
  footer {
    display: flex;
    align-items: center;
    gap: 14px;
    height: 46px;
    padding: 0 16px;
    background: var(--surface);
    box-shadow: inset 0 1px 0 var(--border);
    transition:
      height var(--spring-duration) var(--spring),
      background-color var(--spring-duration) var(--spring);
    min-width: 0;
  }

  footer.live {
    height: 62px;
    background: var(--raised);
  }

  .meter {
    display: flex;
    align-items: center;
  }

  .status-column {
    display: flex;
    flex-direction: column;
    gap: 2px;
    min-width: 0;
    flex: 0 1 auto;
  }

  .status-row {
    display: flex;
    align-items: center;
    gap: 7px;
    min-width: 0;
  }

  .status {
    font: var(--medium);
    font-size: 12.5px;
    color: var(--text-secondary);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    transition: color var(--spring-duration) var(--spring);
  }

  .status.on {
    color: var(--live);
  }

  .status-column :global(.partial) {
    font-size: 12px;
    color: var(--text-tertiary);
    max-width: 360px;
    animation: fade var(--quick-duration) var(--quick);
  }

  /* The Mac's pulse: a slow breath of opacity and size, while live. */
  .pulse {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: var(--live);
    flex: 0 0 auto;
    animation: breathe 0.924s ease-in-out infinite alternate;
  }

  @keyframes breathe {
    from { opacity: 0.55; transform: scale(0.9); }
    to { opacity: 1; transform: scale(1.1); }
  }

  .spacer {
    flex: 1 1 auto;
    min-width: 8px;
  }

  .hint {
    display: flex;
    align-items: center;
    gap: 5px;
    animation: fade var(--spring-duration) var(--spring);
  }

  .hold {
    font-size: 11.5px;
    color: var(--text-tertiary);
  }

  .credit {
    font-size: 9.5px;
    color: color-mix(in srgb, var(--text-tertiary) 60%, transparent);
    white-space: nowrap;
    animation: fade var(--spring-duration) var(--spring);
  }

  .heart {
    color: color-mix(in srgb, var(--danger) 70%, transparent);
  }

  /* The Mac's minimum is on the label, glyph and word together, centred, so
     "Start" and "Stop" swap without the button changing size. */
  .dictate {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    gap: 6px;
    min-width: 46px;
  }

  @keyframes fade {
    from { opacity: 0; }
  }

  @media (max-width: 760px) {
    .credit { display: none; }
  }

  @media (prefers-reduced-motion: reduce) {
    .pulse { animation: none; }
  }
</style>
