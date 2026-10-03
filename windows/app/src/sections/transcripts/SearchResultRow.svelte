<script lang="ts">
  /* One transcript that matched, named, dated, and quoted where it matched.
     A recording's lines carry their time and play from it. Only the name
     opens the transcript, so the quoted lines stay free to be read, and the
     actions stay out, not hidden behind the pointer, because a result is
     usually wanted for something. */
  import Truncate from "../../lib/ui/Truncate.svelte";
  import SourceIcon from "./SourceIcon.svelte";
  import TranscriptActions from "./TranscriptActions.svelte";
  import { shortDateTime } from "../../lib/format";
  import type { Hit } from "../../lib/search";
  import { ui } from "../../lib/state.svelte";
  import { displayName, listSymbol } from "./naming";
  import { checkPlayable, play, playable } from "./playback.svelte";

  let { hit }: { hit: Hit } = $props();

  const transcript = $derived(hit.transcript);
  const timed = $derived(hit.snippets.some((snippet) => snippet.start !== null));
  const canPlay = $derived(playable(transcript));

  $effect(() => {
    if (timed) checkPlayable(transcript);
  });

  function open() {
    ui.transcriptQuery = "";
    ui.openTranscript = transcript.id;
  }
</script>

<div class="row hover-card">
  <div class="head">
    <span class="glyph"><SourceIcon glyph={listSymbol(transcript)} size={10} /></span>
    <button class="name" onclick={open}>
      <Truncate text={displayName(transcript)} mode="middle" />
    </button>
    <span class="spacer"></span>
    <span class="date">{shortDateTime(transcript.date)}</span>
    <TranscriptActions {transcript} />
  </div>

  {#each hit.snippets as snippet}
    <div class="snippet">
      {#if snippet.start !== null && snippet.timecode !== null}
        {@const start = snippet.start}
        <button
          class="time"
          class:playable={canPlay !== false}
          disabled={canPlay !== true}
          onclick={() => play(transcript, start)}>{snippet.timecode}</button
        >
      {/if}
      <p class="quote">{snippet.text}</p>
    </div>
  {/each}
</div>

<style>
  .row {
    display: flex;
    flex-direction: column;
    gap: 8px;
    padding: 12px;
  }

  .head {
    display: flex;
    align-items: center;
    gap: 7px;
    min-width: 0;
  }

  .glyph {
    flex: 0 0 auto;
    color: var(--text-tertiary);
  }

  /* Line heights are the Mac's leading: 15 pt for 12.5 pt text, 14 for 11. */
  .name {
    display: block;
    flex: 0 1 auto;
    min-width: 0;
    overflow: hidden;
    text-align: left;
    font: var(--medium);
    font-size: 12.5px;
    line-height: 15px;
    color: var(--text-primary);
  }

  .spacer {
    flex: 1 1 8px;
    min-width: 8px;
  }

  .date {
    flex: 0 0 auto;
    font-size: 11px;
    line-height: 14px;
    color: var(--text-tertiary);
    white-space: nowrap;
  }

  .snippet {
    display: flex;
    align-items: flex-start;
    gap: 9px;
    min-width: 0;
  }

  .time {
    flex: 0 0 auto;
    font: var(--mono);
    font-variant-numeric: tabular-nums;
    color: var(--text-tertiary);
  }

  .time.playable {
    color: var(--text-secondary);
  }

  .quote {
    flex: 1 1 auto;
    min-width: 0;
    margin: 0;
    font-size: 12.5px;
    line-height: 15px;
    color: var(--text-secondary);
    white-space: pre-wrap;
    overflow-wrap: anywhere;
  }
</style>
