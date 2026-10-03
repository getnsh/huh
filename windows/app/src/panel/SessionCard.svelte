<script lang="ts">
  /* The session, opened: who is being heard, what has been said, and the
     controls. Shown while a session runs, and for a while after it ends so the
     transcript can be opened from it.

     The title strip is the handle. The drag stops short of the buttons beside
     it: a gesture covering the whole header would have to decide between
     moving the panel and pressing Stop, and getting that wrong ends a
     recording. */
  import TriangleAlert from "@lucide/svelte/icons/triangle-alert";
  import Button from "../lib/ui/Button.svelte";
  import ElapsedLabel from "../lib/ui/ElapsedLabel.svelte";
  import Icon from "../lib/ui/Icon.svelte";
  import PulsingDot from "../lib/ui/PulsingDot.svelte";
  import Spinner from "../lib/ui/Spinner.svelte";
  import VoiceTrace from "../lib/ui/VoiceTrace.svelte";
  import { api } from "../lib/api";
  import type { SessionLevels, SessionState, Voice } from "../lib/types";
  import Card from "./Card.svelte";
  import LineRow from "./LineRow.svelte";
  import { drift, fade, tail } from "./motion";
  import { movable } from "./movable";

  interface Props {
    session: SessionState;
    levels: SessionLevels;
  }

  let { session, levels }: Props = $props();

  const running = $derived(session.running);

  /* The unsettled tail of each stream, after the settled lines: the room's
     first, then yours. */
  const drafts = $derived.by(() => {
    const out: { voice: Voice; text: string }[] = [];
    if (session.roomDraft) out.push({ voice: "room", text: session.roomDraft });
    if (session.youDraft) out.push({ voice: "you", text: session.youDraft });
    return out;
  });

  /* Derived so that each changes only when it really changes: the core sends
     the whole session every time anything in it moves. */
  const lineCount = $derived(session.lines.length);
  const draftText = $derived(`${session.youDraft}\n${session.roomDraft}`);

  let scroller: HTMLDivElement | undefined = $state(undefined);
  let keeper: ReturnType<typeof tail> | null = null;

  /* Opened at the newest words, not at the top of an hour of them. */
  $effect(() => {
    if (!scroller) return;
    const follower = tail(scroller);
    keeper = follower;
    follower.follow();
    return () => {
      follower.stop();
      if (keeper === follower) keeper = null;
    };
  });

  /* A line landing scrolls to it on the spring; a draft moving keeps up at
     once, which it does too often to animate. */
  let counted = -1;
  $effect(() => {
    const count = lineCount;
    if (counted >= 0 && count !== counted) keeper?.land();
    counted = count;
  });

  $effect(() => {
    void draftText;
    keeper?.follow();
  });

  const stopOrClose = () =>
    (running ? api.toggleSession() : api.dismissPanel()).catch(() => {});
</script>

