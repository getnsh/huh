<script lang="ts">
  /* The overlay: a pill at the bottom centre, above whatever has focus.
     Every number here is the Mac's. The press pop is keyframed to 0.955 over
     90 ms and back to 1 over 360 ms; the bloom is a 1.5 px ring at 60 % of the
     live colour scaling 0.97 to 1.16 over 620 ms. */
  import { listen } from "@tauri-apps/api/event";
  import LevelMeter from "./lib/LevelMeter.svelte";

  type State =
    | { kind: "idle" }
    | { kind: "starting" }
    | { kind: "listening" }
    | { kind: "transcribing" }
    | { kind: "failed"; message: string };

  // Cast rather than a generic call: `$state<T>()` is a rune, not a function,
  // so it takes no type arguments, and without the cast the initial literal
  // narrows the variable to one branch of the union, which then rejects every
  // other state it will actually be set to.
  let phase = $state({ kind: "idle" } as State);
  let history: number[] = $state([]);
  let partial: string = $state("");
  let confirmation: string | null = $state(null);
  let presses: number = $state(0);

  const listening = $derived(phase.kind === "listening" || phase.kind === "starting");
  const expanded = $derived(partial.length > 0 && confirmation === null);

  $effect(() => {
    const stops = [
      listen<State>("dictation", (event) => {
        const previous = phase.kind;
        phase = event.payload;
        if (phase.kind === "listening" && previous !== "listening") presses += 1;
      }),
      listen<number[]>("levels", (event) => (history = event.payload)),
      listen<string>("partial", (event) => (partial = event.payload)),
      listen<string>("delivered", (event) => {
        confirmation = event.payload;
        setTimeout(() => (confirmation = null), 1400);
      }),
    ];
    return () => stops.forEach((stop) => stop.then((off) => off()));
  });

  const caption = $derived.by(() => {
    switch (phase.kind) {
      case "starting":
        return "Starting…";
      case "listening":
        return expanded ? "" : "Listening";
      case "transcribing":
        return "Transcribing…";
      case "failed":
        return phase.message;
      default:
        return "Hold. Speak. It's typed.";
    }
  });
</script>

<div class="stage">
  <div
    class="pill"
    class:expanded
    class:listening
    style="--press: {presses}"
  >
    {#key presses}
      <span class="bloom"></span>
    {/key}

    <div class="header">
      {#if confirmation}
        <span class="tick">&#10003;</span>
        <span class="confirm">{confirmation}</span>
      {:else}
        <LevelMeter {history} active={listening} />
        <span class="caption" class:live={listening}>{caption}</span>
      {/if}
    </div>

    {#if expanded}
      <p class="partial">{partial}</p>
    {/if}
  </div>
</div>

<style>
  .stage {
    position: fixed;
    inset: 0;
    display: flex;
    align-items: flex-end;
    justify-content: center;
    padding-bottom: 8px;
  }

  .pill {
    position: relative;
    display: flex;
    flex-direction: column;
    gap: 0;
    width: 310px;
    padding: 14px 20px;
    border-radius: var(--radius-hud);
    background: var(--surface);
    border: 1px solid var(--border);
    box-shadow: 0 3px 8px rgb(0 0 0 / 0.3);
    transition:
      width var(--spring-duration) var(--spring),
      padding var(--spring-duration) var(--spring);
    animation: pop 450ms var(--spring);
  }

  .pill.expanded {
    width: 580px;
    gap: 14px;
    padding: 18px 20px;
  }

  /* The pill gives under the press and springs back. */
  @keyframes pop {
    0% { transform: scale(1); }
    20% { transform: scale(0.955); }
    100% { transform: scale(1); }
  }

  /* A ring leaving the pill, once, on the press. */
  .bloom {
    position: absolute;
    inset: 0;
    border-radius: inherit;
    border: 1.5px solid color-mix(in srgb, var(--live) 60%, transparent);
    animation: bloom 620ms var(--quick) forwards;
    pointer-events: none;
  }

  @keyframes bloom {
    from { transform: scale(0.97); opacity: 0.85; }
    to { transform: scale(1.16); opacity: 0; }
  }

  .header {
    display: flex;
    align-items: center;
    gap: 14px;
  }

  .caption {
    font: var(--medium);
    font-size: 12.5px;
    color: var(--text-secondary);
    white-space: nowrap;
    transition: color var(--quick-duration) var(--quick);
  }

  .caption.live {
    color: var(--live);
  }

  .tick {
    color: var(--live);
    font-size: 13px;
  }

  .confirm {
    font: var(--medium);
    color: var(--text-primary);
  }

  .partial {
    margin: 0;
    font-size: 18px;
    line-height: 1.5;
    color: var(--text-primary);
    display: -webkit-box;
    -webkit-line-clamp: 4;
    line-clamp: 4;
    -webkit-box-orient: vertical;
    overflow: hidden;
  }

  @media (prefers-reduced-motion: reduce) {
    .pill { animation: none; }
    .bloom { display: none; }
  }
</style>
