<script lang="ts">
  /* One labelled setting: the label at the left, the control at the right.

     Given a width, the control sits centred in a slot that wide. The Mac
     frames each picker at a fixed width and AppKit centres the pop-up inside
     it, so a short pop-up stands a little in from the edge rather than flush
     against it; right-aligning would move every picker off the Mac's spot.
     Without a width the control simply ends the row. */
  import type { Snippet } from "svelte";

  interface Props {
    label: string;
    width?: number;
    children: Snippet;
  }

  let { label, width, children }: Props = $props();
</script>

<div class="row">
  <span class="label">{label}</span>
  <span class="spacer"></span>
  {#if width}
    <span class="slot" style:width="{width}px">{@render children()}</span>
  {:else}
    {@render children()}
  {/if}
</div>

<style>
  .row {
    display: flex;
    align-items: center;
    min-height: 24px;
  }

  .label {
    font: var(--body);
    line-height: 16px;
    color: var(--text-secondary);
    white-space: nowrap;
  }

  .spacer {
    flex: 1 1 auto;
    min-width: 8px;
  }

  .slot {
    flex: 0 0 auto;
    display: flex;
    justify-content: center;
  }
</style>
