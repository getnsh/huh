<script lang="ts">
  /* A group as the Mac's SettingsView draws one: a spaced capital heading,
     then, 12 below it, a card holding the group's controls 12 apart.

     The heading is drawn here rather than with SectionLabel. That is the
     list label, at 10.5 with 0.6 tracking; Settings sets its headings at 11
     with 0.7. The card's hairline is a shadow rather than a border so it sits
     inside the 16 of padding, where the Mac's strokeBorder draws it. */
  import type { Snippet } from "svelte";

  interface Props {
    title: string;
    children: Snippet;
  }

  let { title, children }: Props = $props();

  const id = $props.id();
</script>

<section class="group" aria-labelledby={id}>
  <h2 class="title" {id}>{title}</h2>
  <div class="card">
    {@render children()}
  </div>
</section>

<style>
  .group {
    display: flex;
    flex-direction: column;
    gap: 12px;
  }

  .title {
    margin: 0;
    font-weight: 500;
    font-size: 11px;
    line-height: 13px;
    letter-spacing: 0.7px;
    text-transform: uppercase;
    color: var(--text-tertiary);
  }

  .card {
    display: flex;
    flex-direction: column;
    gap: 12px;
    padding: 16px;
    border-radius: var(--radius-card);
    background: var(--surface);
    box-shadow: inset 0 0 0 1px var(--border);
  }
</style>
