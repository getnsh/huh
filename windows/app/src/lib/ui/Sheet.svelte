<script lang="ts">
  /* A modal sheet over the whole window, as the Mac attaches one: the window
     dims, the panel arrives in the middle. Escape cancels; Return submits
     when submitting is allowed, even from inside a text field. A click on
     the dimmed window does nothing, as on the Mac. */
  import type { Snippet } from "svelte";

  interface Props {
    width?: number;
    canSubmit?: boolean;
    onsubmit: () => void;
    oncancel: () => void;
    children: Snippet;
  }

  let { width = 460, canSubmit = true, onsubmit, oncancel, children }: Props = $props();

  function keydown(event: KeyboardEvent) {
    if (event.key === "Escape") {
      event.preventDefault();
      oncancel();
    } else if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault();
      if (canSubmit) onsubmit();
    }
  }
</script>

<svelte:window onkeydown={keydown} />

<div class="scrim">
  <div class="sheet" role="dialog" aria-modal="true" style:width="{width}px">
    {@render children()}
  </div>
</div>

<style>
  .scrim {
    position: fixed;
    inset: 0;
    z-index: 50;
    display: grid;
    place-items: center;
    background: rgb(18 18 18 / 0.6);
    animation: dim var(--quick-duration) var(--quick);
  }

  .sheet {
    max-height: calc(100vh - 48px);
    overflow-y: auto;
    border-radius: var(--radius-panel);
    background: var(--surface);
    box-shadow:
      inset 0 1px 0 var(--border),
      0 0 0 1px var(--border-soft),
      0 20px 50px rgb(0 0 0 / 0.5);
    animation: arrive var(--spring-duration) var(--spring);
  }

  @keyframes dim {
    from { opacity: 0; }
  }

  @keyframes arrive {
    from { opacity: 0; transform: scale(0.98); }
  }

  @media (prefers-reduced-motion: reduce) {
    .scrim, .sheet { animation: none; }
  }
</style>
