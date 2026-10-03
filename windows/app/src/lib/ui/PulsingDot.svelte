<script lang="ts">
  /* A dot that says something is live: a soft glow on the dot and a ring
     leaving it, again and again, while it is. Still and grey when it is not. */
  interface Props {
    active?: boolean;
    size?: number;
    tint?: string;
  }

  let { active = true, size = 7, tint = "var(--live)" }: Props = $props();
</script>

<span class="frame" class:active style:--size="{size}px" style:--tint={tint}>
  {#if active}<span class="ring"></span>{/if}
  <span class="dot"></span>
</span>

<style>
  .frame {
    position: relative;
    display: grid;
    place-items: center;
    width: calc(var(--size) * 3);
    height: calc(var(--size) * 3);
    flex: 0 0 auto;
  }

  .dot,
  .ring {
    grid-area: 1 / 1;
    width: var(--size);
    height: var(--size);
    border-radius: 50%;
  }

  .dot {
    background: var(--text-tertiary);
    transition: background-color var(--quick-duration) var(--quick);
  }

  .active .dot {
    background: var(--tint);
    box-shadow: 0 0 5px color-mix(in srgb, var(--tint) 90%, transparent);
  }

  .ring {
    border: 1px solid color-mix(in srgb, var(--tint) 55%, transparent);
    animation: leave 1.7s cubic-bezier(0, 0, 0.58, 1) infinite;
  }

  @keyframes leave {
    from { transform: scale(1); opacity: 0.9; }
    to { transform: scale(2.8); opacity: 0; }
  }

  @media (prefers-reduced-motion: reduce) {
    .ring { display: none; }
  }
</style>
