<script lang="ts">
  /* A thin capsule that fills in the live colour. With no `value` it is the
     Mac's indeterminate bar: a thumb a third of the width going back and
     forth, because any percentage would be invented. */
  interface Props {
    value?: number | null;
    height?: number;
  }

  let { value = null, height = 3 }: Props = $props();
</script>

<div class="track" style:height="{height}px">
  {#if value === null}
    <span class="thumb"></span>
  {:else}
    <span class="fill" style:width="max({height}px, {Math.min(1, Math.max(0, value)) * 100}%)"></span>
  {/if}
</div>

<style>
  .track {
    position: relative;
    width: 100%;
    border-radius: 999px;
    background: var(--hover);
    overflow: hidden;
  }

  .fill {
    position: absolute;
    inset: 0 auto 0 0;
    border-radius: 999px;
    background: var(--live);
    transition: width var(--quick-duration) var(--quick);
  }

  .thumb {
    position: absolute;
    inset: 0 auto 0 0;
    width: 35%;
    border-radius: 999px;
    background: var(--live);
    animation: travel 1.05s ease-in-out infinite alternate;
  }

  @keyframes travel {
    to { left: 65%; }
  }

  @media (prefers-reduced-motion: reduce) {
    .thumb { animation: none; left: 32.5%; }
  }
</style>
