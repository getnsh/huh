<script lang="ts">
  /* A word: a hint to the recogniser and nothing more. Until a correction
     guarantees the spelling the row says "hint only", and offers to write
     that correction, because a hint alone measurably changes very little. */
  import Pencil from "@lucide/svelte/icons/pencil";
  import Trash from "@lucide/svelte/icons/trash";
  import Button from "../../lib/ui/Button.svelte";
  import Chip from "../../lib/ui/Chip.svelte";
  import Icon from "../../lib/ui/Icon.svelte";
  import Switch from "../../lib/ui/Switch.svelte";
  import Row from "./Row.svelte";
  import { core, ui } from "../../lib/state.svelte";
  import type { VocabularyTerm } from "../../lib/types";
  import { deleteTerm, setTermEnabled } from "./actions";
  import { hasCorrectionTargeting } from "./rules";

  let { term }: { term: VocabularyTerm } = $props();

  const hintOnly = $derived(!hasCorrectionTargeting(core.dictionary?.corrections ?? [], term.text));
</script>

<Row>
  <Switch checked={term.enabled} label={term.text} onchange={(on) => setTermEnabled(term.id, on)} />
  <span class="text" class:off={!term.enabled}>{term.text}</span>
  {#if term.note}
    <span class="note">{term.note}</span>
  {/if}
  <span class="spacer"></span>
  {#if hintOnly}
    <Chip
      tint="var(--warning)"
      title="Words are only a hint to the recogniser. Add a correction to guarantee it."
    >
      hint only
    </Chip>
  {/if}

  {#snippet actions()}
    {#if hintOnly}
      <Button
        variant="ghost"
        tint="var(--live)"
        title="Create a correction that always produces “{term.text}”"
        onclick={() => (ui.editor = { mode: "correction", write: term.text })}
      >
        Guarantee
      </Button>
    {/if}
    <Button
      variant="ghost"
      label="Edit"
      onclick={() => (ui.editor = { mode: "word", id: term.id, text: term.text, note: term.note })}
    >
      <Icon of={Pencil} size={12} weight="medium" />
    </Button>
    <Button variant="ghost" label="Delete" onclick={() => deleteTerm(term.id)}>
      <Icon of={Trash} size={12} weight="medium" />
    </Button>
  {/snippet}
</Row>

<style>
  .text {
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

  /* Gives way first: the note truncates long before the word does. */
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
