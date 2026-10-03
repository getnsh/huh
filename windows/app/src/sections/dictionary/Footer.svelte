<script lang="ts">
  /* The file the open tab lives in, the way to find it in Explorer, and how
     much of the dictionary the recogniser is actually told. The dictionary
     is documented as editable by hand, so where it is matters as much as
     what is in it. Amber when words are relying on hints alone. */
  import FileText from "@lucide/svelte/icons/file-text";
  import Button from "../../lib/ui/Button.svelte";
  import Icon from "../../lib/ui/Icon.svelte";
  import Truncate from "../../lib/ui/Truncate.svelte";
  import { api } from "../../lib/api";
  import { counted, homeRelative } from "../../lib/format";
  import { core, ui } from "../../lib/state.svelte";

  const dictionary = $derived(core.dictionary);
  const which = $derived(ui.tab === "people" ? ("people" as const) : ("dictionary" as const));
  const path = $derived(
    dictionary ? homeRelative(which === "people" ? dictionary.peoplePath : dictionary.dictionaryPath) : "",
  );

  const overflow = $derived(dictionary?.biasOverflow ?? 0);
  const alone = $derived(dictionary?.termsWithoutCorrections ?? 0);
  // "hints" and "rely" stay as the Mac writes them, whatever the count.
  const hints = $derived(
    overflow > 0
      ? `Only the first 40 entries are sent to the recogniser as hints — ${overflow} beyond that rely on corrections.`
      : `${dictionary?.hintCount ?? 0} hints sent to the recogniser · ${counted(alone, "word")} rely on hints alone`,
  );
</script>

<footer class="footer">
  <span class="doc"><Icon of={FileText} size={10.5} /></span>
  {#if path}
    <span class="path"><Truncate text={path} mode="middle" /></span>
    <Button variant="ghost" onclick={() => api.revealFile(which).catch(() => {})}>Reveal</Button>
  {/if}
  <span class="spacer"></span>
  <span class="hints" class:warn={overflow > 0 || alone > 0}>{hints}</span>
</footer>

<style>
  .footer {
    flex: none;
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 9px 16px;
    background: var(--surface);
    box-shadow: inset 0 1px 0 var(--border);
    min-width: 0;
  }

  .doc {
    flex: none;
    color: var(--text-tertiary);
  }

  .path {
    flex: 0 1 auto;
    min-width: 0;
    overflow: hidden;
    font: var(--mono);
    color: var(--text-tertiary);
  }

  .spacer {
    flex: 1 1 0;
    min-width: 0;
  }

  .hints {
    flex: 0 1 auto;
    min-width: 0;
    font-size: 11px;
    line-height: 1.25;
    text-align: right;
    color: var(--text-tertiary);
  }

  .hints.warn {
    color: var(--warning);
  }
</style>
