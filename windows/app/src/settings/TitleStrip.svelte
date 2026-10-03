<script lang="ts">
  /* The Settings window's title bar. The Mac draws a title here, "huh?
     Settings", and lights only the close button, since Settings can be
     neither minimised nor zoomed; Windows keeps that one caption button, at
     the right, in the main strip's greys. The strip is the window's own
     ground rather than a bar laid on it, as the Mac's is, and it drags the
     window. Closing really closes: nothing in Settings carries on once it is
     shut, unlike the main window, which hides. */
  import { getCurrentWindow } from "@tauri-apps/api/window";
  import { TEXT } from "./copy";

  const win = getCurrentWindow();
</script>

<header data-tauri-drag-region>
  <span class="title" data-tauri-drag-region>{TEXT.title}</span>
  <button class="cap" title="Close" aria-label="Close" onclick={() => win.close()}>
    <svg viewBox="0 0 10 10" aria-hidden="true"><path d="M1.5 1.5l7 7M8.5 1.5l-7 7" /></svg>
  </button>
</header>

<style>
  header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    height: 32px;
    padding-left: 14px;
    background: var(--base);
  }

  .title {
    font-weight: 600;
    font-size: 13px;
    line-height: 1.2;
    color: var(--text-secondary);
  }

  .cap {
    width: 46px;
    height: 100%;
    display: grid;
    place-items: center;
    transition: background-color var(--quick-duration) var(--quick);
  }

  .cap:hover {
    background: var(--danger);
  }

  svg {
    width: 10px;
    height: 10px;
    fill: none;
    stroke: var(--text-secondary);
    stroke-width: 1.2;
    stroke-linecap: round;
  }

  .cap:hover svg {
    stroke: var(--text-primary);
  }
</style>
