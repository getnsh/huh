<script lang="ts">
  /* Shown when a call has started and nothing is capturing it. An offer has
     to be read to be answered, so it is never collapsed to the mark. The whole
     card is a handle, its buttons excepted. */
  import Button from "../lib/ui/Button.svelte";
  import PulsingDot from "../lib/ui/PulsingDot.svelte";
  import { api } from "../lib/api";
  import Card from "./Card.svelte";
  import { movable } from "./movable";

  interface Props {
    /* The app the call is in, as the core names it. */
    app: string;
  }

  let { app }: Props = $props();
</script>

<div class="handle" use:movable>
  <Card width={316}>
    <div class="offer">
      <div class="headline">
        <PulsingDot active size={6} />
        <span class="title">{app} started</span>
      </div>
      <p class="pitch">
        Want huh? to take notes? It transcribes you and the room separately, on this PC.
      </p>
      <div class="actions">
        <Button variant="primary" onclick={() => api.acceptOffer().catch(() => {})}>Listen in</Button>
        <Button variant="ghost" onclick={() => api.declineOffer().catch(() => {})}>Not now</Button>
      </div>
    </div>
  </Card>
</div>

<style>
  .handle {
    touch-action: none;
  }

  .offer {
    display: flex;
    flex-direction: column;
    gap: 14px;
  }

  .headline {
    display: flex;
    align-items: center;
    gap: 8px;
    min-width: 0;
  }

  .title {
    min-width: 0;
    font: var(--medium);
    color: var(--text-primary);
    overflow-wrap: anywhere;
  }

  .pitch {
    margin: 0;
    font-size: 12px;
    line-height: 1.2;
    color: var(--text-secondary);
  }

  .actions {
    display: flex;
    align-items: center;
    gap: 8px;
  }
</style>
