<script lang="ts">
  /* Words spoken more than once that no dictionary knows. Finding them needs
     no model: a spell checker and a name detector decide what is unfamiliar,
     and only a person decides what it is. Shown while there is something to
     decide, or something dismissed that could be brought back. */
  import Sparkles from "@lucide/svelte/icons/sparkles";
  import { flip } from "svelte/animate";
  import { fade } from "svelte/transition";
  import Button from "../../lib/ui/Button.svelte";
  import Icon from "../../lib/ui/Icon.svelte";
  import SectionLabel from "../../lib/ui/SectionLabel.svelte";
  import CandidateChip from "./CandidateChip.svelte";
  import Strip from "./Strip.svelte";
  import { api } from "../../lib/api";
  import { core } from "../../lib/state.svelte";
  import { ms, quick, spring, QUICK, SPRING } from "./motion";

  const candidates = $derived(core.suggestions.candidates);
  const suppressed = $derived(core.suggestions.suppressedCount);
</script>

{#if candidates.length > 0 || suppressed > 0}
  <Strip gap={8} appear>
    <div class="head">
      <div class="line">
        <span class="glyph"><Icon of={Sparkles} size={10} /></span>
        <SectionLabel>Heard often, not in any dictionary</SectionLabel>
      </div>
      <div class="line">
        <span class="hint">
          Click one: add it as a word if the spelling is right, or fix it if it's a mis-hearing.
        </span>
        {#if suppressed > 0}
          <Button variant="ghost" tint="var(--live)" onclick={() => api.resetDismissed().catch(() => {})}>
            Show {suppressed} dismissed
          </Button>
        {/if}
      </div>
    </div>

    <div class="scroll">
      <div class="flow">
        {#each candidates as candidate (candidate.word.toLowerCase())}
          <span
            class="item"
            animate:flip={{ duration: ms(SPRING), easing: spring }}
            in:fade={{ duration: ms(SPRING), easing: spring }}
            out:fade={{ duration: ms(QUICK), easing: quick }}
          >
            <CandidateChip {candidate} kind="word" />
          </span>
        {/each}
      </div>
    </div>
  </Strip>
{/if}

<style>
  .head {
    display: flex;
    flex-direction: column;
    gap: 4px;
  }

  .line {
    display: flex;
    align-items: center;
    gap: 6px;
  }

  .glyph {
    flex: none;
    color: var(--live);
  }

  .hint {
    font-size: 11.5px;
    line-height: 1.25;
    color: var(--text-tertiary);
  }

  .scroll {
    max-height: 96px;
    overflow-y: auto;
  }

  .flow {
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
  }

  .item {
    display: flex;
  }
</style>
