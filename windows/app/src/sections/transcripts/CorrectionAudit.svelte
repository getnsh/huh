<script lang="ts">
  /* What the dictionary changed in this transcript: the literal text that
     was replaced, in the danger colour, and what was written instead, in the
     live one. The match itself is kept as evidence, not the rule. */
  import ArrowRight from "@lucide/svelte/icons/arrow-right";
  import Icon from "../../lib/ui/Icon.svelte";
  import SectionLabel from "../../lib/ui/SectionLabel.svelte";
  import type { AppliedCorrection } from "../../lib/types";

  let { corrections }: { corrections: AppliedCorrection[] } = $props();
</script>

<div class="audit">
  <SectionLabel>Dictionary changes</SectionLabel>
  {#each corrections as correction}
    <div class="change">
      <span class="from">{correction.matched}</span>
      <span class="arrow"><Icon of={ArrowRight} size={8} weight="semibold" /></span>
      <span class="to">{correction.write}</span>
    </div>
  {/each}
</div>

<style>
  .audit {
    display: flex;
    flex-direction: column;
    align-items: flex-start;
    gap: 7px;
    padding: 14px 16px;
  }

  .change {
    display: flex;
    align-items: center;
    gap: 7px;
    min-width: 0;
  }

  .from,
  .to {
    font: var(--mono);
    padding: 2px 5px;
    border-radius: 4px;
  }

  .from {
    color: var(--danger);
    background: color-mix(in srgb, var(--danger) 10%, transparent);
  }

  .to {
    color: var(--live);
    background: color-mix(in srgb, var(--live) 10%, transparent);
  }

  .arrow {
    color: var(--text-tertiary);
  }
</style>
