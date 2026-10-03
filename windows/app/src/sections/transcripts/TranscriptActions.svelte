<script lang="ts">
  /* Copy, share and delete, as the Mac groups them beside every transcript.
     Copy takes the most useful form at once: with timestamps when there is a
     timeline, plain when there is not. Everything else is in the menu.

     Delete is immediate and cannot be undone, as on the Mac; the recording
     itself, if there is one, is not touched. */
  import Copy from "@lucide/svelte/icons/copy";
  import Share from "@lucide/svelte/icons/share";
  import Trash from "@lucide/svelte/icons/trash";
  import Button from "../../lib/ui/Button.svelte";
  import Icon from "../../lib/ui/Icon.svelte";
  import Menu, { type MenuItem } from "../../lib/ui/Menu.svelte";
  import { api } from "../../lib/api";
  import { copy, copyRich, formatsFor, save, sendToGoogleDocs } from "../../lib/exporter";
  import { core, ui } from "../../lib/state.svelte";
  import type { Transcript } from "../../lib/types";
  import { playback, stop } from "./playback.svelte";
  import { portal } from "./portal";

  interface Props {
    transcript: Transcript;
    /* Out: whether the menu is open, so a card that shows these only under
       the pointer keeps them while the pointer is in the menu. */
    menuOpen?: boolean;
  }

  let { transcript, menuOpen = $bindable(false) }: Props = $props();

  let anchor = $state(null as { x: number; y: number } | null);

  const timed = $derived(transcript.segments.length > 0);
  const copyTitle = $derived(timed ? "Copy with timestamps" : "Copy");

  /* Clipboard and dialog failures have nowhere useful to go; the Mac logs
     them and says nothing either. */
  const quietly = (work: Promise<unknown>) => void work.catch(() => {});

  const items: MenuItem[] = $derived([
    { label: "Copy Plain Text", action: () => quietly(copy(transcript, "plain")) },
    ...(timed
      ? [{ label: "Copy with Timestamps", action: () => quietly(copy(transcript, "timestamped")) }]
      : []),
    { label: "Copy as Rich Text", action: () => quietly(copyRich(transcript)) },
    "separator",
    { label: "Send to Google Docs…", action: () => quietly(sendToGoogleDocs(transcript)) },
    "separator",
    {
      label: "Export as",
      children: formatsFor(transcript).map((format) => ({
        label: format.title,
        action: () => quietly(save(transcript, format.id)),
      })),
    },
  ]);

  function openMenu(event: MouseEvent) {
    event.stopPropagation();
    const rect = (event.currentTarget as HTMLElement).getBoundingClientRect();
    anchor = { x: rect.left, y: rect.bottom + 4 };
    menuOpen = true;
  }

  function closeMenu() {
    anchor = null;
    menuOpen = false;
  }

  /* The window closes an open transcript on Escape. While the menu is open,
     Escape belongs to the menu alone, so it is taken before the window's own
     handler can see it. */
  $effect(() => {
    if (!anchor) return;
    const capture = (event: KeyboardEvent) => {
      if (event.key !== "Escape") return;
      event.preventDefault();
      event.stopPropagation();
      closeMenu();
    };
    window.addEventListener("keydown", capture, true);
    return () => window.removeEventListener("keydown", capture, true);
  });

  async function remove(event: MouseEvent) {
    event.stopPropagation();
    const id = transcript.id;
    if (ui.openTranscript === id) ui.openTranscript = null;
    if (playback.transcriptId === id) stop();
    try {
      await api.deleteTranscripts([id]);
      // The core announces the new history; if that has not landed by now,
      // ask for it, so a deleted transcript never lingers on screen.
      if (core.history.some((t) => t.id === id)) core.history = await api.history();
    } catch {
      // Nothing was deleted, and the list still shows it, which is the truth.
    }
  }
</script>

<div class="actions">
  <Button
    variant="ghost"
    title={copyTitle}
    label={copyTitle}
    onclick={(event) => {
      event.stopPropagation();
      quietly(copy(transcript, timed ? "timestamped" : "plain"));
    }}
  >
    <Icon of={Copy} size={12} weight="medium" />
  </Button>

  <span class="share">
    <Button variant="ghost" label="Share" onclick={openMenu}>
      <Icon of={Share} size={12} weight="medium" />
    </Button>
  </span>

  <Button variant="ghost" label="Delete" onclick={remove}>
    <Icon of={Trash} size={12} weight="medium" />
  </Button>
</div>

{#if anchor}
  <div use:portal>
    <Menu {items} x={anchor.x} y={anchor.y} onclose={closeMenu} />
  </div>
{/if}

<style>
  .actions {
    display: flex;
    align-items: center;
    gap: 2px;
    flex: 0 0 auto;
  }

  /* The Mac's menu button is a borderless 22 pt slot, narrower than a ghost
     button's padding would make it. */
  .share :global(.button) {
    width: 22px;
    padding-left: 0;
    padding-right: 0;
  }
</style>
