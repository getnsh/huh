<script lang="ts">
  /* The sheet every dictionary entry is written in: a word, a correction or a
     person, added or edited. The drafts are copied from the request once, as
     the Mac copies them, so nothing typed here touches the list until Save,
     and Cancel or Escape leaves everything as it was.

     A correction shows its consequences while it is typed: the literal forms
     the trigger will also catch, and the core's warnings when it would also
     rewrite everyday words. Warnings inform; they never block a save. */
  import Info from "@lucide/svelte/icons/info";
  import Button from "../../lib/ui/Button.svelte";
  import FormField from "../../lib/ui/FormField.svelte";
  import Icon from "../../lib/ui/Icon.svelte";
  import SectionLabel from "../../lib/ui/SectionLabel.svelte";
  import Sheet from "../../lib/ui/Sheet.svelte";
  import Alert from "./Alert.svelte";
  import { api } from "../../lib/api";
  import { core, ui, type EditorRequest } from "../../lib/state.svelte";
  import type { Warning } from "../../lib/types";
  import { dismissPersonProposal, followUp } from "./actions";
  import { catchesVariants, splitAliases } from "./rules";

  // App mounts the sheet only while a request stands.
  const request: EditorRequest = ui.editor ?? { mode: "word" };
  const editing = request.id !== undefined;

  /* The name the reading pass asked about, if this editor is the answer. */
  const answering = followUp.personProposal;
  followUp.personProposal = null;

  const TITLES = {
    word: ["Add Word", "Edit Word"],
    correction: ["Add Correction", "Edit Correction"],
    person: ["Add Person", "Edit Person"],
  } as const;
  const title = TITLES[request.mode][editing ? 1 : 0];

  const initial = {
    text: request.mode === "word" ? (request.text ?? "") : "",
    note: request.mode === "correction" ? "" : (request.note ?? ""),
    hear: request.mode === "correction" ? (request.hear ?? "") : "",
    write: request.mode === "correction" ? (request.write ?? "") : "",
    name: request.mode === "person" ? (request.name ?? "") : "",
    aliases: request.mode === "person" ? (request.aliases ?? "") : "",
  };

  /* The passage the word was heard in, when the editor was opened to fix
     one, so the replacement is chosen with the sentence in view. */
  const context = request.mode === "correction" ? (request.context ?? "").trim() : "";

  /* The Mac's model fills Write in when a heard word is being fixed; with no
     model here, the caret goes there instead. Otherwise the first field. */
  const focusWrite =
    request.mode === "correction" && initial.hear.trim() !== "" && initial.write.trim() === "";

  let text = $state(initial.text);
  let note = $state(initial.note);
  let hear = $state(initial.hear);
  let write = $state(initial.write);
  let name = $state(initial.name);
  let aliases = $state(initial.aliases);

  const canSave = $derived(
    request.mode === "word"
      ? text.trim() !== ""
      : request.mode === "correction"
        ? hear.trim() !== "" && write.trim() !== ""
        : name.trim() !== "",
  );

  const heardSomething = $derived(hear.trim() !== "");
  const variants = $derived(catchesVariants(hear));

  /* The core's verdict on the rule as typed, asked for on every keystroke.
     Only the newest answer is kept, should two replies cross. */
  let warnings: Warning[] = $state([]);
  let asked = 0;

  $effect(() => {
    if (request.mode !== "correction") return;
    const ticket = ++asked;
    api
      .checkCorrection(hear, write)
      .then((list) => {
        if (ticket === asked) warnings = list;
      })
      .catch(() => {});
  });

  function cancel() {
    ui.editor = null;
  }

  type Draft = {
    text: string;
    note: string;
    hear: string;
    write: string;
    name: string;
    aliases: string[];
  };

  function save() {
    if (!canSave) return;
    const draft: Draft = {
      text: text.trim(),
      note: note.trim(),
      hear: hear.trim(),
      write: write.trim(),
      name: name.trim(),
      aliases: splitAliases(aliases),
    };
    ui.editor = null;
    commit(draft).catch(() => {
      // The core refused; show the dictionary as it really is.
      api
        .dictionary()
        .then((value) => (core.dictionary = value))
        .catch(() => {});
    });
  }

  /* Saved through the core's own commands. An edit is laid over the entry as
     it stands now rather than as it stood when the sheet opened, so a hit
     counted or a switch flipped in the meantime is kept. */
  async function commit(draft: Draft): Promise<void> {
    switch (request.mode) {
      case "word": {
        if (request.id === undefined) return api.addTerm(draft.text, draft.note);
        const id = request.id;
        const term = core.dictionary?.terms.find((entry) => entry.id === id);
        if (term) await api.updateTerm({ ...$state.snapshot(term), text: draft.text, note: draft.note });
        return;
      }
      case "correction": {
        if (request.id === undefined) return api.addCorrection(draft.hear, draft.write);
        const id = request.id;
        const pair = core.dictionary?.corrections.find((entry) => entry.id === id);
        return api.updateCorrection({
          enabled: pair?.enabled ?? request.enabled ?? true,
          hear: draft.hear,
          hitCount: pair?.hitCount ?? request.hitCount ?? 0,
          id,
          write: draft.write,
        });
      }
      case "person": {
        if (request.id !== undefined) {
          const id = request.id;
          const person = core.dictionary?.people.find((entry) => entry.id === id);
          if (person) {
            await api.updatePerson({
              ...$state.snapshot(person),
              name: draft.name,
              aliases: draft.aliases,
              note: draft.note,
            });
          }
          return;
        }
        await api.addPerson(draft.name, draft.aliases, draft.note);
        // The question is answered by what was just saved; it is not asked again.
        if (answering) dismissPersonProposal(answering);
      }
    }
  }
