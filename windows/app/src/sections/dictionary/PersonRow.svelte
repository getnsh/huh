<script lang="ts">
  /* A name. The row shows the spellings the recogniser is known to produce
     for this person, because that is the part that does the work: the name
     alone only nudges recognition, while each alias is a guaranteed rewrite.
     With no aliases it is a hint like any word, and says so. */
  import ArrowLeft from "@lucide/svelte/icons/arrow-left";
  import Pencil from "@lucide/svelte/icons/pencil";
  import Trash from "@lucide/svelte/icons/trash";
  import UserRound from "@lucide/svelte/icons/user-round";
  import Button from "../../lib/ui/Button.svelte";
  import Chip from "../../lib/ui/Chip.svelte";
  import Icon from "../../lib/ui/Icon.svelte";
  import Switch from "../../lib/ui/Switch.svelte";
  import Row from "./Row.svelte";
  import { ui } from "../../lib/state.svelte";
  import type { Person } from "../../lib/types";
  import { deletePerson, setPersonEnabled } from "./actions";

  let { person }: { person: Person } = $props();

  function edit() {
    ui.editor = {
      mode: "person",
      id: person.id,
      name: person.name,
      aliases: person.aliases.join(", "),
      note: person.note,
    };
  }
</script>

<Row>
  <Switch checked={person.enabled} label={person.name} onchange={(on) => setPersonEnabled(person.id, on)} />
  <span class="glyph" class:on={person.enabled}><Icon of={UserRound} size={10} fill /></span>
  <span class="name" class:off={!person.enabled}>{person.name}</span>
  {#if person.aliases.length > 0}
    <span class="aliases">
      <Icon of={ArrowLeft} size={8} weight="semibold" />
      <span class="spellings">{person.aliases.join(", ")}</span>
    </span>
  {/if}
  {#if person.note}
    <span class="note">{person.note}</span>
  {/if}
  <span class="spacer"></span>
  {#if person.learned}
    <Chip tint="var(--live)" title="Found by reading a transcript, and confirmed by you.">learned</Chip>
  {/if}
  {#if person.aliases.length === 0}
    <Chip
      tint="var(--warning)"
      title="The recogniser is nudged toward this spelling, but nothing guarantees it. Add what it writes instead under “also heard as”."
    >
      hint only
    </Chip>
  {/if}

  {#snippet actions()}
    <Button variant="ghost" label="Edit" onclick={edit}>
      <Icon of={Pencil} size={12} weight="medium" />
    </Button>
    <Button variant="ghost" label="Delete" onclick={() => deletePerson(person.id)}>
      <Icon of={Trash} size={12} weight="medium" />
    </Button>
  {/snippet}
</Row>

<style>
  /* SF's person.fill at 10 pt is ten points across. Lucide draws the same
     height in a wider box, so the box is trimmed to the Mac's advance and the
     glyph sits centred over it. */
  .glyph {
    flex: none;
    width: 10px;
    display: flex;
    justify-content: center;
    color: var(--text-tertiary);
  }

  .glyph.on {
    color: var(--live);
  }

  .name {
    flex: 0 1 auto;
    min-width: 0;
    font: var(--medium);
    font-size: 13.5px;
    color: var(--text-primary);
    overflow-wrap: anywhere;
  }

  .off {
    color: var(--text-tertiary);
  }

  /* The spellings give way before the name, and the note before both. */
  .aliases {
    flex: 0 50 auto;
    min-width: 0;
    display: flex;
    align-items: center;
    gap: 4px;
    color: var(--text-tertiary);
  }

  .spellings {
    min-width: 0;
    font: var(--mono);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .note {
    flex: 0 100 auto;
    min-width: 0;
    font-size: 12px;
    color: var(--text-tertiary);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .spacer {
    flex: 1 1 0;
    min-width: 0;
  }
</style>
