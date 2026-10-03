<script lang="ts">
  /* Everything that matches what is typed in the top bar, best first, as
     the query is typed. The count says how many; an empty result says how
     much was searched, so "nothing" is not mistaken for "nothing to search". */
  import Search from "@lucide/svelte/icons/search";
  import EmptyState from "../../lib/ui/EmptyState.svelte";
  import SearchResultRow from "./SearchResultRow.svelte";
  import { counted } from "../../lib/format";
  import { searchIndex } from "../../lib/search";
  import { core, ui } from "../../lib/state.svelte";

  const hits = $derived(searchIndex(core.history).search(ui.transcriptQuery));
</script>

{#if hits.length === 0}
  <EmptyState
    icon={Search}
    title="No matches"
    message="Nothing across {counted(core.history.length, 'transcript')} matches “{ui.transcriptQuery}”."
  />
{:else}
  <div class="scroll">
    <div class="stack">
      <p class="count">{counted(hits.length, "transcript")}</p>
      {#each hits as hit (hit.transcript.id)}
        <SearchResultRow {hit} />
      {/each}
    </div>
  </div>
{/if}

<style>
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

  .count {
    margin: 0;
    padding: 0 2px 2px;
    font-size: 11.5px;
    line-height: 14px;
    color: var(--text-tertiary);
  }
</style>
