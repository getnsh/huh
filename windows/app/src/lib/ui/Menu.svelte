<script lang="ts" module>
  export type MenuItem =
    | { label: string; action: () => void; disabled?: boolean; children?: never }
    | { label: string; children: MenuItem[]; action?: never; disabled?: boolean }
    | "separator";
</script>

<script lang="ts">
  /* A menu that opens under whatever was clicked, in the app's own greys.
     The Mac uses its native menus, which match a dark Mac; Windows' own
     menus follow the system theme, so they would arrive light in a dark app.
     Escape or a click elsewhere closes it; arrow keys and Return work. */
  import { untrack } from "svelte";
  import ChevronRight from "@lucide/svelte/icons/chevron-right";
  import Icon from "./Icon.svelte";

  interface Props {
    items: MenuItem[];
    /* Where to open, in viewport pixels: the trigger's bottom-left. */
    x: number;
    y: number;
    onclose: () => void;
  }

  let { items, x, y, onclose }: Props = $props();

  let panel: HTMLDivElement | undefined = $state(undefined);
  let submenu: HTMLDivElement | undefined = $state(undefined);
  let open: number | null = $state(null);
  let left = $state(0);
  let top = $state(0);
  /* A submenu opens to the right, as the Mac's do, unless that would carry it
     out of the window, which a webview cannot draw beyond: then to the left,
     and lifted when it would run off the bottom. The share menu sits against
     the window's right edge, so for it the left is the usual side. */
  let flip = $state(false);
  let lift = $state(0);
  /* Level with the item that opened it, as the Mac's are. */
  let anchor = $state(0);

  // Kept inside the window: flipped up or left when it would run off it.
  $effect(() => {
    if (!panel) return;
    const rect = panel.getBoundingClientRect();
    left = Math.min(x, window.innerWidth - rect.width - 8);
    top = y + rect.height > window.innerHeight - 8 ? Math.max(8, y - rect.height - 30) : y;
  });

  $effect(() => {
    if (!submenu || !panel) {
      flip = false;
      lift = 0;
      return;
    }
    const menu = panel.getBoundingClientRect();
    const own = submenu.getBoundingClientRect();
    flip = menu.right - 4 + own.width > window.innerWidth - 8;
    // Measured where it would sit unlifted, so lifting it never moves the goal.
    lift = Math.max(0, own.bottom + untrack(() => lift) - (window.innerHeight - 8));
  });

  function choose(item: MenuItem) {
    if (item === "separator" || item.disabled || item.children) return;
    onclose();
    item.action();
  }

  function keydown(event: KeyboardEvent) {
    const buttons = panel ? [...panel.querySelectorAll<HTMLButtonElement>(":scope > button:not(:disabled)")] : [];
    const index = buttons.indexOf(document.activeElement as HTMLButtonElement);
    if (event.key === "Escape") {
      event.preventDefault();
      onclose();
    } else if (event.key === "ArrowDown") {
      event.preventDefault();
      buttons[(index + 1) % buttons.length]?.focus();
    } else if (event.key === "ArrowUp") {
      event.preventDefault();
      buttons[(index - 1 + buttons.length) % buttons.length]?.focus();
    }
  }
</script>

<svelte:window onkeydown={keydown} />

<!-- svelte-ignore a11y_no_static_element_interactions, a11y_click_events_have_key_events -->
<div class="catcher" onpointerdown={onclose}></div>

<div bind:this={panel} class="menu" role="menu" style:left="{left}px" style:top="{top}px">
  {#each items as item, index}
    {#if item === "separator"}
      <div class="separator"></div>
    {:else}
      <button
        class="item"
        role="menuitem"
        disabled={item.disabled}
        onclick={() => choose(item)}
        onpointerenter={(event) => {
          open = item.children ? index : null;
          anchor = event.currentTarget.offsetTop;
        }}
      >
        <span>{item.label}</span>
        {#if item.children}<Icon of={ChevronRight} size={9} weight="semibold" />{/if}
      </button>
      {#if item.children && open === index}
        <div
          class="submenu"
          class:flip
          role="menu"
          bind:this={submenu}
          style:top="{anchor - 4 - lift}px"
        >
          {#each item.children as child}
            {#if child === "separator"}
              <div class="separator"></div>
            {:else}
              <button class="item" role="menuitem" disabled={child.disabled} onclick={() => choose(child)}>
                <span>{child.label}</span>
              </button>
            {/if}
          {/each}
        </div>
      {/if}
    {/if}
  {/each}
</div>

<style>
  .catcher {
    position: fixed;
    inset: 0;
    z-index: 60;
  }

  .menu,
  .submenu {
    position: fixed;
    z-index: 61;
    display: flex;
    flex-direction: column;
    min-width: 200px;
    padding: 4px;
    border-radius: var(--radius-control);
    background: var(--raised);
    box-shadow:
      inset 0 0 0 1px var(--border),
      0 12px 38px rgb(0 0 0 / 0.62),
      0 2px 6px rgb(0 0 0 / 0.5);
    animation: open var(--quick-duration) var(--quick);
  }

  .submenu {
    position: absolute;
    left: calc(100% - 4px);
  }

  .submenu.flip {
    left: auto;
    right: calc(100% - 4px);
  }

  .item {
    position: relative;
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 16px;
    height: 24px;
    padding: 0 10px;
    border-radius: 5px;
    font: var(--body);
    line-height: 1.2;
    color: var(--text-primary);
    text-align: left;
    white-space: nowrap;
  }

  .item:hover:not(:disabled),
  .item:focus-visible {
    background: var(--hover);
    outline: none;
  }

  .item:disabled {
    color: var(--text-tertiary);
  }

  .separator {
    height: 1px;
    margin: 4px 6px;
    background: var(--border-soft);
  }

  @keyframes open {
    from { opacity: 0; transform: translateY(-3px); }
  }
</style>
