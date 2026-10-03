<script lang="ts">
  /* Where the learning pass is with a transcript. Queued, being read, read
     with something found, and read with nothing found are four different
     states; drawn alike, there would be no telling whether it had run. */
  import Check from "@lucide/svelte/icons/check";
  import Chip from "../../lib/ui/Chip.svelte";
  import Icon from "../../lib/ui/Icon.svelte";
  import Spinner from "../../lib/ui/Spinner.svelte";
  import { core } from "../../lib/state.svelte";
  import type { Transcript } from "../../lib/types";

  let { transcript }: { transcript: Transcript } = $props();

  const reading = $derived(core.learning.analysing === transcript.id);
</script>

{#if reading}
  <span class="reading"><span class="wheel"><Spinner size={9} /></span>reading</span>
{:else if !transcript.analyzedAt}
  <Chip tint="var(--warning)">queued</Chip>
{:else if transcript.analysisFindings > 0}
  <Chip tint="var(--live)">learned {transcript.analysisFindings}</Chip>
{:else}
  <span class="checked" title="Read by the learning pass — nothing new in it">
    <Icon of={Check} size={8} weight="bold" />checked
  </span>
{/if}

<style>
  .reading {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    padding: 3px 7px;
    border-radius: 999px;
    font-weight: 500;
    font-size: 10.5px;
    line-height: 13px;
    color: var(--live);
    background: color-mix(in srgb, var(--live) 12%, transparent);
    white-space: nowrap;
  }

  .wheel {
    display: grid;
    place-items: center;
    width: 10px;
    height: 10px;
  }

  .checked {
    display: inline-flex;
    align-items: center;
    gap: 3px;
    font-size: 10.5px;
    line-height: 13px;
    color: var(--text-tertiary);
    white-space: nowrap;
  }
</style>
