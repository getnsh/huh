<script lang="ts">
  /* The panel's card: the surface, a hairline and a shadow shaped to it, with
     what it holds padded 16 all round. Opaque, as on the Mac: a blur would
     pick up whatever happens to be behind the panel.

     The surface is drawn on a layer of its own, behind the contents, so that
     when the card grows it can reach its new height on the spring while the
     window takes that height at once (see `glide`). */
  import type { Snippet } from "svelte";
  import { glide } from "./motion";

  interface Props {
    /* The width of what the card holds; the card is this plus its padding. */
    width: number;
    children: Snippet;
  }

  let { width, children }: Props = $props();

  let surface: HTMLDivElement | undefined = $state(undefined);
  let body: HTMLDivElement | undefined = $state(undefined);

  $effect(() => {
    const back = surface;
    const front = body;
    if (!back || !front) return;
    // The first measurement is the card arriving, which its face's own
    // transition already covers; only growth after that glides.
    let height = -1;
    const observer = new ResizeObserver(([entry]) => {
      const next = entry.borderBoxSize?.[0]?.blockSize ?? front.offsetHeight;
      const grew = height < 0 ? 0 : next - height;
      height = next;
      if (grew > 0.5) glide(back, front, grew);
    });
    observer.observe(front);
    return () => observer.disconnect();
  });
</script>

<div class="card" style:width="{width + 32}px">
  <div class="surface" bind:this={surface}></div>
  <div
    class="body"
    bind:this={body}
    ontransitionend={(event) => {
      // The clip has done its work; a card at rest is not clipped.
      const node = event.currentTarget;
      if (event.target === node && event.propertyName === "clip-path") node.style.clipPath = "";
    }}
  >
    {@render children()}
  </div>
</div>

<style>
  .card {
    position: relative;
    isolation: isolate;
  }

  /* 20 px is the Mac's radiusPanel + 4: the session card is rounded a step
     further than the 16 of every other panel. */
  .surface {
    position: absolute;
    inset: 0;
    z-index: -1;
    border-radius: 20px;
    background: var(--surface);
    box-shadow:
      inset 0 0 0 1px var(--border),
      0 3px 8px rgb(0 0 0 / 0.3);
  }

  .body {
    padding: 16px;
  }
</style>
