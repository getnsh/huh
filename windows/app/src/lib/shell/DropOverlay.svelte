<script lang="ts">
  /* Drag a recording over the window and the window says what it will do
     with it. Only the first file is taken, as on the Mac. */
  import AudioLines from "@lucide/svelte/icons/audio-lines";
  import { getCurrentWebview } from "@tauri-apps/api/webview";
  import Icon from "../ui/Icon.svelte";
  import { transcribe } from "../actions";

  let shown = $state(false);

  $effect(() => {
    const pending = getCurrentWebview().onDragDropEvent((event) => {
      const kind = event.payload.type;
      if (kind === "enter" || kind === "over") shown = true;
      else if (kind === "leave") shown = false;
      else if (kind === "drop") {
        shown = false;
        const [path] = event.payload.paths;
        if (path) transcribe(path);
      }
    });
    return () => {
      pending.then((off) => off());
    };
  });
</script>

{#if shown}
  <div class="drop">
    <div class="frame"></div>
    <div class="content">
      <span class="glyph"><Icon of={AudioLines} size={28} weight="light" /></span>
      <p class="title">Drop to transcribe</p>
      <p class="detail">Audio or video — meeting recordings, voice memos</p>
    </div>
  </div>
{/if}

<style>
  .drop {
    position: fixed;
    inset: 0;
    z-index: 40;
    display: grid;
    place-items: center;
    background: color-mix(in srgb, var(--base) 85%, transparent);
    animation: fade var(--quick-duration) var(--quick);
    pointer-events: none;
  }

  .frame {
    position: absolute;
    inset: 9px;
    border: 1.5px dashed color-mix(in srgb, var(--live) 55%, transparent);
    border-radius: var(--radius-panel);
  }

  .content {
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 10px;
  }

  .glyph {
    color: var(--live);
  }

  .title {
    margin: 0;
    font: var(--heading);
    color: var(--text-primary);
  }

  .detail {
    margin: 0;
    font-size: 12px;
    color: var(--text-tertiary);
  }

  @keyframes fade {
    from { opacity: 0; }
  }
</style>
