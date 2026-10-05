<script lang="ts">
  /* The main window: the Mac's 820 x 560, its caption strip and top bar, the
     two sections, and the transport bar along the bottom. A grid of rows
     rather than heights added up by hand, so the bar can grow when the
     microphone opens without anything below it being pushed off the window. */
  import CaptionStrip from "./lib/shell/CaptionStrip.svelte";
  import TopBar from "./lib/shell/TopBar.svelte";
  import Banners from "./lib/shell/Banners.svelte";
  import RecordBar from "./lib/shell/RecordBar.svelte";
  import DropOverlay from "./lib/shell/DropOverlay.svelte";
  import FirstRun from "./lib/shell/FirstRun.svelte";
  import Transcripts from "./sections/transcripts/Transcripts.svelte";
  import Dictionary from "./sections/dictionary/Dictionary.svelte";
  import EditorSheet from "./sections/dictionary/EditorSheet.svelte";
  import { api } from "./lib/api";
  import { pickRecording } from "./lib/actions";
  import { connect, ui } from "./lib/state.svelte";

  let topBar: TopBar | undefined = $state(undefined);
  /* While the first launch fetches the model, nothing under that screen can
     be reached, by pointer or by keyboard. */
  let firstRun = $state(false);

  $effect(() => connect());

  /* The Mac's menu commands, with Ctrl for Command. */
  function keydown(event: KeyboardEvent) {
    if (ui.editor || firstRun) return;
    const ctrl = event.ctrlKey && !event.altKey && !event.metaKey;
    const key = event.key.toLowerCase();
    if (ctrl && !event.shiftKey && key === "r") {
      event.preventDefault();
      api.toggleDictation();
    } else if (ctrl && event.shiftKey && key === "m") {
      event.preventDefault();
      api.toggleSession();
    } else if (ctrl && !event.shiftKey && key === "l") {
      event.preventDefault();
      api.runLearning();
    } else if (ctrl && !event.shiftKey && key === "o") {
      event.preventDefault();
      pickRecording();
    } else if (ctrl && !event.shiftKey && key === "1") {
      event.preventDefault();
      ui.section = "transcripts";
    } else if (ctrl && !event.shiftKey && key === "2") {
      event.preventDefault();
      ui.section = "dictionary";
    } else if (ctrl && !event.shiftKey && key === "f") {
      event.preventDefault();
      topBar?.focusSearch();
    } else if (ctrl && !event.shiftKey && key === ",") {
      event.preventDefault();
      api.openSettings();
    } else if (event.key === "Escape" && ui.openTranscript) {
      ui.openTranscript = null;
    }
  }

  /* No browser menu on right-click, except in text a person might copy. */
  function contextmenu(event: MouseEvent) {
    const target = event.target as HTMLElement | null;
    if (!target?.closest(".selectable, input, textarea")) event.preventDefault();
  }
</script>

<svelte:window onkeydown={keydown} oncontextmenu={contextmenu} />

<div class="window">
  <CaptionStrip />
  <div class="contents" inert={firstRun}>
    <TopBar bind:this={topBar} />
    <div class="banners"><Banners /></div>
    <main>
      {#key ui.section}
        <div class="section">
          {#if ui.section === "transcripts"}
            <Transcripts />
          {:else}
            <Dictionary />
          {/if}
        </div>
      {/key}
    </main>
    <RecordBar />
  </div>
  <FirstRun bind:showing={firstRun} />
</div>

{#if ui.editor}
  <EditorSheet />
{/if}

{#if !firstRun}
  <DropOverlay />
{/if}

<style>
  .window {
    position: relative;
    display: grid;
    grid-template-rows: auto auto auto minmax(0, 1fr) auto;
    height: 100vh;
    min-width: 0;
  }

  /* Only there to carry `inert`; its children stay rows of the grid. */
  .contents {
    display: contents;
  }

  .banners {
    display: flex;
    flex-direction: column;
  }

  main {
    position: relative;
    min-height: 0;
    display: flex;
    flex-direction: column;
  }

  /* The Mac declares the section swap as a fade with a small rise. */
  .section {
    flex: 1 1 auto;
    min-height: 0;
    display: flex;
    flex-direction: column;
    animation: swap var(--spring-duration) var(--spring);
  }

  @keyframes swap {
    from { opacity: 0; transform: translateY(8px) scale(0.995); }
  }

  @media (prefers-reduced-motion: reduce) {
    .section { animation: none; }
  }
</style>