</script>

<Sheet width={460} canSubmit={canSave} onsubmit={save} oncancel={cancel}>
  <div class="editor">
    <h2 class="title">{title}</h2>

    {#if request.mode === "person"}
      <FormField label="Name" placeholder="Ada Okonkwo" bind:value={name} autofocus />
      <FormField label="Also heard as" placeholder="Ayda, Ada Oconquo" mono bind:value={aliases} />
      <FormField label="Note (optional)" placeholder="who they are" bind:value={note} />
      <p class="explain">
        Names are kept apart from the dictionary on purpose. Once a name is right it should stay that
        way, so nothing here is revised by a later pass and you won't be asked about it again. Each
        spelling under “also heard as” is rewritten to the name, and the name itself is passed to the
        recogniser as a hint.
      </p>
    {:else if request.mode === "correction"}
      <FormField
        label="When you hear"
        placeholder="super base"
        mono
        bind:value={hear}
        autofocus={!focusWrite}
      />

      {#if context}
        <div class="came-up">
          <SectionLabel>Where it came up</SectionLabel>
          <p class="context">“…{context}…”</p>
        </div>
      {/if}

      <FormField label="Write" placeholder="Supabase" mono bind:value={write} autofocus={focusWrite} />

      {#if heardSomething}
        <p class="aside">
          Type the replacement as it should be written.
        </p>

        <div class="catches">
          <span class="caption">Also catches</span>
          <div class="variants">
            {#each variants as variant (variant)}
              <span class="variant">{variant}</span>
            {/each}
          </div>
          <p class="rule">Case-insensitive, whole words only — never inside a longer word.</p>
        </div>
      {/if}

      {#each warnings as warning (warning.message)}
        <div
          class="warning"
          class:danger={warning.severity === "danger"}
          class:caution={warning.severity === "caution"}
        >
          {#if warning.severity === "danger"}
            <Alert size={11} behind="color-mix(in srgb, var(--danger) 10%, var(--surface))" />
          {:else}
            <Icon of={Info} size={11} />
          {/if}
          <span class="message">{warning.message}</span>
        </div>
      {/each}
    {:else}
      <FormField label="Word or phrase" placeholder="Supabase" bind:value={text} autofocus />
      <FormField label="Note (optional)" placeholder="what it is" bind:value={note} />
      <p class="explain">
        Words are passed to the recogniser before it transcribes, so it leans toward producing them.
        Measured on clean audio, this changed nothing at all — treat it as a nudge and add a correction
        for anything that actually matters.
      </p>
    {/if}

    <div class="buttons">
      <Button variant="secondary" onclick={cancel}>Cancel</Button>
      <Button variant="primary" disabled={!canSave} onclick={save}>Save</Button>
    </div>
  </div>
</Sheet>

<style>
  .editor {
    display: flex;
    flex-direction: column;
    gap: 18px;
    padding: 22px;
  }

  .title {
    margin: 0;
    font: var(--title);
    font-size: 17px;
    color: var(--text-primary);
  }

  /* Running text wraps on the Mac's measured 15 px lines at 12 px. */
  .explain {
    margin: 0;
    font-size: 12px;
    line-height: 1.25;
    color: var(--text-tertiary);
  }

  .came-up {
    display: flex;
    flex-direction: column;
    gap: 4px;
  }

  .context {
    margin: 0;
    padding: 9px;
    border-radius: 6px;
    font-size: 12px;
    line-height: 1.25;
    color: var(--text-secondary);
    background: var(--base);
  }

  .aside {
    margin: 0;
    font-size: 11px;
    line-height: 1.25;
    color: var(--text-tertiary);
  }

  .catches {
    display: flex;
    flex-direction: column;
    gap: 6px;
  }

  .caption {
    font-weight: 500;
    font-size: 11px;
    letter-spacing: 0.6px;
    text-transform: uppercase;
    color: var(--text-tertiary);
  }

  .variants {
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
  }

  .variant {
    padding: 3px 6px;
    border-radius: 4px;
    font: var(--mono);
    color: var(--text-secondary);
    background: var(--raised);
    white-space: pre;
  }

  .rule {
    margin: 0;
    font-size: 11.5px;
    color: var(--text-tertiary);
  }

  .warning {
    display: flex;
    align-items: flex-start;
    gap: 8px;
    padding: 10px;
    border-radius: var(--radius-control);
    font-size: 12px;
    line-height: 1.25;
  }

  .warning.danger {
    color: var(--danger);
    background: color-mix(in srgb, var(--danger) 10%, transparent);
  }

  .warning.caution {
    color: var(--text-secondary);
    background: color-mix(in srgb, var(--text-secondary) 10%, transparent);
  }

  .message {
    flex: 1 1 auto;
    min-width: 0;
  }

  .buttons {
    display: flex;
    justify-content: flex-end;
    gap: 8px;
  }
</style>
