<script lang="ts">
  /* The Transcripts section: everything dictated, transcribed or listened
     to, and one of them open.

     The list and the open transcript share one place on the window and
     cross on the spring, both present while they do: the transcript arrives
     from 14 px to the right and leaves the same way, the list returns from
     8 px to the left, as the Mac moves them. A transcript deleted while open,
     here or anywhere else, simply gives way to the list. */
  import Browse from "./Browse.svelte";
  import Detail from "./Detail.svelte";
  import { core, ui } from "../../lib/state.svelte";
  import type { Transcript } from "../../lib/types";
  import { drift } from "./motion";

  const open = $derived(
    ui.openTranscript === null
      ? null
      : (core.history.find((transcript) => transcript.id === ui.openTranscript) ?? null),
  );

  /* The last transcript shown, so the detail keeps drawing it while it
     leaves: the open one is already gone by then. */
  let last: Transcript | null = null;
  const shown = $derived.by(() => {
    if (open) last = open;
    return open ?? last;
  });
</script>

<div class="stage">
  {#if open}
    <div class="view" in:drift={{ x: 14 }} out:drift={{ x: 14 }}>
      {#if shown}<Detail transcript={shown} />{/if}
    </div>
  {:else}
    <div class="view" in:drift={{ x: -8 }} out:drift={{ x: -8 }}>
      <Browse />
    </div>
  {/if}
</div>

<style>
  .stage {
    flex: 1 1 auto;
    min-height: 0;
    display: grid;
    grid-template: minmax(0, 1fr) / minmax(0, 1fr);
    overflow: hidden;
  }

  /* Both views in the one cell, so the crossing overlaps rather than
     stacking the leaving view above the arriving one. */
  .view {
    grid-area: 1 / 1;
    min-width: 0;
    min-height: 0;
    display: flex;
    flex-direction: column;
  }
</style>
