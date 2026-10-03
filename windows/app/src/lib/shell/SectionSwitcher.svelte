<script lang="ts">
  /* Two sections and a pill that travels between them on the spring. The
     labels change colour with it, so the eye follows one movement. */
  import TextAlignStart from "@lucide/svelte/icons/text-align-start";
  import BookA from "@lucide/svelte/icons/book-a";
  import Icon from "../ui/Icon.svelte";
  import { ui, type Section } from "../state.svelte";

  const sections: { id: Section; title: string; icon: typeof BookA }[] = [
    { id: "transcripts", title: "Transcripts", icon: TextAlignStart },
    { id: "dictionary", title: "Dictionary", icon: BookA },
  ];

  const index = $derived(sections.findIndex((s) => s.id === ui.section));
</script>

<div class="switcher" role="tablist">
  <span class="indicator" style:transform="translateX({index * 104}px)"></span>
  {#each sections as section}
    <button
      class="segment"
      class:on={ui.section === section.id}
      role="tab"
      aria-selected={ui.section === section.id}
      onclick={() => (ui.section = section.id)}
    >
      <Icon of={section.icon} size={11} weight="medium" />
      <span>{section.title}</span>
    </button>
  {/each}
</div>

<style>
  .switcher {
    position: relative;
    display: flex;
    padding: 2px;
    border-radius: 9px;
    background: var(--base);
    box-shadow: inset 0 0 0 1px var(--border-soft);
    flex: 0 0 auto;
  }

  .indicator {
    position: absolute;
    top: 2px;
    left: 2px;
    width: 104px;
    height: 28px;
    border-radius: 7px;
    background: var(--hover);
    transition: transform var(--spring-duration) var(--spring);
  }

  .segment {
    position: relative;
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 6px;
    width: 104px;
    height: 28px;
    font: var(--medium);
    font-size: 12.5px;
    color: var(--text-tertiary);
    transition: color var(--spring-duration) var(--spring);
  }

  .segment.on {
    color: var(--text-primary);
  }
</style>
