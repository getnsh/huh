<script lang="ts">
  /* The main window: the same 820 x 560 as the Mac, the same two sections, and
     the same transport bar along the bottom. */
  import { invoke } from "@tauri-apps/api/core";
  import { listen } from "@tauri-apps/api/event";
  import TitleBar from "./lib/TitleBar.svelte";
  import LevelMeter from "./lib/LevelMeter.svelte";

  type Section = "transcripts" | "dictionary";
  type State = { kind: string; message?: string };

  let section = $state<Section>("transcripts");
  let state = $state<State>({ kind: "idle" });
  let history = $state<number[]>([]);
  let transcripts = $state<any[]>([]);

  const live = $derived(state.kind === "listening" || state.kind === "starting");

  $effect(() => {
    invoke<any[]>("get_history").then((value) => (transcripts = value)).catch(() => {});
    const stops = [
      listen<State>("dictation", (event) => (state = event.payload)),
      listen<number[]>("levels", (event) => (history = event.payload)),
    ];
    return () => stops.forEach((stop) => stop.then((off) => off()));
  });

  const status = $derived.by(() => {
    switch (state.kind) {
      case "starting": return "Starting…";
      case "listening": return "Listening";
      case "transcribing": return "Transcribing…";
      case "failed": return state.message ?? "Something went wrong";
      default: return "Ready";
    }
  });
</script>

<TitleBar />

<main>
  <nav>
    <button class:on={section === "transcripts"} onclick={() => (section = "transcripts")}>
      Transcripts
    </button>
    <button class:on={section === "dictionary"} onclick={() => (section = "dictionary")}>
      Dictionary
    </button>
  </nav>

  <section>
    {#if section === "transcripts"}
      {#if transcripts.length === 0}
        <p class="empty">Nothing yet. Hold Right Ctrl and say something.</p>
      {:else}
        <ul>
          {#each transcripts as item (item.id)}
            <li>
              <p class="text">{item.text}</p>
              <p class="meta">{item.engine} &middot; {item.text.split(" ").length} words</p>
            </li>
          {/each}
        </ul>
      {/if}
    {:else}
      <p class="empty">The dictionary lives here.</p>
    {/if}
  </section>
</main>

<footer class:live>
  <LevelMeter {history} active={live} bars={live ? 44 : 22} maxHeight={live ? 26 : 16} />
  <span class="status" class:on={live}>{status}</span>
  <span class="spacer"></span>
  <span class="hint">Hold <kbd>Right Ctrl</kbd></span>
  <button class="primary" onclick={() => invoke("toggle_dictation")}>
    {live ? "Stop" : "Start"}
  </button>
</footer>

<style>
  main {
    display: flex;
    flex-direction: column;
    height: calc(100vh - 38px - 46px);
  }

  nav {
    display: flex;
    gap: 4px;
    padding: 12px 16px;
    flex: 0 0 auto;
  }

  nav button {
    padding: 6px 14px;
    border-radius: var(--radius-control);
    font: var(--medium);
    color: var(--text-secondary);
    transition: background var(--quick-duration) var(--quick);
  }

  nav button:hover { background: var(--hover); }
  nav button.on { background: var(--raised); color: var(--text-primary); }

  section {
    flex: 1 1 auto;
    overflow-y: auto;
    padding: 0 16px 16px;
  }

  ul { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 8px; }

  li {
    padding: 14px 16px;
    background: var(--raised);
    border: 1px solid var(--border);
    border-radius: var(--radius-card);
  }

  .text { margin: 0 0 6px; color: var(--text-primary); user-select: text; }
  .meta { margin: 0; font-size: 11.5px; color: var(--text-tertiary); }
  .empty { color: var(--text-tertiary); padding: 24px 0; }

  footer {
    display: flex;
    align-items: center;
    gap: 14px;
    height: 46px;
    padding: 0 16px;
    background: var(--surface);
    border-top: 1px solid var(--border);
    transition: height var(--spring-duration) var(--spring), background var(--quick-duration) var(--quick);
  }

  footer.live { height: 62px; background: var(--raised); }

  .status { font: var(--medium); font-size: 12.5px; color: var(--text-secondary); }
  .status.on { color: var(--live); }
  .spacer { flex: 1 1 auto; }
  .hint { font-size: 11.5px; color: var(--text-tertiary); }

  kbd {
    font: var(--mono);
    font-size: 10.5px;
    padding: 2px 5px;
    border-radius: 4px;
    background: var(--raised);
    color: var(--text-secondary);
  }

  .primary {
    min-width: 62px;
    padding: 6px 14px;
    border-radius: var(--radius-control);
    background: var(--accent-fill);
    color: var(--accent-text);
    font: var(--medium);
  }

  .primary:active { opacity: 0.85; }
</style>
