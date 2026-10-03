<script lang="ts">
  /* The collapsed session's mark: the app's five bars, moving with whoever is
     speaking. The centre bar takes the speaker's colour, the live colour for
     you and the softer one for the room, so the mark says who is talking. */
  interface Props {
    history?: number[];
    active?: boolean;
    accent?: string;
  }

  let { history = [], active = false, accent = "var(--live)" }: Props = $props();

  const WEIGHTS = [0.34, 0.66, 1, 0.66, 0.34];
  const BAR = 3.5;
  const GAP = 3.5;
  const MAX = 20;

  let heights: number[] = $state(WEIGHTS.map((w) => Math.max(BAR, w * 0.44 * MAX)));

  $effect(() => {
    const levels = history;
    const live = active;
    const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
    const reference = Math.max(Math.max(0, ...levels), 0.06);
    const recent = Math.max(0, ...levels.slice(-4));
    const level = Math.min(1, recent / reference);

    const compute = (time: number) => {
      const t = time / 1000;
      heights = WEIGHTS.map((weight, i) => {
        const wobble = live && !reduce ? 0.78 + 0.22 * Math.sin(t * 7.4 + i * 1.15) : 1;
        const fraction = 0.44 + 0.56 * Math.pow(level, 0.6) * wobble;
        return Math.max(BAR, weight * fraction * MAX);
      });
    };

    if (!live || reduce) {
      compute(0);
      return;
    }
    let frame = 0;
    let last = 0;
    const loop = (time: number) => {
      if (time - last >= 32) {
        last = time;
        compute(time);
      }
      frame = requestAnimationFrame(loop);
    };
    frame = requestAnimationFrame(loop);
    return () => cancelAnimationFrame(frame);
  });
</script>

<span class="mark" style:--accent={accent} style:gap="{GAP}px" style:height="{MAX}px">
  {#each heights as height, i}
    <i class:centre={i === 2} style:height="{height}px" style:width="{BAR}px"></i>
  {/each}
</span>

<style>
  .mark {
    display: inline-flex;
    align-items: center;
  }

  i {
    display: block;
    border-radius: 999px;
    background: var(--text-primary);
  }

  i.centre {
    background: var(--accent);
    transition: background-color 0.12s cubic-bezier(0, 0, 0.58, 1);
  }
</style>
