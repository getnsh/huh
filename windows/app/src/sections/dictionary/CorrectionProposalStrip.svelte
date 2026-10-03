<script lang="ts">
  /* Fixes the reading pass proposes, each waiting for a yes or a no. Always
     there on the Corrections tab, because "nothing found" is an answer worth
     giving: the line under the heading says which kind of nothing it is. */
  import Sparkles from "@lucide/svelte/icons/sparkles";
  import { flip } from "svelte/animate";
  import { fade } from "svelte/transition";
  import Button from "../../lib/ui/Button.svelte";
  import Icon from "../../lib/ui/Icon.svelte";
  import SectionLabel from "../../lib/ui/SectionLabel.svelte";
  import Spinner from "../../lib/ui/Spinner.svelte";
  import ProposalRow from "./ProposalRow.svelte";
  import Strip from "./Strip.svelte";
  import { api } from "../../lib/api";
  import { counted } from "../../lib/format";
  import { core } from "../../lib/state.svelte";
  import { ms, quick, spring, QUICK, SPRING } from "./motion";

  const learning = $derived(core.learning);
  const proposals = $derived(core.suggestions.proposals);

  /* Windows reads without a language model, so the Mac's lines about what
     "the model" sees are cut to what is true here. */
  const hint = $derived.by(() => {
    if (core.history.length === 0) return "Nothing to work with yet — transcribe something first.";
    if (learning.pending > 0) return `${counted(learning.pending, "transcript")} still to read.`;
    if (learning.lastRunFoundNothing || core.suggestions.candidates.length === 0) {
      return "Every transcript has been read and nothing in them looked like a mis-hearing. That's a real answer, not a failure.";
    }
    return `${counted(core.suggestions.candidates.length, "unrecognised word")} are still under review. Anything recognised as a garbled name or product appears here.`;
  });
</script>

<Strip gap={10}>
  <div class="header">
    <span class="glyph"><Icon of={Sparkles} size={10} /></span>
    <SectionLabel>Suggested fixes</SectionLabel>
    <span class="spacer"></span>
    {#if learning.running}
      <span class="stage">
        <Spinner size={16} />
        <span class="stage-text">{learning.stage || "Reading on-device…"}</span>
      </span>
    {:else}
      <Button
        variant="ghost"
        tint="var(--live)"
        disabled={core.history.length === 0}
        onclick={() => api.runLearning().catch(() => {})}
      >
        {learning.pending > 0 ? `Read ${learning.pending} unread` : "Read again"}
      </Button>
    {/if}
  </div>

  {#if proposals.length === 0}
    <p class="hint">{hint}</p>
  {:else}
    <div class="scroll">
      <div class="rows">
        {#each proposals as proposal (proposal.heard.toLowerCase())}
          <div
            animate:flip={{ duration: ms(SPRING), easing: spring }}
            in:fade={{ duration: ms(SPRING), easing: spring }}
            out:fade={{ duration: ms(QUICK), easing: quick }}
          >
            <ProposalRow {proposal} />
          </div>
        {/each}
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
    max-height: 210px;
    overflow-y: auto;
  }

  .rows {
    display: flex;
    flex-direction: column;
    gap: 6px;
  }
</style>
