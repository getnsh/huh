<script lang="ts" module>
  export type Tone = "live" | "warning" | "neutral";
</script>

<script lang="ts">
  /* A dot and a sentence: how something stands right now. The dot takes the
     live colour when all is well, the warning colour when something wants
     attention, and grey when there is nothing to say either way. Anything
     that acts on it, such as "Check Again", follows the sentence. */
  import type { Snippet } from "svelte";

  interface Props {
    tone: Tone;
    text: string;
    /* Startup's line, which the Mac sets half a point smaller. */
    small?: boolean;
    danger?: boolean;
    children?: Snippet;
  }

  let { tone, text, small = false, danger = false, children }: Props = $props();
</script>

<div class="status">
  <span class="dot {tone}"></span>
  <span class="text" class:small class:danger>{text}</span>
  {#if children}
    {@render children()}
  {/if}
</div>

<style>
  .status {
    display: flex;
    align-items: center;
    gap: 7px;
  }

  .dot {
    flex: 0 0 auto;
    width: 6px;
    height: 6px;
    border-radius: 50%;
  }

  .live {
    background: var(--live);
  }

  .warning {
    background: var(--warning);
  }

  .neutral {
    background: var(--text-tertiary);
  }

  .text {
    flex: 1 1 auto;
    min-width: 0;
    font-size: 12px;
    line-height: 15px;
    color: var(--text-tertiary);
  }

  .text.small {
    font-size: 11.5px;
    line-height: 14px;
  }

  .text.danger {
    color: var(--danger);
  }
</style>
