<script lang="ts">
  /* One turn of speech in the session's transcript.

     A coloured rail rather than a name on every line: the colour already says
     who is speaking, the live colour for you and the softer one for the room,
     and a label down the left edge would cost width the words need. A settled
     line is bright on a firm rail; the unsettled tail of a stream, still being
     worked out, is grey on a fainter one. */
  import type { Voice } from "../lib/types";

  interface Props {
    voice: Voice;
    text: string;
    settled: boolean;
  }

  let { voice, text, settled }: Props = $props();
</script>

<div class="line" class:settled class:room={voice === "room"}>
  <span class="rail"></span>
  <p class="words">{text}</p>
</div>

<style>
  .line {
    --tint: var(--live);
    display: flex;
    align-items: stretch;
    gap: 9px;
  }

  .line.room {
    --tint: var(--live-soft);
  }

  .rail {
    flex: 0 0 2px;
    border-radius: 1px;
    background: color-mix(in srgb, var(--tint) 35%, transparent);
  }

  .settled .rail {
    background: color-mix(in srgb, var(--tint) 75%, transparent);
  }

  /* 12.5 pt with 2.5 pt between lines, as on the Mac. */
  .words {
    flex: 1 1 auto;
    min-width: 0;
    margin: 0;
    font-size: 12.5px;
    line-height: calc(1.2em + 2.5px);
    color: var(--text-secondary);
    overflow-wrap: anywhere;
  }

  .settled .words {
    color: var(--text-primary);
  }
</style>