{#snippet trace(label: string, history: number[], tint: string, hears: boolean, speaking: boolean)}
  <div class="track">
    <span class="voice" style:color={speaking ? tint : null}>{label}</span>
    <!-- A source that never opened is drawn as off rather than as silent: a
         flat line would claim a microphone is listening on a PC that has none. -->
    <span class="signal" class:off={running && !hears}>
      <VoiceTrace {history} active={running && hears} {tint} />
    </span>
  </div>
{/snippet}

<Card width={356}>
  <div class="header">
    <div class="strip" title="Drag to move" use:movable>
      <PulsingDot active={running} size={6} />
      <!-- "Listening" in the past tense would be a lie about a panel that has
           stopped, so a finished session goes by what it was. -->
      <span class="title">{running ? session.label : session.pastLabel}</span>
      <span class="spacer"></span>
      <!-- Frozen once it ends: a counter still climbing on a stopped session
           says it is still recording. -->
      <ElapsedLabel
        since={session.startedAt}
        frozen={running ? null : session.finalDuration}
        tint="var(--text-tertiary)"
      />
    </div>

    <!-- The three glyphs are drawn rather than taken from Lucide, at the sizes
         measured off the Mac's own panel: SF's chevron at 10 pt stands 9 pt
         tall, where Lucide's fills half its box. -->
    <button
      class="round"
      title="Collapse"
      aria-label="Collapse"
      onclick={() => api.setPanelExpanded(false).catch(() => {})}
    >
      <svg class="chevron" viewBox="0 0 5.25 9" aria-hidden="true">
        <path d="M0.875 0.875 4.375 4.5 0.875 8.125" />
      </svg>
    </button>

    <button
      class="round"
      class:stop={running}
      aria-label={running ? "Stop" : "Close"}
      disabled={session.stopping}
      onclick={stopOrClose}
    >
      {#if running}
        <span class="square"></span>
      {:else}
        <svg class="cross" viewBox="0 0 7.25 7.25" aria-hidden="true">
          <path d="M0.875 0.875 6.375 6.375M6.375 0.875 0.875 6.375" />
        </svg>
      {/if}
    </button>
  </div>

  <div class="traces">
    {@render trace("You", levels.you, "var(--live)", session.hearsYou, session.youDraft !== "")}
    {@render trace(
      session.roomLabel,
      levels.room,
      "var(--live-soft)",
      session.hearsRoom,
      session.roomDraft !== "",
    )}
  </div>

  <div class="divider"></div>

  <!-- As tall as what it holds, to 300 px, then it scrolls: a long meeting
       must not end up as a panel the height of the screen. -->
  <div class="transcript" bind:this={scroller}>
    <div class="list">
      {#if session.lines.length === 0 && drafts.length === 0}
        <p class="waiting">{running ? "Waiting for the first words…" : "Nothing was heard."}</p>
      {/if}

      {#each session.lines as line (line.id)}
        <div in:drift={{ y: 10 }}>
          <LineRow voice={line.voice} text={line.text} settled />
        </div>
      {/each}

      {#each drafts as draft (draft.voice)}
        <div in:drift={{ y: 10 }}>
          <LineRow voice={draft.voice} text={draft.text} settled={false} />
        </div>
      {/each}

      <!-- Somewhere for the list to rest: scrolled to its end, the last line
           would otherwise sit hard against the bottom edge. -->
      <div class="anchor"></div>
    </div>
  </div>

  {#if session.statusMessage}
    <div class="status" in:fade>
      <span class="warning"><Icon of={TriangleAlert} size={10} fill /></span>
      <p>{session.statusMessage}</p>
    </div>
  {/if}

  {#if session.stopping}
    <div class="row" in:fade>
      <Spinner />
      <span class="finishing">Finishing up…</span>
    </div>
  {:else if !running && session.savedTranscript !== null}
    <div class="row" in:drift={{ y: "self" }}>
      <Button variant="primary" onclick={() => api.openSaved().catch(() => {})}>
        Open transcript
      </Button>
    </div>
  {/if}
</Card>

<style>
  .header {
    display: flex;
    align-items: center;
    gap: 8px;
    padding-bottom: 12px;
  }

  .strip {
    display: flex;
    align-items: center;
    gap: 8px;
    flex: 1 1 auto;
    min-width: 0;
    touch-action: none;
  }

  .title {
    min-width: 0;
    font: var(--medium);
    color: var(--text-primary);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .spacer {
    flex: 1 1 auto;
    min-width: 6px;
  }

  /* Plain buttons on the Mac: a filled 22 pt circle, no hover. */
  .round {
    flex: 0 0 auto;
    display: grid;
    place-items: center;
    width: 22px;
    height: 22px;
    border-radius: 50%;
    color: var(--text-secondary);
    background: var(--hover);
    transition: opacity var(--quick-duration) var(--quick);
  }

  /* While it runs the button stops it, and says so in the primary inversion:
     the base grey on the light fill. */
  .round.stop {
    color: var(--base);
    background: var(--accent-fill);
  }

  .round:disabled {
    opacity: 0.4;
  }

  .chevron,
  .cross {
    display: block;
    fill: none;
    stroke: currentColor;
    stroke-width: 1.75;
    stroke-linecap: round;
    stroke-linejoin: round;
  }

  .chevron {
    width: 5.25px;
    height: 9px;
  }

  .cross {
    width: 7.25px;
    height: 7.25px;
  }

  .square {
    width: 7.5px;
    height: 7.5px;
    border-radius: 1px;
    background: currentColor;
  }

  .traces {
    display: flex;
    flex-direction: column;
    gap: 10px;
    padding-bottom: 12px;
  }

  .track {
    display: flex;
    align-items: center;
    gap: 10px;
  }

  /* Takes its voice's colour while that voice is mid-sentence. */
  .voice {
    flex: 0 0 74px;
    min-width: 0;
    font: var(--medium);
    font-size: 10px;
    letter-spacing: 0.6px;
    text-transform: uppercase;
    color: var(--text-tertiary);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    transition: color var(--quick-duration) var(--quick);
  }

  .signal {
    display: flex;
    flex: 1 1 auto;
    min-width: 0;
  }

  .signal.off {
    opacity: 0.3;
  }

  .divider {
    height: 1px;
    background: var(--border-soft);
  }

  /* Lines dissolve at the top edge instead of being cut off by it, so the
     panel reads as a window onto something still running. */
  .transcript {
    min-height: 34px;
    max-height: 300px;
    overflow-y: auto;
    overscroll-behavior: contain;
    scrollbar-width: none;
    -webkit-mask-image: linear-gradient(to bottom, transparent 0%, #000 7%, #000 100%);
    mask-image: linear-gradient(to bottom, transparent 0%, #000 7%, #000 100%);
  }

  .transcript::-webkit-scrollbar {
    display: none;
  }

  .list {
    display: flex;
    flex-direction: column;
    gap: 12px;
    padding: 12px 0;
  }

  .waiting {
    margin: 0;
    padding: 10px 0;
    font-size: 12px;
    color: var(--text-tertiary);
  }

  .anchor {
    flex: 0 0 1px;
  }

  .status {
    display: flex;
    align-items: center;
    gap: 7px;
    padding-top: 12px;
  }

  .status p {
    flex: 1 1 auto;
    min-width: 0;
    margin: 0;
    font-size: 11.5px;
    line-height: 14px;
    color: var(--text-tertiary);
  }

  /* exclamationmark.triangle.fill: the mark cut out of a solid triangle, in
     the colour of the card under it. */
  .warning {
    display: grid;
    place-items: center;
    color: var(--warning);
  }

  .warning :global(svg path:not(:first-child)) {
    stroke: var(--surface);
  }

  .row {
    display: flex;
    align-items: center;
    gap: 8px;
    padding-top: 12px;
  }

  .finishing {
    font-size: 12px;
    color: var(--text-secondary);
  }
</style>
