<script lang="ts">
  /* A Lucide glyph standing in for an SF Symbol at the Mac's size and weight.
     An SF Symbol at point size N draws about 1.3 N tall, and its weights map
     onto stroke widths; the stroke is absolute, so a small icon does not go
     thin as it shrinks. `fill` is for the Mac's ".fill" symbols. */
  import type { Component } from "svelte";

  type Weight = "light" | "regular" | "medium" | "semibold" | "bold";

  interface Props {
    of: Component<any>;
    size?: number;
    weight?: Weight;
    fill?: boolean;
    class?: string;
  }

  let { of: Glyph, size = 12, weight = "regular", fill = false, class: className = "" }: Props =
    $props();

  const STROKE: Record<Weight, number> = {
    light: 1.0,
    regular: 1.25,
    medium: 1.4,
    semibold: 1.6,
    bold: 1.8,
  };
</script>

<Glyph
  size={Math.round(size * 1.3)}
  strokeWidth={STROKE[weight]}
  absoluteStrokeWidth
  fill={fill ? "currentColor" : "none"}
  class="icon {className}"
  aria-hidden="true"
/>
