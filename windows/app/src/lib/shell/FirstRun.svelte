<script lang="ts">
  /* The first launch, while Parakeet comes down and loads. Nothing in the
     window works until it has: every transcript, recording and meeting goes
     through that model. So instead of a percentage tucked into the record
     bar, the window says plainly what is happening, how much, and that it
     happens once.

     Shown only when this launch has had to download. A normal launch loads
     the model in seconds, behind the record bar's "Loading model…", as
     before. Once the model is ready the screen says so, shows the key to
     hold, and steps aside.

     The caption strip stays above it, so the window can still be moved,
     minimised or closed while it waits. */
  import Button from "../ui/Button.svelte";
  import Keycap from "../ui/Keycap.svelte";
  import ProgressBar from "../ui/ProgressBar.svelte";
  import { api } from "../api";
  import { core } from "../state.svelte";
  import { HOTKEY_LABELS } from "../types";

  interface Props {
    /* Whether the screen is up, for the window to make what is under it
       unreachable by keyboard. */
    showing?: boolean;
  }

  let { showing = $bindable(false) }: Props = $props();

  /* How long "Ready" stays before the window comes through. */
  const LINGER = 1600;

  let downloaded = $state(false);
  let leaving = $state(false);
  let gone = $state(false);
  /* The last sizes the download reported, kept for the failure, which
     carries none of its own. */
  let done = $state(0);
  let total = $state(0);
  /* Whether a failure came while loading rather than downloading: the files
     are all here then, and saying the download stopped would be wrong. */
  let loadFailed = $state(false);

  const engine = $derived(core.engine);

  $effect(() => {
    if (engine.kind === "downloading") {
      downloaded = true;
      done = engine.done;
      total = engine.total;
      loadFailed = false;
    } else if (engine.kind === "loading") {
      loadFailed = true;
    }
  });

  $effect(() => {
    if (!downloaded || engine.kind !== "ready" || leaving) return;
    const timer = setTimeout(() => (leaving = true), LINGER);
    return () => clearTimeout(timer);
  });

  $effect(() => {
    showing = downloaded && !gone;
  });

  const megabytes = (bytes: number) => (bytes / 1e6).toFixed(1);
  const percent = $derived(engine.kind === "downloading" ? engine.percent : 0);
  const key = $derived(HOTKEY_LABELS[core.settings?.hotkey ?? "rightControl"]);
  const verb = $derived(core.settings?.triggerMode === "toggle" ? "Tap" : "Hold");

  /* The eyebrow counts the three steps the way the setup counts its own. */
  const step = $derived.by(() => {
    switch (engine.kind) {
      case "loading":
        return { number: "00:02", label: "loading" };
      case "ready":
        return { number: "00:03", label: "ready" };
      case "failed":
        return { number: "00:01", label: "stopped" };
      default:
        return { number: "00:01", label: "downloading" };
    }
  });

  const retry = () => api.retryEngine().catch(() => {});
</script>

