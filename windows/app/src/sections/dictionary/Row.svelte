<script lang="ts">
  /* One entry in a Dictionary list: the raised card that lifts a step under
     the pointer, with its edit and delete buttons arriving only then.

     The buttons join the row rather than float over it, as on the Mac: the
     chips step aside to make room and the row grows to the buttons' height,
     both on the quick curve. Keyboard focus inside the row shows them too,
     so they can be reached without a mouse. */
  import type { Snippet } from "svelte";

  interface Props {
    children: Snippet;
    actions: Snippet;
  }

  let { children, actions }: Props = $props();
</script>

<div class="row hover-card">
  {@render children()}
  <span class="actions">{@render actions()}</span>
</div>

<style>
  .row {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 9px 12px;
    border-radius: var(--radius-control);
    min-width: 0;
    /* Lets the actions grow from nothing to their own size, and back. */
    interpolate-size: allow-keywords;
  }

  /* Collapsed to the switch's height, and pulled back over the gap the row
     would otherwise leave for it. */
  .actions {
    flex: none;
    display: flex;
    align-items: center;
    gap: 2px;
    width: 0;
    height: 16px;
    margin-left: -12px;
    overflow: hidden;
    opacity: 0;
    visibility: hidden;
    transition:
      width var(--quick-duration) var(--quick),
      height var(--quick-duration) var(--quick),
      margin-left var(--quick-duration) var(--quick),
      opacity var(--quick-duration) var(--quick),
      visibility var(--quick-duration) var(--quick);
  }

  .row:hover .actions,
  .row:has(:focus-visible) .actions {
    width: auto;
    height: auto;
    margin-left: 0;
    opacity: 1;
    visibility: visible;
  }
</style>
