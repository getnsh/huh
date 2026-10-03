<script lang="ts">
  /* The session panel: what sits at the edge of the screen while a session
     runs, or while a call is being offered one.

     It never takes focus. The call being transcribed is in another app, and
     that app has to stay in front. It does take clicks, so its window is
     sized to what it shows and no larger: a transparent margin would be an
     invisible strip swallowing clicks meant for whatever lies behind it.

     The page draws and measures; the core owns the window. It sizes the window
     from what is measured here, around a fixed top-left corner, keeps it on
     screen, moves it while a drag is under way, and slides it in and out. */
  import { api, on } from "../lib/api";
  import type { SessionLevels, SessionState } from "../lib/types";
  import CollapsedMark from "./CollapsedMark.svelte";
  import OfferCard from "./OfferCard.svelte";
  import SessionCard from "./SessionCard.svelte";
  import { dock, rise } from "./motion";

  // Raw, not proxied: each is replaced whole by every event and never changed
  // in place, the levels thirty times a second. Cast rather than annotated,
  // because an annotated `null` still narrows to null.
  let session = $state.raw(null as SessionState | null);
  let levels = $state.raw({ you: [], room: [] } as SessionLevels);
  let root: HTMLDivElement | undefined = $state(undefined);

  $effect(() => {
    // An event that lands before the first read is newer than it.
    let heard = false;
    api
      .session()
      .then((first) => {
        if (!heard) session = first;
      })
      .catch(() => {});
    const stops = [
      on("session", (next) => {
        heard = true;
        // A new session starts from silence, not from the tail of the last.
        if (next.running && !session?.running) levels = { you: [], room: [] };
        session = next;
      }),
      on("session-levels", (next) => (levels = next)),
    ];
    return () => stops.forEach((stop) => stop());
  });

  /* Which face shows. An offer has to be read to be answered, so it is never
     collapsed; otherwise the panel is the mark until it is opened. */
  const face = $derived.by(() => {
    if (!session) return null;
    if (!session.expanded && session.offer === null) return "mark";
    if (session.offer !== null && !session.running) return "offer";
    return "session";
  });

  /* Reports the page's size to the core, which makes the window that size.

     Layout sizes, so a face part-way through a transition is measured as it
     will be rather than as it is drawn. While one face leaves as another
     arrives the two share one cell, so the window holds the larger until the
     leaving one has gone, and nothing is cut off on its way out. */
  $effect(() => {
    const node = root;
    if (!node) return;
    let width = 0;
    let height = 0;
    const observer = new ResizeObserver(([entry]) => {
      // Nothing to show yet: the margin alone is not a size worth sending.
      if (!node.firstElementChild) return;
      const box = entry.borderBoxSize?.[0];
      const w = box ? box.inlineSize : node.offsetWidth;
      const h = box ? box.blockSize : node.offsetHeight;
      if (Math.abs(w - width) <= 0.5 && Math.abs(h - height) <= 0.5) return;
      width = w;
      height = h;
      api.panelMeasured(Math.ceil(w), Math.ceil(h)).catch(() => {});
    });
    observer.observe(node);
    return () => observer.disconnect();
  });
</script>

<div class="root" class:away={!session?.visible} bind:this={root}>
  {#if session && face === "mark"}
    <div class="face" transition:rise={{ scale: 0.86 }}>
      <CollapsedMark {levels} running={session.running} />
    </div>
  {:else if session && face === "offer"}
    <div class="face" transition:dock>
      <OfferCard app={session.offer ?? "A call"} />
    </div>
  {:else if session && face === "session"}
    <div class="face" transition:rise={{ scale: 0.94 }}>
      <SessionCard {session} {levels} />
    </div>
  {/if}
</div>

<style>
  /* Sized by what it holds, never by the window: the window is sized by it.
     The 14 px margin is the room the card's shadow needs, the Mac's figure
     (MARGIN in motion.ts). */
  .root {
    position: absolute;
    top: 0;
    left: 0;
    display: grid;
    width: max-content;
    padding: 14px;
    /* Docking: in from 28 px beyond where it rests, as the Mac's window
       arrives, on the curve kept for exactly this. */
    transition:
      opacity 260ms var(--dock),
      translate 260ms var(--dock);
  }

  /* Hidden, or on its way out: the core hides the window once this has
     played, the Mac's 0.2 s. */
  .root.away {
    opacity: 0;
    translate: 28px 0;
    transition:
      opacity 200ms ease-in-out,
      translate 200ms ease-in-out;
  }

  @media (prefers-reduced-motion: reduce) {
    .root,
    .root.away {
      transition: none;
    }
  }

  /* Faces share one cell, so one arriving and one leaving overlap rather than
     stack. Pinned top-left: the corner the window is anchored by. */
  .face {
    grid-area: 1 / 1;
    justify-self: start;
    align-self: start;
  }
</style>
