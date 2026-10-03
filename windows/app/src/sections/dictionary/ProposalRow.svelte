<script lang="ts">
  /* A fix the reading pass proposes: what was heard, in red, and what it
     should be, in the live colour. Nothing is applied until Add, and a fix
     that would also rewrite everyday words says so, in red, before anyone
     can add it — and its Add turns amber. */
  import ArrowRight from "@lucide/svelte/icons/arrow-right";
  import Button from "../../lib/ui/Button.svelte";
  import Chip from "../../lib/ui/Chip.svelte";
  import Icon from "../../lib/ui/Icon.svelte";
  import Alert from "./Alert.svelte";
  import type { Proposal } from "../../lib/types";
  import { acceptProposal, dismissProposal, editProposal, proposalAsPerson } from "./actions";

  let { proposal }: { proposal: Proposal } = $props();

  const dangers = $derived(proposal.warnings.filter((warning) => warning.severity === "danger"));
  const risky = $derived(dangers.length > 0);
</script>

<div class="row hover-card">
  <div class="line">
    <span class="heard">{proposal.heard}</span>
    <span class="arrow"><Icon of={ArrowRight} size={8} weight="semibold" /></span>
    <span class="write">{proposal.write}</span>
    <span class="spacer"></span>
    {#if risky}
      <Chip tint="var(--danger)">risky</Chip>
    {/if}
    <Button
      variant="ghost"
      tint="var(--live)"
      title="File “{proposal.write}” under People instead, where it won't be revised or asked about again."
      onclick={() => proposalAsPerson(proposal.heard)}
    >
      It's a name
    </Button>
    <Button variant="ghost" onclick={() => editProposal(proposal)}>Edit…</Button>
    <Button variant="ghost" onclick={() => dismissProposal(proposal.heard)}>Dismiss</Button>
    <Button
      variant="secondary"
      tint={risky ? "var(--warning)" : "var(--text-primary)"}
      onclick={() => acceptProposal(proposal.heard)}
    >
      Add
    </Button>
  </div>

  <p class="context">“…{proposal.context}…”</p>

  {#each dangers as warning (warning.message)}
    <div class="danger">
      <Alert size={9} behind="var(--raised)" />
      <span>{warning.message}</span>
    </div>
  {/each}
</div>

<style>
  .row {
    display: flex;
    flex-direction: column;
    gap: 6px;
    padding: 8px 10px;
    border-radius: var(--radius-control);
  }

  .line {
    display: flex;
    align-items: center;
    gap: 8px;
    min-width: 0;
  }

  .heard {
    flex: 0 1 auto;
    min-width: 0;
    font: var(--mono);
    color: var(--danger);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
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
    color: var(--live);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .spacer {
    flex: 1 0 8px;
  }

  .context {
    margin: 0;
    font-size: 11px;
    color: var(--text-tertiary);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .danger {
    display: flex;
    align-items: flex-start;
    gap: 6px;
    font-size: 11px;
    line-height: 1.25;
    color: var(--danger);
  }
</style>
