<script lang="ts">
  /* A switch and what it does: a title, and when there is more to say, a
     smaller line under it. The switch is pushed to the far end, as the Mac
     pushes it with a spacer, so every switch in a card lines up. */
  import Switch from "../lib/ui/Switch.svelte";

  interface Props {
    title: string;
    detail?: string;
    checked: boolean;
    /* The least room kept between the words and the switch: 10 where the
       Mac asks for it, its default 8 where it does not. */
    spacing?: number;
    onchange: (checked: boolean) => void;
  }

  let { title, detail, checked, spacing = 10, onchange }: Props = $props();
</script>

<div class="row">
  <span class="words">
    <span class="title">{title}</span>
    {#if detail}
      <span class="detail">{detail}</span>
    {/if}
  </span>
  <span class="spacer" style:min-width="{spacing}px"></span>
  <Switch size="small" {checked} label={title} {onchange} />
</div>

<style>
  .row {
    display: flex;
    align-items: center;
  }

  .words {
    display: flex;
    flex-direction: column;
    gap: 2px;
    min-width: 0;
  }

  .title {
    font: var(--body);
    line-height: 16px;
    color: var(--text-secondary);
  }

  .detail {
    font-size: 11px;
    line-height: 13px;
    color: var(--text-tertiary);
  }

  .spacer {
    flex: 1 1 auto;
  }
</style>
