<script lang="ts">
  /* A summary, drawn from the Markdown the model writes, as the Mac's
     MarkdownBlock draws it: a heading becomes a section label, a bullet a
     grey dot beside its text, anything else a paragraph, all 5 apart. Within
     a line, strong, emphasis and code are styled and everything else is the
     literal text; markdown.ts says how it is read. Every run is drawn as
     text, never as markup, so nothing a model writes can reach the page as
     HTML. The words can be selected and copied, as on the Mac. */
  import SectionLabel from "../../lib/ui/SectionLabel.svelte";
  import { inline, lines } from "./markdown";

  let { text }: { text: string } = $props();

  const parsed = $derived(lines(text));
</script>

<!-- One line of markup per run: the text keeps its spaces, so any between
     the tags would show. -->
{#snippet runs(source: string)}
  {#each inline(source) as run}<span class:strong={run.strong} class:em={run.em} class:code={run.code}
      >{run.text}</span
    >{/each}
{/snippet}

<div class="markdown selectable">
  {#each parsed as line}
    {#if line.kind === "heading"}
      <div class="heading"><SectionLabel>{line.text}</SectionLabel></div>
    {:else if line.kind === "bullet"}
      <div class="bullet">
        <span class="dot">•</span>
        <p class="text">{@render runs(line.text)}</p>
      </div>
    {:else}
      <p class="text">{@render runs(line.text)}</p>
    {/if}
  {/each}
</div>

<style>
  /* 12.5 pt on the Mac's 15 pt leading, wrapped lines included. */
  .markdown {
    display: flex;
    flex-direction: column;
    gap: 5px;
    font-size: 12.5px;
    line-height: 15px;
    color: var(--text-secondary);
  }

  .heading {
    padding-top: 4px;
  }

  .bullet {
    display: flex;
    align-items: flex-start;
    gap: 7px;
  }

  /* The Mac gives the dot no font of its own, so it is the system's 13 pt
     rather than the text's 12.5, top-aligned with the first line. */
  .dot {
    flex: 0 0 auto;
    font-size: 13px;
    line-height: 16px;
    color: var(--text-tertiary);
  }

  .text {
    flex: 1 1 auto;
    min-width: 0;
    margin: 0;
    white-space: pre-wrap;
    overflow-wrap: anywhere;
  }

  .strong {
    font-weight: 700;
  }

  .em {
    font-style: italic;
  }

  .code {
    font-family: var(--font-mono);
  }
</style>