{#if downloaded && !gone}
  <section
    class="first-run"
    class:leaving
    aria-live="polite"
    aria-busy={engine.kind === "downloading" || engine.kind === "loading"}
    onanimationend={(event) => {
      if (event.animationName.endsWith("leave")) gone = true;
    }}
  >
    <div class="column">
      <p class="eyebrow" class:failed={engine.kind === "failed"}>
        <b>{step.number}</b>
        <span class="rule"></span>
        <em>{step.label}</em>
      </p>

      {#if engine.kind === "ready"}
        <h1>Ready.</h1>
        <p class="lede">
          {verb} <Keycap label={key} /> and speak. The words go wherever the cursor is.
        </p>
      {:else if engine.kind === "loading"}
        <h1>Loading the speech model.</h1>
        <p class="lede">A few seconds. The download was the slow part, and it is done.</p>
      {:else if engine.kind === "failed"}
        <h1>{loadFailed ? "The model would not load." : "The download stopped."}</h1>
        <p class="lede">{engine.message}</p>
      {:else}
        <h1>Getting the speech model.</h1>
        <p class="lede">
          huh? hears everything on this PC, so the model that listens lives here too. It is
          fetched once, checked, and kept.
        </p>
      {/if}

      <div class="progress">
        {#if engine.kind === "downloading"}
          <ProgressBar value={percent / 100} />
        {:else if engine.kind === "loading"}
          <ProgressBar />
        {:else if engine.kind === "ready"}
          <ProgressBar value={1} />
        {:else}
          <div class="halted">
            <ProgressBar value={loadFailed ? 1 : total ? done / total : 0} />
          </div>
        {/if}
      </div>

      <div class="meta">
        {#if engine.kind === "downloading"}
          <span>{megabytes(engine.done)} of {megabytes(engine.total)} MB</span>
          <span class="number">{engine.percent}%</span>
        {:else if engine.kind === "failed" && loadFailed}
          <span>Parakeet TDT 0.6B v3, downloaded and checked</span>
        {:else if engine.kind === "failed"}
          <span>
            {#if done > 0}{megabytes(done)} MB kept. Trying again carries on from there.{:else}Nothing
              was kept.{/if}
          </span>
        {:else}
          <span>Parakeet TDT 0.6B v3, kept on this PC</span>
        {/if}
      </div>

      {#if engine.kind === "failed"}
        <div class="actions">
          <Button variant="primary" onclick={retry}>Try again</Button>
        </div>
      {/if}
    </div>
  </section>
{/if}

<style>
  /* Over the bars and sections, under the caption strip, whose 32 px it
     leaves uncovered. Taken out of the window's grid: an item placed on it
     pushes the rows it does not name into new ones. */
  .first-run {
    position: absolute;
    inset: 32px 0 0;
    z-index: 5;
    display: flex;
    align-items: center;
    padding: 40px 56px 56px;
    background: var(--base);
    animation: first-run-enter var(--spring-duration) var(--spring);
  }

  .first-run.leaving {
    animation: first-run-leave 250ms var(--quick) forwards;
  }

  @keyframes first-run-enter {
    from { opacity: 0; }
  }

  @keyframes first-run-leave {
    to { opacity: 0; }
  }

  .column {
    width: 100%;
    max-width: 520px;
  }

  /* The signature eyebrow: mono, tracked, the number in the live colour and
     a short hairline after it. */
  .eyebrow {
    display: flex;
    align-items: center;
    gap: 10px;
    margin: 0 0 20px;
    font: var(--mono);
    line-height: 1;
    letter-spacing: 0.08em;
    color: var(--text-tertiary);
  }

  .eyebrow b {
    font-weight: 400;
    color: var(--live);
    font-variant-numeric: tabular-nums;
    transition: color var(--quick-duration) var(--quick);
  }

  .eyebrow.failed b {
    color: var(--danger);
  }

  .eyebrow em {
    font-style: normal;
  }

  .rule {
    flex: 0 0 52px;
    height: 1px;
    background: linear-gradient(90deg, #3a3a3a, transparent);
  }

  h1 {
    margin: 0 0 0 -2px;
    font-size: 44px;
    font-weight: 600;
    line-height: 0.98;
    letter-spacing: -0.045em;
    color: var(--text-primary);
    text-wrap: balance;
  }

  .lede {
    margin: 18px 0 0;
    max-width: 46ch;
    font-size: 14px;
    line-height: 1.5;
    color: var(--text-secondary);
    text-wrap: pretty;
  }

  .progress {
    margin-top: 32px;
  }

  /* Where a failed download got to, in grey: the live colour would say it
     is still moving. */
  .halted :global(.fill) {
    background: var(--text-tertiary);
  }

  .meta {
    display: flex;
    justify-content: space-between;
    gap: 16px;
    margin-top: 12px;
    font: var(--mono);
    color: var(--text-tertiary);
    font-variant-numeric: tabular-nums;
  }

  .number {
    color: var(--text-secondary);
  }

  .actions {
    display: flex;
    gap: 8px;
    margin-top: 24px;
  }
</style>
