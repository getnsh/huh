<script lang="ts" generics="T extends string">
  /* The Mac's pop-up button, for a choice among a few.

     The button is as wide as its longest option, as AppKit sizes a pop-up, so
     it keeps its width when the choice changes. The list opens over the
     button with the current choice under the pointer and a tick beside it,
     which is where a Mac pop-up puts it: a choice is changed by moving a short
     way from what is there, not by reading a list from the top. Menu is not
     used because it opens below what was clicked and has no current choice
     to mark; its panel is copied, so the two look like one family.

     Arrows open it from the keyboard, as Return and Space do by pressing it;
     inside, arrows, Home and End move, Return or Space choose, and Escape or
     Tab put it away with nothing changed. */
  import Check from "@lucide/svelte/icons/check";
  import ChevronsUpDown from "@lucide/svelte/icons/chevrons-up-down";
  import Icon from "../lib/ui/Icon.svelte";
  import type { Choice } from "./copy";

  interface Props {
    value: T;
    options: Choice<T>[];
    /* What the control is called, for a screen reader: the row's label. */
    label: string;
    onchange: (value: T) => void;
  }

  let { value, options, label, onchange }: Props = $props();

  const id = $props.id();

  /* A row of the list and the list's inset, as Menu draws them. */
  const ROW = 24;
  const INSET = 4;
  /* An option's words start this far in from the list's edge (the inset, the
     row's padding, the tick's column and its gap); the button's start 12.5 in
     from its own. The difference puts the two on one line. */
  const ALIGN = INSET + 6 + 14 + 5 - 12.5;

  let button = $state(null as HTMLButtonElement | null);
  let list = $state(null as HTMLDivElement | null);
  let open = $state(false);
  let active = $state(0);
  let place = $state({ left: 0, top: 0, width: 0 });

  const chosen = $derived(Math.max(0, options.findIndex((option) => option.value === value)));

  function show() {
    if (!button) return;
    const rect = button.getBoundingClientRect();
    const height = options.length * ROW + INSET * 2;
    const width = rect.width + ALIGN + 8;
    const top = rect.top + (rect.height - ROW) / 2 - INSET - chosen * ROW;
    place = {
      left: Math.min(Math.max(8, rect.left - ALIGN), window.innerWidth - width - 8),
      top: Math.min(Math.max(8, top), window.innerHeight - height - 8),
      width,
    };
    active = chosen;
    open = true;
  }

  function hide(refocus = true) {
    if (!open) return;
    open = false;
    if (refocus) button?.focus();
  }

  function choose(at: number) {
    const option = options[at];
    hide();
    if (option && option.value !== value) onchange(option.value);
  }

  /* The list takes focus so the keys reach it; it is fixed in place, so
     focusing it must not scroll the page under it. */
  $effect(() => {
    if (open) list?.focus({ preventScroll: true });
  });

  function buttonKey(event: KeyboardEvent) {
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      show();
    }
  }

  function listKey(event: KeyboardEvent) {
    switch (event.key) {
      case "ArrowDown":
        active = Math.min(options.length - 1, active + 1);
        break;
      case "ArrowUp":
        active = Math.max(0, active - 1);
        break;
      case "Home":
        active = 0;
        break;
      case "End":
        active = options.length - 1;
        break;
      case "Enter":
      case " ":
        choose(active);
        break;
      case "Escape":
      case "Tab":
        hide();
        break;
      default:
        return;
    }
    event.preventDefault();
    event.stopPropagation();
  }
</script>

<svelte:window onblur={() => hide(false)} onresize={() => hide(false)} />

<button
  bind:this={button}
  class="popup"
  class:open
  aria-haspopup="listbox"
  aria-expanded={open}
  aria-label={label}
  onclick={() => (open ? hide() : show())}
  onkeydown={buttonKey}
>
  <!-- Every option, stacked and unseen, so the button takes the widest. -->
  <span class="labels">
    {#each options as option (option.value)}
      <span class="measure" aria-hidden="true">{option.label}</span>
    {/each}
    <span class="current">{options[chosen]?.label}</span>
  </span>
  <Icon of={ChevronsUpDown} size={12} weight="medium" />
</button>

{#if open}
  <!-- svelte-ignore a11y_no_static_element_interactions -->
  <div class="catcher" onpointerdown={() => hide()}></div>
  <div
    bind:this={list}
    class="list"
    role="listbox"
    tabindex="-1"
    aria-label={label}
    aria-activedescendant="{id}-{active}"
    style:left="{place.left}px"
    style:top="{place.top}px"
    style:min-width="{place.width}px"
    onkeydown={listKey}
  >
    {#each options as option, at (option.value)}
      <!-- svelte-ignore a11y_click_events_have_key_events -->
      <div
        id="{id}-{at}"
        class="option"
        class:active={at === active}
        role="option"
        tabindex="-1"
        aria-selected={option.value === value}
        onpointerenter={() => (active = at)}
        onclick={() => choose(at)}
      >
        <span class="tick">
          {#if option.value === value}
            <Icon of={Check} size={9} weight="semibold" />
          {/if}
        </span>
        <span>{option.label}</span>
      </div>
    {/each}
  </div>
{/if}

<style>
  /* Measured on the Mac: 24 tall, filled in the border grey (#252525 in the
     capture), the label 12.5 in, the chevrons 10.5 from the end and 20 clear
     of the label. Like the app's buttons it answers the press, not the
     pointer passing over. */
  .popup {
    display: inline-flex;
    align-items: center;
    gap: 15px;
    height: 24px;
    padding: 0 6px 0 12.5px;
    border-radius: 6px;
    background: var(--border);
    color: var(--text-primary);
    font: var(--body);
    line-height: 16px;
    white-space: nowrap;
    transition: background-color var(--quick-duration) var(--quick);
  }

  .popup:active,
  .popup.open {
    background: var(--pressed);
  }

  .labels {
    display: grid;
    text-align: left;
  }

  .labels > span {
    grid-area: 1 / 1;
  }

  .measure {
    visibility: hidden;
  }

  .catcher {
    position: fixed;
    inset: 0;
    z-index: 60;
  }

  .list {
    position: fixed;
    z-index: 61;
    display: flex;
    flex-direction: column;
    padding: 4px;
    border-radius: var(--radius-control);
    background: var(--raised);
    box-shadow:
      inset 0 0 0 1px var(--border),
      0 12px 38px rgb(0 0 0 / 0.62),
      0 2px 6px rgb(0 0 0 / 0.5);
    outline: none;
    animation: appear var(--quick-duration) var(--quick);
  }

  .option {
    display: grid;
    grid-template-columns: 14px auto;
    column-gap: 5px;
    align-items: center;
    height: 24px;
    padding: 0 12px 0 6px;
    border-radius: 5px;
    font: var(--body);
    line-height: 16px;
    color: var(--text-primary);
    white-space: nowrap;
  }

  .option.active {
    background: var(--hover);
  }

  .tick {
    display: grid;
    place-items: center;
  }

  @keyframes appear {
    from {
      opacity: 0;
    }
  }
</style>
