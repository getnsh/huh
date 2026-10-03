<script lang="ts">
  import type { Snippet } from "svelte";

  let { children }: { children: Snippet } = $props();
</script>

<span class="label">{@render children()}</span>

<style>
  .label {
    font-weight: 500;
    font-size: 10.5px;
    line-height: 1.2;
    letter-spacing: 0.6px;
    text-transform: uppercase;
    color: var(--text-tertiary);
  }
</style>
