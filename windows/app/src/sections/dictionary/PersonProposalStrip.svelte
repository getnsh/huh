<script lang="ts">
  /* Names found in the transcripts, awaiting a person's word. Two kinds, and
     the difference matters: a name spoken often only needs remembering; a
     name the reading pass stopped on needs its spelling settled. Every one
     is asked about once, and the answer is kept, because a queue that asks
     the same question after every recording is worse than no queue. */
  import CircleUserRound from "@lucide/svelte/icons/circle-user-round";
  import { flip } from "svelte/animate";
  import { fade } from "svelte/transition";
  import Icon from "../../lib/ui/Icon.svelte";
  import SectionLabel from "../../lib/ui/SectionLabel.svelte";
  import Spinner from "../../lib/ui/Spinner.svelte";
  import CandidateChip from "./CandidateChip.svelte";
  import PersonProposalRow from "./PersonProposalRow.svelte";
  import Strip from "./Strip.svelte";
  import { counted } from "../../lib/format";
  import { core } from "../../lib/state.svelte";
  import { ms, quick, spring, QUICK, SPRING } from "./motion";

  const learning = $derived(core.learning);
  const names = $derived(core.suggestions.nameCandidates);
  const proposals = $derived(core.suggestions.personProposals);
  const empty = $derived(names.length === 0 && proposals.length === 0);
</script>

<Strip gap={10}>
  <div class="header">
    <span class="glyph"><Icon of={CircleUserRound} size={10} /></span>
    <SectionLabel>Names found in your transcripts</SectionLabel>
    <span class="spacer"></span>
    {#if learning.running}
      <span class="stage">
        <Spinner size={16} />
        <span class="stage-text">{learning.stage || "Reading…"}</span>
      </span>
    {/if}
  </div>

  {#if empty}
    <p class="hint">
      {learning.pending > 0
        ? `${counted(learning.pending, "transcript")} still to read.`
        : "Nothing waiting. Names turn up here as transcripts are read, and each one is only ever asked about once."}
    </p>
  {:else}
    <div class="scroll">
      <div class="groups">
        {#if names.length > 0}
          <div class="group">
            <p class="caption">Spoken often — someone you know?</p>
            <div class="flow">
              {#each names as candidate (candidate.word.toLowerCase())}
                <span
                  class="item"
                  animate:flip={{ duration: ms(SPRING), easing: spring }}
                  in:fade={{ duration: ms(SPRING), easing: spring }}
                  out:fade={{ duration: ms(QUICK), easing: quick }}
                >
                  <CandidateChip {candidate} kind="name" />
                </span>
              {/each}
            </div>
          </div>
        {/if}

        {#if proposals.length > 0}
          <div class="group">
            {#if names.length > 0}
              <p class="caption second">Heard in a transcript — is it a name?</p>
            {/if}
            <div class="rows">
              {#each proposals as proposal (proposal.heard.toLowerCase())}
                <div
                  animate:flip={{ duration: ms(SPRING), easing: spring }}
                  in:fade={{ duration: ms(SPRING), easing: spring }}
                  out:fade={{ duration: ms(QUICK), easing: quick }}
                >
                  <PersonProposalRow {proposal} />
                </div>
              {/each}
            </div>
          </div>
        {/if}
      </div>
    </div>
  {/if}
</Strip>

<style>
  .header {
    display: flex;
    align-items: center;
    gap: 7px;
    min-width: 0;
  }

  .glyph {
    flex: none;
    color: var(--live);
  }

  .spacer {
    flex: 1 1 0;
    min-width: 0;
  }

  .stage {
    display: flex;
    align-items: center;
    gap: 6px;
    min-width: 0;
  }

  .stage-text {
    min-width: 0;
    font-size: 11px;
    color: var(--text-tertiary);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .hint {
    margin: 0;
    font-size: 11.5px;
    line-height: 1.25;
    color: var(--text-tertiary);
  }

  .scroll {
    max-height: 240px;
    overflow-y: auto;
  }

  .groups {
    display: flex;
    flex-direction: column;
    gap: 10px;
  }

  .group {
    display: flex;
    flex-direction: column;
    gap: 6px;
  }

  .caption {
    margin: 0;
    font-size: 11px;
    color: var(--text-tertiary);
  }

  .caption.second {
    padding-top: 2px;
  }

  .flow {
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
  }

  .item {
    display: flex;
  }

  .rows {
    display: flex;
    flex-direction: column;
    gap: 6px;
  }
</style>
