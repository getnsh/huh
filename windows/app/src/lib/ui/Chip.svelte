<script lang="ts">
  /* A small capsule of fact: "1 fixed", "learned", "hint only". Text in the
     tint, on the tint at 12 %. */
  import type { Snippet } from "svelte";

  interface Props {
    tint?: string;
    title?: string;
    children: Snippet;
  }

  let { tint = "var(--text-secondary)", title, children }: Props = $props();
</script>

<span class="chip" style:--tint={tint} {title}>{@render children()}</span>

<style>
  .chip {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    font-weight: 500;
    font-size: 10.5px;
    line-height: 1.2;
    padding: 3px 7px;
    border-radius: 999px;
    color: var(--tint);
    background: color-mix(in srgb, var(--tint) 12%, transparent);
    white-space: nowrap;
  }
</style>
