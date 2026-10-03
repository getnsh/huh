<script lang="ts">
  /* The glyph beside a transcript: a waveform for a recording, a microphone
     for dictation, a speaking head for a live session. The Mac's mic.fill
     has a solid capsule on a drawn stand, so only the capsule is filled;
     filling Lucide's open stand would turn it into a bowl. */
  import AudioLines from "@lucide/svelte/icons/audio-lines";
  import Mic from "@lucide/svelte/icons/mic";
  import Speech from "@lucide/svelte/icons/speech";
  import Icon from "../../lib/ui/Icon.svelte";
  import type { Glyph } from "./naming";

  interface Props {
    glyph: Glyph;
    size: number;
  }

  let { glyph, size }: Props = $props();

  const GLYPHS = { waveform: AudioLines, mic: Mic, meeting: Speech };
</script>

<span class="source" class:mic={glyph === "mic"}>
  <Icon of={GLYPHS[glyph]} {size} />
</span>

<style>
  .source {
    display: grid;
    place-items: center;
  }

  .mic :global(svg rect) {
    fill: currentColor;
  }
</style>
