<script lang="ts">
  /* One transcript in the list. A row identifies rather than previews: a
     recording leads with its file name and its shape, dictation with the
     first two lines of what was said. The text itself is read in the open
     transcript, where it scrolls; quoting much of it here would cost layout
     time in proportion to its length and tell little more.

     Only a recording is told apart. A live session wears the microphone and
     leads with its text, as it does on the Mac. The actions arrive under the
     pointer and take their room from the row, so a long line of text gives
     way to them. */
  import ChevronRight from "@lucide/svelte/icons/chevron-right";
  import Chip from "../../lib/ui/Chip.svelte";
  import Icon from "../../lib/ui/Icon.svelte";
  import Truncate from "../../lib/ui/Truncate.svelte";
  import LearningBadge from "./LearningBadge.svelte";
  import SourceIcon from "./SourceIcon.svelte";
  import TranscriptActions from "./TranscriptActions.svelte";
  import { clock, relative, wordCount } from "../../lib/format";
  import { ui } from "../../lib/state.svelte";
  import type { Transcript } from "../../lib/types";
  import { quickFade } from "./motion";

  interface Props {
    transcript: Transcript;
    /* The clock the relative dates are read against. */
    now: number;
  }

  let { transcript, now }: Props = $props();

  let hovered = $state(false);
  let menuOpen = $state(false);

  const isFile = $derived(transcript.source === "file");
  const lit = $derived(hovered || menuOpen);

  function open() {
    ui.openTranscript = transcript.id;
  }

  function keydown(event: KeyboardEvent) {
    // Return on one of the actions inside belongs to that action.
    if (event.target !== event.currentTarget) return;
    if (event.key === "Enter" || event.key === " ") {
      event.preventDefault();
      open();
    }
  }
</script>

<div
  class="card hover-card"
  class:lit
  role="button"
  tabindex="0"
  onclick={open}
  onkeydown={keydown}
  onpointerenter={() => (hovered = true)}
  onpointerleave={() => (hovered = false)}
>
  <span class="glyph" class:file={isFile}>
    <SourceIcon glyph={isFile ? "waveform" : "mic"} size={12} />
  </span>

  <div class="main">
    {#if isFile}
      <span class="name"><Truncate text={transcript.sourceName} mode="middle" /></span>
    {:else}
      <span class="text">{transcript.text}</span>
    {/if}

    <div class="meta">
      <span>{relative(transcript.date, now)}</span>
      <span class="dot">·</span>
      {#if isFile}
        <span>{clock(transcript.duration)}</span>
        <span class="dot">·</span>
      {/if}
      <span>{wordCount(transcript.text)} words</span>
      {#if transcript.segments.length > 0}
        <span class="dot">·</span>
        <span>{transcript.segments.length} lines</span>
      {/if}
      <LearningBadge {transcript} />
      {#if transcript.summary}
        <Chip tint="var(--live)">summarised</Chip>
      {/if}
      {#if transcript.corrections.length > 0}
        <Chip>{transcript.corrections.length} fixed</Chip>
      {/if}
    </div>
  </div>

  <span class="spacer"></span>

  {#if lit}
    <span class="actions" transition:quickFade>
      <TranscriptActions {transcript} bind:menuOpen />
    </span>
  {/if}

  <span class="chevron"><Icon of={ChevronRight} size={13} weight="semibold" /></span>
</div>

<style>
  .card {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 11px 12px;
    min-width: 0;
  }

  /* The hover look, held while the card's menu has the pointer. */
  .card.lit {
    background: var(--hover);
    box-shadow: inset 0 0 0 1px var(--border);
  }

  .glyph {
    flex: 0 0 16px;
    display: grid;
    place-items: center;
    color: var(--text-tertiary);
  }

  .glyph.file {
    color: color-mix(in srgb, var(--live) 80%, transparent);
  }

  .main {
    flex: 0 1 auto;
    min-width: 0;
    display: flex;
    flex-direction: column;
    gap: 3px;
  }

  /* Line heights in this card are the Mac's own leading, 16 pt for 13 pt
     text and 14 pt for 11 pt, which is what makes a card 55 tall, and 60
     with a chip in it, as on the Mac. */
  .name {
    display: block;
    min-width: 0;
    font: var(--medium);
    line-height: 16px;
    color: var(--text-primary);
  }

  /* Two lines at most, cut at the end. A live session's turns are separate
     lines in its text, and stay so. */
  .text {
    display: -webkit-box;
    -webkit-box-orient: vertical;
    -webkit-line-clamp: 2;
    line-clamp: 2;
    overflow: hidden;
    font: var(--body);
    line-height: 16px;
    color: var(--text-primary);
    white-space: pre-wrap;
    overflow-wrap: anywhere;
  }

  .meta {
    display: flex;
    align-items: center;
    gap: 7px;
    min-width: 0;
    overflow: hidden;
    font-size: 11px;
    line-height: 14px;
    color: var(--text-tertiary);
    white-space: nowrap;
  }

  .dot {
    color: color-mix(in srgb, var(--text-tertiary) 60%, transparent);
  }

  .spacer {
    flex: 1 1 8px;
    min-width: 8px;
  }

  .actions {
    display: flex;
    flex: 0 0 auto;
  }

  /* Drawn at the height of the Mac's glyph, and cropped to its width so it
     sits as near the edge as the Mac's does. */
  .chevron {
    flex: 0 0 auto;
    display: grid;
    place-items: center;
    margin: 0 -5.5px;
    color: var(--text-tertiary);
    opacity: 0.45;
    transition: opacity var(--quick-duration) var(--quick);
  }

  .card:hover .chevron,
  .card.lit .chevron {
    opacity: 1;
  }
</style>
