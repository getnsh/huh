<script lang="ts">
  /* Words, Corrections, People, each with how many it holds. The counts are
     totals, not what a search has left: a tab says what is there. The
     selection moves on the spring, as the Mac's does. */
  import { core, ui, type DictionaryTab } from "../../lib/state.svelte";

  const TABS: { id: DictionaryTab; title: string }[] = [
    { id: "words", title: "Words" },
    { id: "corrections", title: "Corrections" },
    { id: "people", title: "People" },
  ];

  const counts = $derived({
    words: core.dictionary?.terms.length ?? 0,
    corrections: core.dictionary?.corrections.length ?? 0,
    people: core.dictionary?.people.length ?? 0,
  });
</script>

<div class="tabs" role="tablist">
  {#each TABS as tab (tab.id)}
    <button
      class="tab"
      class:on={ui.tab === tab.id}
      role="tab"
      aria-selected={ui.tab === tab.id}
      onclick={() => (ui.tab = tab.id)}
    >
      <span>{tab.title}</span>
      <span class="count">{counts[tab.id]}</span>
    </button>
  {/each}
</div>

<style>
  .tabs {
    flex: none;
    display: flex;
    gap: 4px;
    padding: 12px 16px 10px;
  }

  .tab {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 6px 11px;
    border-radius: 7px;
    font: var(--medium);
    font-size: 12.5px;
    color: var(--text-secondary);
    background: transparent;
    transition:
      background-color var(--spring-duration) var(--spring),
      color var(--spring-duration) var(--spring);
  }

  .tab.on {
    color: var(--text-primary);
    background: var(--raised);
  }

  .count {
    font-weight: 500;
    font-size: 10.5px;
    color: var(--text-tertiary);
  }
</style>
