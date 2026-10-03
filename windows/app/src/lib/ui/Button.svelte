<script lang="ts">
  /* The Mac's three button styles, and nothing between them.

     Primary borrows its emphasis from inversion, light on dark, because the
     live colour is reserved for state. Secondary is the raised grey with a
     hairline. Ghost is bare until pressed. None has a hover state: on the Mac
     a button answers the press, not the pointer passing over it. */
  import type { Snippet } from "svelte";

  interface Props {
    variant?: "primary" | "secondary" | "ghost";
    /* The text and icon colour for secondary and ghost. */
    tint?: string;
    disabled?: boolean;
    title?: string;
    label?: string;
    type?: "button" | "submit";
    onclick?: (event: MouseEvent) => void;
    children: Snippet;
  }

  let {
    variant = "secondary",
    tint,
    disabled = false,
    title,
    label,
    type = "button",
    onclick,
    children,
  }: Props = $props();
</script>

<button
  {type}
  class="button {variant}"
  style:--tint={tint}
  {disabled}
  {title}
  aria-label={label}
  onclick={(event) => {
    if (!disabled) onclick?.(event);
  }}
>
  {@render children()}
</button>

<style>
  .button {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    gap: 6px;
    white-space: nowrap;
    border: 0;
    line-height: 1.2;
    transition:
      transform var(--quick-duration) var(--quick),
      background-color var(--quick-duration) var(--quick),
      color var(--quick-duration) var(--quick);
  }

  .button:disabled {
    opacity: 0.4;
  }

  .primary {
    font: var(--medium);
    line-height: 1.2;
    padding: 8px 16px;
    border-radius: var(--radius-control);
    color: var(--accent-text);
    background: var(--accent-fill);
  }

  .primary:not(:disabled):active {
    background: color-mix(in srgb, var(--accent-fill) 82%, transparent);
    transform: scale(0.985);
  }

  .secondary {
    font: var(--medium);
    line-height: 1.2;
    padding: 7px 14px;
    border-radius: var(--radius-control);
    color: var(--tint, var(--text-primary));
    background: var(--raised);
    box-shadow: inset 0 0 0 1px var(--border);
  }

  .secondary:not(:disabled):active {
    background: var(--pressed);
    transform: scale(0.985);
  }

  .ghost {
    font: var(--medium);
    font-size: 12px;
    line-height: 1.2;
    padding: 5px 9px;
    border-radius: 6px;
    color: var(--tint, var(--text-secondary));
    background: transparent;
  }

  .ghost:not(:disabled):active {
    color: var(--text-primary);
    background: var(--hover);
  }
</style>
