<script lang="ts">
  /* One word the reading pass found, as a capsule that opens its choices.

     A menu rather than icon buttons: the choices are opposites and none of
     them has a conventional icon, so each is written out in full. A word sits
     on the base grey; a name wears the live colour faintly, because it is a
     person rather than a piece of jargon and is filed somewhere else. */
  import ChevronDown from "@lucide/svelte/icons/chevron-down";
  import UserRound from "@lucide/svelte/icons/user-round";
  import Icon from "../../lib/ui/Icon.svelte";
  import Menu, { type MenuItem } from "../../lib/ui/Menu.svelte";
  import type { Candidate } from "../../lib/types";
  import { acceptCandidate, acceptCandidateAsPerson, dismissCandidate, fixHeardWord } from "./actions";

  interface Props {
    candidate: Candidate;
    kind: "word" | "name";
  }

  let { candidate, kind }: Props = $props();

  let button: HTMLButtonElement | undefined = $state(undefined);
  let menu: { x: number; y: number } | null = $state(null);

  const items: MenuItem[] = $derived(
    kind === "word"
      ? [
          { label: `Add “${candidate.word}” as a word`, action: () => acceptCandidate(candidate.word) },
          {
            label: "It's someone's name — remember it",
            action: () => acceptCandidateAsPerson(candidate.word),
          },
          { label: "It's a mis-hearing — fix it…", action: () => fixHeardWord(candidate.word) },
          "separator",
          { label: "Never suggest this", action: () => dismissCandidate(candidate.word) },
        ]
      : [
          {
            label: `Remember “${candidate.word}” as a person`,
            action: () => acceptCandidateAsPerson(candidate.word),
          },
          { label: "The spelling is wrong — fix it…", action: () => fixHeardWord(candidate.word) },
          "separator",
          { label: "Not a name", action: () => dismissCandidate(candidate.word) },
        ],
  );

  // Under the capsule, from its left edge, as a pull-down menu opens.
  function open() {
    if (!button) return;
    const rect = button.getBoundingClientRect();
    menu = { x: rect.left, y: rect.bottom + 4 };
  }
</script>

<button
  bind:this={button}
  class="chip"
  class:named={kind === "name"}
  class:open={menu !== null}
  aria-haspopup="menu"
  aria-expanded={menu !== null}
  onclick={open}
>
  {#if kind === "name" || candidate.isName}
    <span class="person"><Icon of={UserRound} size={kind === "name" ? 9 : 8.5} fill /></span>
  {/if}
  <span class="word">{candidate.word}</span>
  <span class="count">{candidate.count}×</span>
  <span class="chevron"><Icon of={ChevronDown} size={8} weight="semibold" /></span>
</button>

{#if menu}
  <Menu {items} x={menu.x} y={menu.y} onclose={() => (menu = null)} />
{/if}

<style>
  /* A word: the base grey with a soft hairline, a step up under the pointer
     and while its menu is open. */
  .chip {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 6px 10px;
    border-radius: 999px;
    white-space: nowrap;
    background: var(--base);
    box-shadow: inset 0 0 0 1px var(--border-soft);
    transition:
      background-color var(--quick-duration) var(--quick),
      box-shadow var(--quick-duration) var(--quick);
  }

  .chip:hover,
  .chip.open {
    background: var(--hover);
    box-shadow: inset 0 0 0 1px var(--border);
  }

  .chip.named {
    background: color-mix(in srgb, var(--live) 8%, transparent);
    box-shadow: inset 0 0 0 1px color-mix(in srgb, var(--live) 28%, transparent);
  }

  .chip.named:hover,
  .chip.named.open {
    background: color-mix(in srgb, var(--live) 16%, transparent);
    box-shadow: inset 0 0 0 1px color-mix(in srgb, var(--live) 50%, transparent);
  }

  .word {
    font: var(--medium);
    font-size: 12.5px;
    color: var(--text-primary);
  }

  .count {
    font-size: 10px;
    color: var(--text-tertiary);
  }

  .chevron {
    color: var(--text-tertiary);
  }

  .person {
    color: var(--live);
  }
</style>
