<script lang="ts">
  /* The small grey sentence under a group's controls that says what they do
     or what they cost. It wraps; nothing else in a card does. The line pitch
     is the Mac's measured 14, set in pixels so every wrapped line lands on
     it rather than a fraction off. */
  import type { Snippet } from "svelte";

  let { children }: { children: Snippet } = $props();
</script>

<p class="note">{@render children()}</p>

<style>
  .note {
    margin: 0;
    font-size: 11.5px;
    line-height: 14px;
    color: var(--text-tertiary);
  }
</style>
