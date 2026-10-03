<script lang="ts">
  /* The Mac's small progress wheel: twelve spokes, the brightest leading.
     It steps rather than glides, as the native one does. Under reduced motion
     it stands still, which still reads as "working". */
  interface Props {
    size?: number;
  }

  let { size = 16 }: Props = $props();
  const spokes = Array.from({ length: 12 }, (_, i) => i);
</script>

<svg class="spinner" width={size} height={size} viewBox="0 0 16 16" aria-hidden="true">
  {#each spokes as i}
    <line
      x1="8"
      y1="2.2"
      x2="8"
      y2="5.2"
      transform="rotate({i * 30} 8 8)"
      style:opacity={0.18 + (0.82 * i) / 11}
    />
  {/each}
</svg>

<style>
  .spinner {
    flex: 0 0 auto;
    animation: turn 1s steps(12) infinite;
  }

  line {
    stroke: var(--text-secondary);
    stroke-width: 1.6;
    stroke-linecap: round;
  }

  @keyframes turn {
    to { transform: rotate(1turn); }
  }

  @media (prefers-reduced-motion: reduce) {
    .spinner { animation: none; }
  }
</style>
