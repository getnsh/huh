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

  /* What the core reports once the text has gone, or could not go. */
  type Delivery = { label: string; delivered: boolean };

  /* The Mac shows four lines of the words so far. */
  const LINES = 4;

  // Cast rather than a generic call: `$state<T>()` is a rune, not a function,
  // so it takes no type arguments, and without the cast the initial literal
  // narrows the variable to one branch of the union, which then rejects every
  // other state it will actually be set to.
  let phase = $state({ kind: "idle" } as State);
  let history: number[] = $state([]);
  let partial: string = $state("");
  let fitted: string = $state("");
  let confirmation: Delivery | null = $state(null);
  let presses: number = $state(0);
  let shown: boolean = $state(false);
  let measure: HTMLParagraphElement | undefined = $state(undefined);

  const listening = $derived(phase.kind === "listening" || phase.kind === "starting");
  const expanded = $derived(partial.length > 0 && confirmation === null);

  $effect(() => {
    const stops = [
      listen<State>("dictation", (event) => {
        const previous = phase.kind;
        phase = event.payload;
        // The pop belongs to the press, so it fires on starting, not when the
        // microphone has finished opening.
        if (phase.kind === "starting" && previous !== "starting") {
          presses += 1;
          partial = "";
          confirmation = null;
        }
      }),
      listen<number[]>("levels", (event) => (history = event.payload)),
      listen<string>("partial", (event) => (partial = event.payload)),
      // Held until the overlay has faded and gone, so the fade-out is the
      // confirmation leaving rather than the caption coming back.
      listen<Delivery>("delivered", (event) => (confirmation = event.payload)),
      listen<boolean>("overlay", (event) => (shown = event.payload)),
    ];
    return () => stops.forEach((stop) => stop.then((off) => off()));
  });

  /* The newest words are the ones that matter while they are being spoken, so
     the Mac truncates the head: the last four lines show, behind an ellipsis.
     CSS can only clamp the tail, so the words are fitted here instead, against
     a hidden copy of the text at the expanded width. */
  $effect(() => {
    const text = partial;
    if (!measure || !text) {
      fitted = text;
      return;
    }
    const limit = parseFloat(getComputedStyle(measure).lineHeight) * LINES + 1;
    measure.textContent = text;
    if (measure.scrollHeight <= limit) {
      fitted = text;
      return;
    }
    const words = text.replace(/^…/, "").split(/\s+/);
    // The fewest words that can be dropped from the front and still fit.
    let low = 1;
    let high = words.length - 1;
    while (low < high) {
      const middle = (low + high) >> 1;
      measure.textContent = "…" + words.slice(middle).join(" ");
      if (measure.scrollHeight <= limit) high = middle;
      else low = middle + 1;
    }
    fitted = "…" + words.slice(low).join(" ");
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

<div class="stage" class:shown>
  <!-- Keyed on the press, so the pop and the bloom both play on every one. A
       CSS animation runs when its element is created, and the overlay is
       created once, hidden, at launch. -->
  {#key presses}
  <div
    class="pill"
    class:expanded
    class:listening
  >
    <span class="bloom"></span>

    <div class="header">
      {#if confirmation}
        <span class="confirmation">
          {#if confirmation.delivered}
            <svg class="check" viewBox="0 0 16 16" aria-hidden="true">
              <circle cx="8" cy="8" r="8" />
              <path d="M4.7 8.2l2.2 2.2 4.4-4.6" />
            </svg>
          {/if}
          <span class="confirm">{confirmation.label}</span>
        </span>
      {:else if phase.kind === "failed"}
        <!-- No meter: a failure needs the width, and nothing is listening. -->
        <span class="caption wraps">{caption}</span>
      {:else}
        <LevelMeter {history} active={listening} />
        <span class="caption" class:live={listening}>{caption}</span>
        {#if phase.kind === "transcribing"}
          <span class="spinner" aria-hidden="true"></span>
        {/if}
      {/if}
    </div>

    {#if expanded}
      <p class="partial">{fitted}</p>
    {/if}
  </div>
  {/key}

  <!-- The ruler the words are fitted against. -->
  <p class="partial ruler" bind:this={measure} aria-hidden="true"></p>
</div>

<style>
  /* The window is shown and hidden by the core; the page fades with it, in
     over 0.10 s and out over 0.20 s, the Mac's two figures. */
  .stage {
    position: fixed;
    inset: 0;
    display: flex;
    align-items: flex-end;
    justify-content: center;
    padding-bottom: 8px;
    opacity: 0;
    transition: opacity 200ms var(--quick);
  }

  .stage.shown {
    opacity: 1;
    transition-duration: 100ms;
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
      padding var(--spring-duration) var(--spring),
      gap var(--spring-duration) var(--spring);
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
    min-height: 26px;
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

  .caption.wraps {
    white-space: normal;
    line-height: 1.4;
  }

  /* The Mac's small progress wheel, at the end of the row, while the words
     are being worked out. */
  .spinner {
    margin-left: auto;
    width: 13px;
    height: 13px;
    border-radius: 50%;
    border: 1.5px solid color-mix(in srgb, var(--text-secondary) 28%, transparent);
    border-top-color: var(--text-secondary);
    animation: turn 0.8s linear infinite;
  }

  @keyframes turn {
    to { transform: rotate(1turn); }
  }

  .confirmation {
    display: flex;
    align-items: center;
    gap: 10px;
    animation: settle var(--spring-duration) var(--spring);
  }

  @keyframes settle {
    from { opacity: 0; transform: scale(0.96); }
  }

  .check {
    width: 13px;
    height: 13px;
    flex: 0 0 auto;
  }

  .check circle {
    fill: var(--live);
  }

  .check path {
    fill: none;
    stroke: var(--surface);
    stroke-width: 1.7;
    stroke-linecap: round;
    stroke-linejoin: round;
  }

  .confirm {
    font: var(--medium);
    color: var(--text-primary);
  }

  /* 18 pt with 3 pt between lines, as on the Mac. */
  .partial {
    margin: 0;
    font-size: 18px;
    line-height: calc(1.2em + 3px);
    color: var(--text-primary);
    overflow-wrap: anywhere;
    animation: arrive var(--spring-duration) var(--spring);
  }

  @keyframes arrive {
    from { opacity: 0; transform: translateY(-6px); }
  }

  /* The same type at the expanded pill's inner width, out of sight. */
  .ruler {
    position: absolute;
    visibility: hidden;
    pointer-events: none;
    width: 540px;
    animation: none;
  }

  @media (prefers-reduced-motion: reduce) {
    .pill,
    .confirmation,
    .partial { animation: none; }
    .bloom { display: none; }
    .stage { transition: none; }
    /* Still, not slower: a wheel that has stopped still says "working". */
    .spinner { animation: none; }
  }
</style>
