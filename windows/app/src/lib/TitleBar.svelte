<script lang="ts">
  /* The window has no system frame, so the drag region and the caption buttons
     are ours. They sit right, in the grey ladder, because that is where a
     Windows hand goes; the Mac's traffic lights would be a costume.
     data-tauri-drag-region is what keeps Snap Layouts and double-click to
     maximise working in a frameless window. */
  import { getCurrentWindow } from "@tauri-apps/api/window";

  const win = getCurrentWindow();
</script>

<header data-tauri-drag-region>
  <span class="name" data-tauri-drag-region>huh?</span>
  <div class="controls">
    <button class="cap" title="Minimise" onclick={() => win.minimize()} aria-label="Minimise">
      <svg viewBox="0 0 10 10"><path d="M1 5h8" /></svg>
    </button>
    <button class="cap" title="Maximise" onclick={() => win.toggleMaximize()} aria-label="Maximise">
      <svg viewBox="0 0 10 10"><rect x="1" y="1" width="8" height="8" rx="1" /></svg>
    </button>
    <button class="cap close" title="Close" onclick={() => win.hide()} aria-label="Close">
      <svg viewBox="0 0 10 10"><path d="M1.5 1.5l7 7M8.5 1.5l-7 7" /></svg>
    </button>
  </div>
</header>

<style>
  header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    height: 38px;
    padding-left: 14px;
    background: var(--surface);
    border-bottom: 1px solid var(--border);
    flex: 0 0 auto;
  }

  .name {
    font: var(--medium);
    color: var(--text-secondary);
  }

  .controls {
    display: flex;
    height: 100%;
  }

  .cap {
    width: 46px;
    display: grid;
    place-items: center;
    transition: background var(--quick-duration) var(--quick);
  }

  .cap:hover { background: var(--hover); }
  .cap:active { background: var(--pressed); }
  .cap.close:hover { background: var(--danger); }

  svg {
    width: 10px;
    height: 10px;
    fill: none;
    stroke: var(--text-secondary);
    stroke-width: 1.2;
    stroke-linecap: round;
  }

  .cap:hover svg { stroke: var(--text-primary); }
</style>
