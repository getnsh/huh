<script lang="ts">
  /* The level meter, at the Mac's exact numbers: 28 bars, 3 px wide, 2.5 px
     apart, 24 px tall, redrawn 30 times a second.
     Canvas rather than 28 elements, because this runs for as long as the key
     is held and a layout pass per frame is not free. */
  interface Props {
    history?: number[];
    active?: boolean;
    bars?: number;
    barWidth?: number;
    gap?: number;
    maxHeight?: number;
    tint?: string;
  }

  let {
    history = [],
    active = false,
    bars = 28,
    barWidth = 3,
    gap = 2.5,
    maxHeight = 24,
    tint = "var(--live)",
  }: Props = $props();

  // Derived, not computed once: the main window widens the meter from 22 bars
  // to 44 the moment the microphone opens, and a constant would keep drawing
  // the old one at the old size.
  const width = $derived(bars * barWidth + (bars - 1) * gap);
  let canvas: HTMLCanvasElement | undefined = $state(undefined);

  $effect(() => {
    if (!canvas) return;
    let frame = 0;
    const context = canvas.getContext("2d");
    if (!context) return;
    const ratio = window.devicePixelRatio || 1;
    canvas.width = width * ratio;
    canvas.height = maxHeight * ratio;
    context.scale(ratio, ratio);

    const colour = getComputedStyle(document.documentElement)
      .getPropertyValue(tint.replace("var(", "").replace(")", "").trim())
      .trim() || "#9E7BFF";

    const draw = () => {
      const phase = performance.now() / 1000;
      context.clearRect(0, 0, width, maxHeight);
      for (let index = 0; index < bars; index += 1) {
        const offset = index - (bars - history.length);
        const level = offset >= 0 && offset < history.length ? history[offset] : 0;
        // Compress the upper range so loud speech does not saturate every bar.
        const shaped = Math.pow(Math.min(1, level), 0.65);
        // A static row reads as a failure rather than as waiting for input.
        const breathing = active ? 2.2 * (0.5 + 0.5 * Math.sin(phase * 3.1 + index * 0.42)) : 0;
        const height = 3 + breathing + shaped * (maxHeight - 3);
        const recency = index / Math.max(1, bars - 1);
        context.globalAlpha = active ? 0.35 + 0.65 * recency : 0.45;
        context.fillStyle = active ? colour : "#6B6B6B";
        const x = index * (barWidth + gap);
        const y = (maxHeight - height) / 2;
        context.beginPath();
        context.roundRect(x, y, barWidth, height, barWidth / 2);
        context.fill();
      }
      frame = requestAnimationFrame(draw);
    };
    draw();
    return () => cancelAnimationFrame(frame);
  });
</script>

<canvas bind:this={canvas} style="width:{width}px;height:{maxHeight}px"></canvas>

<style>
  canvas {
    display: block;
  }
</style>
