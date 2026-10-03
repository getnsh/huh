<script lang="ts" module>
  /* Where the list was scrolled to. Opening a transcript replaces the list,
     and coming back to the top of five hundred cards would lose the place;
     the Mac does lose it, which is the one thing here not copied. */
  let remembered = 0;
</script>

<script lang="ts">
  /* Every transcript, newest first, in one flat list: no grouping by day and
     no sorting to choose, as on the Mac. Above it, any recording being
     transcribed. When the top bar's field has a query in it, the matches
     replace the list. */
  import AudioLines from "@lucide/svelte/icons/audio-lines";
  import EmptyState from "../../lib/ui/EmptyState.svelte";
  import JobBanners from "./JobBanners.svelte";
  import SearchResults from "./SearchResults.svelte";
  import TranscriptCard from "./TranscriptCard.svelte";
  import { core, ui } from "../../lib/state.svelte";

  const searching = $derived(ui.transcriptQuery.trim() !== "");

  /* "4 mins ago" has to become "5 mins ago" without anything else changing,
     so the cards read the time from a clock that ticks. */
  let now = $state(Date.now());

  $effect(() => {
    const timer = setInterval(() => (now = Date.now()), 30_000);
    return () => clearInterval(timer);
  });

  let list: HTMLDivElement | undefined = $state(undefined);

  $effect(() => {
    if (list) list.scrollTop = remembered;
  });
</script>

<div class="browse">
  <JobBanners />

  {#if core.history.length === 0}
    <EmptyState
      icon={AudioLines}
      title="No transcripts yet"
      message="Hold your push-to-talk key anywhere, press Start below, or drop a meeting recording onto this window."
    />
  {:else if searching}
    <SearchResults />
  {:else}
    <div class="scroll" bind:this={list} onscroll={() => (remembered = list?.scrollTop ?? 0)}>
      <div class="stack">
        {#each core.history as transcript (transcript.id)}
          <TranscriptCard {transcript} {now} />
        {/each}
      </div>
    </div>
  {/if}
</div>

<style>
  .browse {
    flex: 1 1 auto;
    min-height: 0;
    display: flex;
    flex-direction: column;
  }

  .scroll {
    flex: 1 1 auto;
    min-height: 0;
    overflow-y: auto;
  }

  .stack {
    display: flex;
    flex-direction: column;
    gap: 6px;
    padding: 14px 16px;
  }
</style>
