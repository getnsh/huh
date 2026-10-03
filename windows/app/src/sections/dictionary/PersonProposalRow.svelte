<script lang="ts">
  /* A name the reading pass found, waiting for a person to say what it is.

     When the pass has a better spelling to offer, the row shows the change,
     heard in red and proposed in the live colour, as the Mac's does. When
     its best guess is the word as heard, nothing is claimed: the row asks
     whether this is someone's name at all, and lets the right spelling be
     typed if it is not this one. Either way, known names it might be are
     offered as one-click answers. Whatever is chosen files the heard
     spelling as an alias, so from then on it is corrected without asking. */
  import ArrowRight from "@lucide/svelte/icons/arrow-right";
  import Button from "../../lib/ui/Button.svelte";
  import Icon from "../../lib/ui/Icon.svelte";
  import type { PersonProposal } from "../../lib/types";
  import { acceptPersonProposal, dismissPersonProposal, fixPersonProposal } from "./actions";

  let { proposal }: { proposal: PersonProposal } = $props();

  const same = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();

  /* The pass had nothing better than what it heard. */
  const asking = $derived(same(proposal.heard, proposal.name));
  /* Known spellings, closest first, less whatever the row already shows. */
  const picks = $derived(
    (proposal.alternatives ?? []).filter(
      (pick) => !same(pick, proposal.name) && !same(pick, proposal.heard),
    ),
  );
</script>

<div class="row hover-card">
  <div class="line">
    {#if asking}
      <span class="question">Is “<span class="token">{proposal.heard}</span>” someone's name?</span>
    {:else}
      <span class="heard">{proposal.heard}</span>
      <span class="arrow"><Icon of={ArrowRight} size={8} weight="semibold" /></span>
      <span class="name">{proposal.name}</span>
    {/if}
    {#if proposal.timecode}
      <span class="timecode">{proposal.timecode}</span>
    {/if}
    <span class="spacer"></span>
    {#if asking}
      <Button variant="ghost" onclick={() => fixPersonProposal(proposal, "", proposal.heard)}>
        Wrong spelling — fix it…
      </Button>
      <Button variant="ghost" onclick={() => dismissPersonProposal(proposal.heard)}>Not a name</Button>
      <Button variant="secondary" onclick={() => acceptPersonProposal(proposal.heard, proposal.heard)}>
        Yes — remember it
      </Button>
    {:else}
      <Button variant="ghost" onclick={() => fixPersonProposal(proposal, proposal.name, proposal.heard)}>
        Edit…
      </Button>
      <Button variant="ghost" onclick={() => dismissPersonProposal(proposal.heard)}>Not a name</Button>
      <Button variant="secondary" onclick={() => acceptPersonProposal(proposal.heard, proposal.name)}>
        Add
      </Button>
    {/if}
  </div>

  {#if picks.length > 0}
    <div class="picks">
      <span class="ask">Is it one of these?</span>
      {#each picks as pick (pick)}
        <Button variant="ghost" tint="var(--live)" onclick={() => acceptPersonProposal(proposal.heard, pick)}>
          {pick}
        </Button>
      {/each}
    </div>
  {/if}

  {#if proposal.context}
    <p class="context">“{proposal.context}”</p>
  {/if}
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

  .question {
    flex: 0 1 auto;
    min-width: 0;
    font: var(--medium);
    font-size: 12.5px;
    color: var(--text-primary);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .token {
    font: var(--mono);
    font-size: 12.5px;
    font-weight: 500;
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

  .name {
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

  .timecode {
    flex: none;
    font: var(--mono);
    font-size: 10px;
    color: var(--text-tertiary);
  }

  .spacer {
    flex: 1 0 8px;
  }

  .picks {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 2px;
  }

  .ask {
    margin-right: 4px;
    font-size: 11px;
    color: var(--text-tertiary);
  }

  /* Up to two lines of where it came up, then cut. */
  .context {
    margin: 0;
    font-size: 11px;
    line-height: 1.25;
    color: var(--text-tertiary);
    display: -webkit-box;
    -webkit-line-clamp: 2;
    line-clamp: 2;
    -webkit-box-orient: vertical;
    overflow: hidden;
  }
</style>
