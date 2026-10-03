<script lang="ts">
  /* A correction: when the recogniser writes this, write that. The half of
     the dictionary that is a guarantee rather than a hint, so it shows how
     often it has actually fired. */
  import ArrowRight from "@lucide/svelte/icons/arrow-right";
  import Pencil from "@lucide/svelte/icons/pencil";
  import Trash from "@lucide/svelte/icons/trash";
  import Button from "../../lib/ui/Button.svelte";
  import Chip from "../../lib/ui/Chip.svelte";
  import Icon from "../../lib/ui/Icon.svelte";
  import Switch from "../../lib/ui/Switch.svelte";
  import Row from "./Row.svelte";
  import { ui } from "../../lib/state.svelte";
  import type { CorrectionPair } from "../../lib/types";
  import { deleteCorrection, setCorrectionEnabled } from "./actions";

  let { pair }: { pair: CorrectionPair } = $props();

  function edit() {
    ui.editor = {
      mode: "correction",
      id: pair.id,
      hear: pair.hear,
      write: pair.write,
      hitCount: pair.hitCount,
      enabled: pair.enabled,
    };
  }
</script>

<Row>
  <Switch
    checked={pair.enabled}
    label="{pair.hear} to {pair.write}"
    onchange={(on) => setCorrectionEnabled(pair.id, on)}
  />
  <span class="hear" class:off={!pair.enabled}>{pair.hear}</span>
  <span class="arrow"><Icon of={ArrowRight} size={9} weight="semibold" /></span>
  <span class="write" class:off={!pair.enabled}>{pair.write}</span>
  <span class="spacer"></span>
  {#if pair.hitCount > 0}
    <Chip tint="var(--live)">fired {pair.hitCount}×</Chip>
  {/if}

  {#snippet actions()}
    <Button variant="ghost" label="Edit" onclick={edit}>
      <Icon of={Pencil} size={12} weight="medium" />
    </Button>
    <Button variant="ghost" label="Delete" onclick={() => deleteCorrection(pair.id)}>
      <Icon of={Trash} size={12} weight="medium" />
    </Button>
  {/snippet}
</Row>

<style>
  .hear {
    flex: 0 1 auto;
    min-width: 0;
    font: var(--mono);
    color: var(--text-secondary);
    overflow-wrap: anywhere;
  }

  .arrow {
    flex: none;
    color: var(--text-tertiary);
  }

  .write {
    flex: 0 1 auto;
    min-width: 0;
    font: var(--mono);
    font-size: 12.5px;
    font-weight: 500;
    color: var(--text-primary);
    overflow-wrap: anywhere;
  }

  .off {
    color: var(--text-tertiary);
  }

  .spacer {
    flex: 1 1 0;
    min-width: 0;
  }
</style>
