<script lang="ts">
  /* Learn: read the transcripts for names and words worth teaching it. The
     button carries the queue on its face: how many transcripts are still
     unread, and a count, in the live colour, of what is waiting to be
     reviewed. */
  import Sparkles from "@lucide/svelte/icons/sparkles";
  import Button from "../ui/Button.svelte";
  import Icon from "../ui/Icon.svelte";
  import Spinner from "../ui/Spinner.svelte";
  import { api } from "../api";
  import { core } from "../state.svelte";

  const learning = $derived(core.learning);
  const waiting = $derived(learning.pendingCount > 0);
</script>

<Button
  variant="secondary"
  tint={waiting ? "var(--live)" : "var(--text-secondary)"}
  disabled={learning.running}
  title="Scan your transcripts for words and fixes worth teaching it"
  onclick={() => api.runLearning()}
>
  {#if learning.running}
    <Spinner size={12} />
    <span>Reading…</span>
  {:else}
    <Icon of={Sparkles} size={11} weight="medium" />
    <span>Learn</span>
    {#if learning.pending > 0}
      <span class="queued">{learning.pending} queued</span>
    {/if}
    {#if waiting}
      <span class="badge">{learning.pendingCount}</span>
    {/if}
  {/if}
</Button>

<style>
  .queued {
    font-weight: 500;
    font-size: 10px;
    color: var(--warning);
  }

  .badge {
    font-weight: 600;
    font-size: 10px;
    line-height: 1.2;
    padding: 1px 5px;
    border-radius: 999px;
    color: var(--accent-text);
    background: var(--live);
    animation: arrive var(--spring-duration) var(--spring);
  }

  @keyframes arrive {
    from { opacity: 0; transform: scale(0.6); }
  }
</style>
