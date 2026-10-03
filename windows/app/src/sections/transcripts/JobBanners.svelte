<script lang="ts">
  /* A recording being transcribed, then the offer to recycle it, or what
     went wrong. Shown above the list, inline rather than as a dialog: a job
     this long is often left to run unattended, and a dialog that takes focus
     to guard a destructive choice invites the wrong click. */
  import CircleCheck from "@lucide/svelte/icons/circle-check";
  import Trash from "@lucide/svelte/icons/trash";
  import Button from "../../lib/ui/Button.svelte";
  import Icon from "../../lib/ui/Icon.svelte";
  import ProgressBar from "../../lib/ui/ProgressBar.svelte";
  import Spinner from "../../lib/ui/Spinner.svelte";
  import Truncate from "../../lib/ui/Truncate.svelte";
  import { api } from "../../lib/api";
  import { core } from "../../lib/state.svelte";
  import FailureBanner from "./FailureBanner.svelte";
  import { drift } from "./motion";

  const job = $derived(core.fileJob);
</script>

{#if job.kind !== "idle"}
  <div class="jobs" transition:drift={{ y: -8 }}>
    {#if job.kind === "running"}
      <!-- The stage, when the core names one, is kept to the tooltip: the
           Mac's card says only which file and how far. -->
      <div class="card running" title={job.stage || undefined}>
        <div class="line">
          <Spinner />
          <span class="file"><Truncate text={job.name} mode="middle" /></span>
          <span class="spacer"></span>
          <span class="percent">{Math.floor(job.progress * 100)}%</span>
        </div>
        <ProgressBar value={job.progress} />
      </div>
    {:else if job.kind === "done"}
      <div class="card saved">
        <span class="tick"><Icon of={CircleCheck} size={12} fill /></span>
        <span class="column">
          <span class="headline">Transcript saved</span>
          <span class="detail"><Truncate text="Done with {job.name}?" mode="middle" /></span>
        </span>
        <span class="spacer"></span>
        <Button variant="ghost" onclick={() => api.keepOriginal().catch(() => {})}>Keep It</Button>
        <Button variant="secondary" onclick={() => api.recycleOriginal().catch(() => {})}>
          <span class="pair"><Icon of={Trash} size={9.5} weight="semibold" />Move to Recycle Bin</span>
        </Button>
      </div>
    {:else if job.kind === "failed"}
      <FailureBanner message={job.message} ondismiss={() => api.dismissFileFailure().catch(() => {})} />
    {/if}
  </div>
{/if}

<style>
  .jobs {
    display: flex;
    flex-direction: column;
    gap: 8px;
    padding: 12px 16px 0;
    flex: 0 0 auto;
  }

  .card {
    border-radius: var(--radius-card);
  }

  .running {
    display: flex;
    flex-direction: column;
    gap: 8px;
    padding: 12px;
    background: var(--raised);
    box-shadow: inset 0 0 0 1px color-mix(in srgb, var(--live) 30%, transparent);
  }

  .line {
    display: flex;
    align-items: center;
    gap: 9px;
    min-width: 0;
  }

  /* Line heights are the Mac's leading: 15 pt for 12.5 pt text, 14 for 11.5. */
  .file {
    min-width: 0;
    font: var(--medium);
    font-size: 12.5px;
    line-height: 15px;
    color: var(--text-primary);
  }

  .spacer {
    flex: 1 1 8px;
    min-width: 8px;
  }

  .percent {
    flex: 0 0 auto;
    font: var(--mono);
    font-variant-numeric: tabular-nums;
    color: var(--text-tertiary);
  }

  .saved {
    display: flex;
    align-items: center;
    gap: 11px;
    padding: 12px;
    background: var(--raised);
    box-shadow: inset 0 0 0 1px var(--border);
  }

  /* checkmark.circle.fill: a solid disc with the tick cut out of it. */
  .tick {
    display: grid;
    place-items: center;
    color: var(--live);
  }

  .tick :global(svg path) {
    stroke: var(--raised);
  }

  .column {
    display: flex;
    flex-direction: column;
    gap: 1px;
    min-width: 0;
  }

  .headline {
    font: var(--medium);
    font-size: 12.5px;
    line-height: 15px;
    color: var(--text-primary);
  }

  .detail {
    min-width: 0;
    font-size: 11.5px;
    line-height: 14px;
    color: var(--text-tertiary);
  }

  .pair {
    display: inline-flex;
    align-items: center;
    gap: 5px;
  }
</style>
