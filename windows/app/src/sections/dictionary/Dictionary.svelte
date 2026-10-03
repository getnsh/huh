<script lang="ts">
  /* The Dictionary: three tabs, the banners that say what has just happened
     to the files, the reading pass's suggestions for the open tab, the list
     itself, and the file it all lives in along the bottom.

     As on the Mac, a search narrows the list but never the counts, and a list
     with nothing to show says what belongs in it rather than staying blank.
     The suggestions sit above the list and do not scroll with it: they are
     the questions, and the list is the answers so far. */
  import BookA from "@lucide/svelte/icons/book-a";
  import RefreshCw from "@lucide/svelte/icons/refresh-cw";
  import Undo2 from "@lucide/svelte/icons/undo-2";
  import Users from "@lucide/svelte/icons/users";
  import Button from "../../lib/ui/Button.svelte";
  import EmptyState from "../../lib/ui/EmptyState.svelte";
  import Icon from "../../lib/ui/Icon.svelte";
  import Alert from "./Alert.svelte";
  import CorrectionProposalStrip from "./CorrectionProposalStrip.svelte";
  import CorrectionRow from "./CorrectionRow.svelte";
  import Footer from "./Footer.svelte";
  import PersonProposalStrip from "./PersonProposalStrip.svelte";
  import PersonRow from "./PersonRow.svelte";
  import SuggestionStrip from "./SuggestionStrip.svelte";
  import Tabs from "./Tabs.svelte";
  import TermRow from "./TermRow.svelte";
  import { core, ui } from "../../lib/state.svelte";
  import { dismissRetroNote } from "./actions";
  import { contains } from "./rules";

  const dictionary = $derived(core.dictionary);
  const query = $derived(ui.dictionaryQuery.trim().toLocaleLowerCase());

  const terms = $derived.by(() => {
    const all = dictionary?.terms ?? [];
    if (!query) return all;
    return all.filter((term) => contains(term.text, query) || contains(term.note, query));
  });

  const corrections = $derived.by(() => {
    const all = dictionary?.corrections ?? [];
    if (!query) return all;
    return all.filter((pair) => contains(pair.hear, query) || contains(pair.write, query));
  });

  const people = $derived.by(() => {
    const all = dictionary?.people ?? [];
    if (!query) return all;
    return all.filter(
      (person) =>
        contains(person.name, query) ||
        contains(person.note, query) ||
        person.aliases.some((alias) => contains(alias, query)),
    );
  });
</script>

<div class="dictionary">
  <Tabs />

  <!-- A file that could not be read is never written over, so this is the
       only sign that edits here are not being kept. -->
  {#if dictionary?.loadError}
    <div class="notice failed">
      <Alert size={11} behind="color-mix(in srgb, var(--danger) 10%, var(--base))" />
      <span class="message">{dictionary.loadError}</span>
    </div>
  {/if}

  <!-- What the last correction changed in transcripts already kept: a new
       rule fixes the past as well as the future. -->
  {#if dictionary?.retroNote}
    <div class="notice retro">
      <span class="undo"><Icon of={Undo2} size={6.5} weight="bold" /></span>
      <span class="message">{dictionary.retroNote}</span>
      <span class="spacer"></span>
      <Button variant="ghost" onclick={dismissRetroNote}>Dismiss</Button>
    </div>
  {/if}

  {#key ui.tab}
    <div class="pane">
      {#if ui.tab === "words"}
        <SuggestionStrip />
        {#if terms.length === 0}
          <EmptyState
            icon={BookA}
            title="No words yet"
            message="Add names, jargon and product names. They're passed to the recogniser as a hint — but a hint is all they are. Anything it keeps getting wrong needs a correction too."
          />
        {:else}
          <div class="scroll">
            <div class="list">
              {#each terms as term (term.id)}
                <TermRow {term} />
              {/each}
            </div>
          </div>
        {/if}
      {:else if ui.tab === "corrections"}
        <CorrectionProposalStrip />
        {#if corrections.length === 0}
          <EmptyState
            icon={RefreshCw}
            title="No corrections yet"
            message="“When you hear X, write Y.” This runs after transcription and is the reliable half of the dictionary — hints are a nudge, this is a guarantee."
          />
        {:else}
          <div class="scroll">
            <div class="list">
              {#each corrections as pair (pair.id)}
                <CorrectionRow {pair} />
              {/each}
            </div>
          </div>
        {/if}
      {:else}
        <PersonProposalStrip />
        {#if people.length === 0}
          <EmptyState
            icon={Users}
            title="No names yet"
            message="Names live here rather than in the dictionary, because a name settles once and then shouldn't move. Each one biases the recogniser and rewrites the spellings it gets wrong — and once it's here you won't be asked about it again."
          />
        {:else}
          <div class="scroll">
            <div class="list">
              {#each people as person (person.id)}
                <PersonRow {person} />
              {/each}
            </div>
          </div>
        {/if}
      {/if}
    </div>
  {/key}

  <Footer />
</div>

<style>
  .dictionary {
    flex: 1 1 auto;
    min-height: 0;
    display: flex;
    flex-direction: column;
  }

  .notice {
    flex: none;
    display: flex;
    align-items: center;
    margin: 0 16px 10px;
    padding: 9px 12px;
    border-radius: var(--radius-control);
    font-size: 12px;
    line-height: 1.25;
  }

  .failed {
    gap: 8px;
    color: var(--danger);
    background: color-mix(in srgb, var(--danger) 10%, transparent);
  }

  .retro {
    gap: 9px;
    background: color-mix(in srgb, var(--live) 8%, transparent);
    animation: drop var(--spring-duration) var(--spring);
  }

  .message {
    flex: 0 1 auto;
    min-width: 0;
  }

  .retro .message {
    color: var(--text-secondary);
  }

  .spacer {
    flex: 1 0 8px;
  }

  /* arrow.uturn.backward.circle.fill: the arrow cut out of a live disc. */
  .undo {
    flex: none;
    display: grid;
    place-items: center;
    width: 13px;
    height: 13px;
    border-radius: 50%;
    background: var(--live);
    color: color-mix(in srgb, var(--live) 8%, var(--base));
  }

  /* A tab's strip and list arrive together, fading in on the spring. */
  .pane {
    flex: 1 1 auto;
    min-height: 0;
    display: flex;
    flex-direction: column;
    animation: fade var(--spring-duration) var(--spring);
  }

  .scroll {
    flex: 1 1 auto;
    min-height: 0;
    overflow-y: auto;
  }

  .list {
    display: flex;
    flex-direction: column;
    gap: 6px;
    padding: 0 16px 14px;
  }

  @keyframes drop {
    from { opacity: 0; transform: translateY(-8px); }
  }

  @keyframes fade {
    from { opacity: 0; }
  }
</style>
