<script lang="ts">
  /* The strip the Mac's traffic lights sit in, with Windows' caption buttons
     at its other end, because that is where a Windows hand goes. No title is
     drawn, as the Mac draws none. The whole strip drags the window and a
     double-click on it maximises, which is what keeps Snap Layouts working in
     a frameless window. Close hides the window: the key keeps working, and
     the tray brings it back.

     Settings sits beside them. The Mac reaches it from the menu bar, which a
     Windows window does not have; the tray and Ctrl+, reach it too. */
  import { getCurrentWindow } from "@tauri-apps/api/window";
  import Cog from "@lucide/svelte/icons/settings";
  import Icon from "../ui/Icon.svelte";
  import { api } from "../api";

  const win = getCurrentWindow();

  let maximised = $state(false);

  $effect(() => {
    let stop: (() => void) | undefined;
    let gone = false;
    const look = () => win.isMaximized().then((value) => (maximised = value)).catch(() => {});
    look();
    win
      .onResized(look)
      .then((unlisten) => (gone ? unlisten() : (stop = unlisten)))
      .catch(() => {});
    return () => {
      gone = true;
      stop?.();
    };
  });
</script>

<header data-tauri-drag-region>
  <div class="controls">
    <button
      class="cap settings"
      title="Settings (Ctrl+,)"
      aria-label="Settings"
      onclick={() => api.openSettings()}
    >
      <Icon of={Cog} size={10} />
    </button>
    <button class="cap" title="Minimise" aria-label="Minimise" onclick={() => win.minimize()}>
      <svg viewBox="0 0 10 10"><path d="M1 5h8" /></svg>
    </button>
    <button
      class="cap"
      title={maximised ? "Restore" : "Maximise"}
      aria-label={maximised ? "Restore" : "Maximise"}
      onclick={() => win.toggleMaximize()}
    >
      {#if maximised}
        <svg viewBox="0 0 10 10">
          <rect x="1" y="2.5" width="6.5" height="6.5" rx="1" />
          <path d="M3 2.5V2a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v4a1 1 0 0 1-1 1h-.5" />
        </svg>
      {:else}
        <svg viewBox="0 0 10 10"><rect x="1" y="1" width="8" height="8" rx="1" /></svg>
      {/if}
    </button>
    <button class="cap close" title="Close" aria-label="Close" onclick={() => win.hide()}>
      <svg viewBox="0 0 10 10"><path d="M1.5 1.5l7 7M8.5 1.5l-7 7" /></svg>
    </button>
  </div>
</header>

<style>
  header {
    display: flex;
    justify-content: flex-end;
    height: 32px;
    background: var(--surface);
  }

  .controls {
    display: flex;
    height: 100%;
  }

  .cap {
    width: 46px;
    display: grid;
    place-items: center;
    color: var(--text-secondary);
    transition:
      background-color var(--quick-duration) var(--quick),
      color var(--quick-duration) var(--quick);
  }

  .cap:hover {
    background: var(--hover);
    color: var(--text-primary);
  }

  .cap:active { background: var(--pressed); }
  .cap.close:hover { background: var(--danger); }

  svg {
    width: 10px;
    height: 10px;
    fill: none;
    stroke: currentColor;
    stroke-width: 1.2;
    stroke-linecap: round;
  }
</style>
