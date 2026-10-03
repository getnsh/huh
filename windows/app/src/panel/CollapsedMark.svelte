<script lang="ts">
  /* The collapsed panel: the product mark, and nothing else.

     What sits at the edge of the screen for an hour should say two things and
     no more: this is running, and someone is talking. The mark says both, and
     takes the colour of whichever side is louder, so a glance tells you the
     call is still going and who has the floor. Everything else is one click
     away; a drag moves it instead.

     Flat and opaque on a short shadow. A blur would pick up what is behind it
     and a wide shadow would spread a halo, and against a light window the two
     together read as a smudge round the mark. */
  import SpeakingMark from "../lib/ui/SpeakingMark.svelte";
  import { api } from "../lib/api";
  import type { SessionLevels } from "../lib/types";
  import { movable } from "./movable";

  interface Props {
    levels: SessionLevels;
    running: boolean;
  }

  let { levels, running }: Props = $props();

  /* The two streams as one trace, since the mark has room for one voice: the
     louder of the two at each moment, over the span both cover. */
  const history = $derived.by(() => {
    const { you, room } = levels;
    if (you.length === 0) return room;
    if (room.length === 0) return you;
    const count = Math.min(you.length, room.length);
    return Array.from({ length: count }, (_, i) =>
      Math.max(you[you.length - count + i], room[room.length - count + i]),
    );
  });

  /* Whose colour, decided on the levels rather than on the words, so it moves
     with the voice instead of trailing the recogniser by a second. A tie goes
     to the room, as on the Mac. */
  const accent = $derived.by(() => {
    const recent = (trace: number[]) => Math.max(0, ...trace.slice(-4));
    return recent(levels.you) > recent(levels.room) ? "var(--live)" : "var(--live-soft)";
  });

  const open = () => api.setPanelExpanded(true).catch(() => {});
</script>

<div
  class="mark"
  role="button"
  tabindex="0"
  aria-label="Open the session"
  title="Click to open, drag to move"
  use:movable={{ onClick: open }}
  onkeydown={(event) => {
    if (event.key === "Enter" || event.key === " ") {
      event.preventDefault();
      open();
    }
  }}
>
  <SpeakingMark {history} active={running} {accent} />
</div>

<style>
  /* 20 pt of mark in 12 pt and 18 pt of padding: a 67.5 × 44 capsule. */
  .mark {
    display: flex;
    align-items: center;
    padding: 12px 18px;
    border-radius: 999px;
    background: var(--raised);
    box-shadow:
      inset 0 0 0 1px var(--border),
      0 2px 5px rgb(0 0 0 / 0.28);
    touch-action: none;
    transition:
      transform var(--quick-duration) var(--quick),
      box-shadow var(--quick-duration) var(--quick);
  }

  /* It answers the pointer, as nothing else in the app does: the mark is the
     whole of the control, and it is small. The hairline steps to the hover
     grey, as the Mac's does. */
  .mark:hover {
    transform: scale(1.045);
    box-shadow:
      inset 0 0 0 1px var(--hover),
      0 2px 5px rgb(0 0 0 / 0.28);
  }
</style>
