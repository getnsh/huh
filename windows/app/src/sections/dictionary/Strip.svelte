<script lang="ts">
  /* The card a tab's suggestions sit in: raised, a hairline, the card radius,
     inset from the window's edges as the rows are. It does not scroll with
     the list; it is the question, and the list is the answer so far. */
  import type { Snippet } from "svelte";

  interface Props {
    gap: number;
    /* Fades and drops into place when it appears, as the Mac's word strip
       does. The other two are always there and simply are. */
    appear?: boolean;
    children: Snippet;
  }

  let { gap, appear = false, children }: Props = $props();
</script>

<section class="strip" class:appear style:gap="{gap}px">
  {@render children()}
</section>

<style>
  .strip {
    flex: none;
    display: flex;
    flex-direction: column;
    margin: 0 16px 10px;
    padding: 12px;
    border-radius: var(--radius-card);
    background: var(--raised);
    box-shadow: inset 0 0 0 1px var(--border-soft);
  }

  .appear {
    animation: appear var(--spring-duration) var(--spring);
  }

  @keyframes appear {
    from { opacity: 0; transform: translateY(-8px); }
  }
</style>
