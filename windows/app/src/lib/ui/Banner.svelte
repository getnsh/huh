<script lang="ts">
  /* A strip under the top bar that says one thing and offers what to do
     about it. It slides down into place and fades, on the spring. */
  import type { Snippet } from "svelte";

  interface Props {
    tone?: "raised" | "warning" | "live" | "danger";
    children: Snippet;
  }

  let { tone = "raised", children }: Props = $props();
</script>

<div class="banner {tone}">
  {@render children()}
</div>

<style>
  .banner {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 9px 16px;
    box-shadow: inset 0 -1px 0 var(--border);
    font-size: 12px;
    line-height: 1.25;
    color: var(--text-secondary);
    animation: drop var(--spring-duration) var(--spring);
  }

  .raised { background: var(--raised); }
  .warning { background: color-mix(in srgb, var(--warning) 8%, var(--base)); }
  .live { background: color-mix(in srgb, var(--live) 8%, var(--base)); }
  .danger { background: color-mix(in srgb, var(--danger) 10%, var(--base)); color: var(--danger); }

  @keyframes drop {
    from { opacity: 0; transform: translateY(-8px); }
  }

  @media (prefers-reduced-motion: reduce) {
    .banner { animation: none; }
  }
</style>
