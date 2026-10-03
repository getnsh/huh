<script lang="ts">
  /* exclamationmark.triangle.fill. Lucide draws the triangle and its mark in
     one colour, so filling it would swallow the mark; the mark is drawn again
     in the colour of whatever is behind it, which is what the SF Symbol's
     cut-out shows. */
  import TriangleAlert from "@lucide/svelte/icons/triangle-alert";
  import Icon from "../../lib/ui/Icon.svelte";

  interface Props {
    size: number;
    /* The surface the glyph sits on, seen through the mark. */
    behind: string;
  }

  let { size, behind }: Props = $props();
</script>

<span class="alert" style:--behind={behind}><Icon of={TriangleAlert} {size} fill /></span>

<style>
  .alert {
    flex: none;
    display: grid;
    place-items: center;
  }

  .alert :global(svg > :not(:first-child)) {
    stroke: var(--behind);
  }
</style>
