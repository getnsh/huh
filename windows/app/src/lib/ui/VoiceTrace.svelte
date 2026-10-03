<script lang="ts">
  /* One voice's signal across the width it is given: the whole second of
     history spread over as many bars as fit, at a fixed pitch, scaled to its
     own loudest moment so a quiet speaker still shows. Dots when nothing is
     heard. Used for the "You" and "PC" traces. */
  interface Props {
    history?: number[];
    active?: boolean;
    tint?: string;
    height?: number;
  }

  let { history = [], active = false, tint = "var(--live)", height = 26 }: Props = $props();

  const BAR = 2.5;
  const PITCH = 5;
  const MIN = 2.5;

  let canvas: HTMLCanvasElement | undefined = $state(undefined);
  let width = $state(0);

  $effect(() => {
    if (!canvas || width <= 0) return;
    const context = canvas.getContext("2d");
    if (!context) return;
    const ratio = window.devicePixelRatio || 1;
    canvas.width = Math.round(width * ratio);
    canvas.height = Math.round(height * ratio);
    context.setTransform(ratio, 0, 0, ratio, 0, 0);

    const colour =
      getComputedStyle(canvas).getPropertyValue(tint.replace("var(", "").replace(")", "").trim()).trim() ||
      "#9E7BFF";
    const levels = history;
    const live = active;
    const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
    const count = Math.max(8, Math.floor((width + PITCH - BAR) / PITCH));
    const reference = Math.max(Math.max(0, ...levels), 0.06);

    const sample = (position: number) => {
      if (levels.length === 0) return 0;
      if (levels.length === 1) return levels[0];
      const exact = position * (levels.length - 1);
      const low = Math.floor(exact);
      const high = Math.min(levels.length - 1, low + 1);
      return levels[low] + (levels[high] - levels[low]) * (exact - low);
    };

    const draw = (time: number) => {
      const t = time / 1000;
      context.clearRect(0, 0, width, height);
      context.fillStyle = colour;
      for (let i = 0; i < count; i += 1) {
        const normalised = Math.min(1, sample(i / Math.max(1, count - 1)) / reference);
        const idle = live && !reduce ? 0.03 * (0.5 + 0.5 * Math.sin(t * 2.6 + i * 0.35)) : 0;
        const amount = Math.min(1, Math.pow(normalised, 0.8) * 0.95 + idle);
        const bar = Math.max(MIN, amount * height);
        context.beginPath();
        context.roundRect(i * PITCH, (height - bar) / 2, BAR, bar, BAR / 2);
        context.fill();
      }
    };

    if (!live || reduce) {
      draw(0);
      return;
    }
    let frame = 0;
    let last = 0;
    const loop = (time: number) => {
      if (time - last >= 32) {
        last = time;
        draw(time);
      }
      frame = requestAnimationFrame(loop);
    };
    frame = requestAnimationFrame(loop);
    return () => cancelAnimationFrame(frame);
  });
</script>

<div class="trace" class:active bind:clientWidth={width} style:height="{height}px">
  <canvas bind:this={canvas} style:width="{width}px" style:height="{height}px"></canvas>
</div>

<style>
  .trace {
    flex: 1 1 auto;
    min-width: 0;
    opacity: 0.35;
    transition: opacity var(--quick-duration) var(--quick);
  }

  .trace.active {
    opacity: 1;
  }

  canvas {
    display: block;
  }
</style>
