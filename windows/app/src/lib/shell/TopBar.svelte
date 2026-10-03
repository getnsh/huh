<script lang="ts">
  /* The bar under the caption strip: the mark, the two sections, search, and
     the one thing to do next — transcribe a recording, or add to the
     dictionary. The 70 px at its start is the Mac's, kept so the bar sits as
     it does there. */
  import AudioLines from "@lucide/svelte/icons/audio-lines";
  import Plus from "@lucide/svelte/icons/plus";
  import Button from "../ui/Button.svelte";
  import Icon from "../ui/Icon.svelte";
  import SearchField from "../ui/SearchField.svelte";
  import SectionSwitcher from "./SectionSwitcher.svelte";
  import LearnButton from "./LearnButton.svelte";
  import { pickRecording } from "../actions";
  import { core, ui } from "../state.svelte";

  let search: SearchField | undefined = $state(undefined);

  export function focusSearch() {
    search?.focus();
  }

  const ADD_TITLES = { words: "Add a word", corrections: "Add a correction", people: "Add a person" };
  const MODES = { words: "word", corrections: "correction", people: "person" } as const;

  const jobRunning = $derived(core.fileJob.kind === "running");
</script>

<div class="bar">
  <span class="lead"></span>
  <span class="mark"><Icon of={AudioLines} size={12.5} weight="medium" /></span>
  <SectionSwitcher />
  <span class="spacer" data-tauri-drag-region></span>

  {#if ui.section === "transcripts"}
    <SearchField bind:this={search} bind:value={ui.transcriptQuery} placeholder="Search everything" />
  {:else}
    <SearchField bind:this={search} bind:value={ui.dictionaryQuery} placeholder="Search dictionary" />
  {/if}

  <LearnButton />

  {#if ui.section === "transcripts"}
    <Button
      variant="secondary"
      title="Transcribe a recording  Ctrl+O"
      label="Transcribe a recording"
      disabled={jobRunning}
      onclick={pickRecording}
    >
      <span class="badged">
        <Icon of={AudioLines} size={12} weight="semibold" />
        <span class="plus"><Icon of={Plus} size={6} weight="bold" /></span>
      </span>
    </Button>
  {:else}
    <Button
      variant="primary"
      title={ADD_TITLES[ui.tab]}
      label={ADD_TITLES[ui.tab]}
      onclick={() => (ui.editor = { mode: MODES[ui.tab] })}
    >
      <Icon of={Plus} size={12} weight="bold" />
    </Button>
  {/if}
</div>

<style>
  .bar {
    display: flex;
    align-items: center;
    gap: 12px;
    height: 48px;
    padding: 0 14px;
    background: var(--surface);
    box-shadow: inset 0 -1px 0 var(--border);
    min-width: 0;
  }

  .lead {
    width: 70px;
    flex: 0 1 70px;
    min-width: 0;
  }

  .mark {
    color: var(--text-secondary);
    flex: 0 0 auto;
  }

  .spacer {
    flex: 1 1 auto;
    min-width: 0;
    align-self: stretch;
  }

  /* waveform.badge.plus: the mark with a small plus on its shoulder. */
  .badged {
    position: relative;
    display: grid;
    place-items: center;
    width: 15px;
    height: 15px;
  }

  .plus {
    position: absolute;
    right: -4px;
    bottom: -3px;
    display: grid;
    place-items: center;
    width: 9px;
    height: 9px;
    border-radius: 50%;
    background: currentColor;
  }

  .plus :global(svg) {
    color: var(--raised);
  }
</style>
