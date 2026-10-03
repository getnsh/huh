<script lang="ts">
  /* The summary at the top of an open transcript: the Mac's SummaryCard.
     While it is being written, what is happening and the words so far; once
     written, the summary itself, with a button that copies its Markdown.

     The bar is determinate only while there is something real to measure,
     such as the download. A bar parked at a made-up percentage for a minute
     reads as a hang, so the writing gets the moving bar, and the words
     arriving are what show it is getting somewhere. */
  import Copy from "@lucide/svelte/icons/copy";
  import Sparkles from "@lucide/svelte/icons/sparkles";
  import Button from "../../lib/ui/Button.svelte";
  import Icon from "../../lib/ui/Icon.svelte";
  import ProgressBar from "../../lib/ui/ProgressBar.svelte";
  import SectionLabel from "../../lib/ui/SectionLabel.svelte";
  import Spinner from "../../lib/ui/Spinner.svelte";
  import { core } from "../../lib/state.svelte";
  import { SUMMARY_MODEL, type Transcript } from "../../lib/types";
  import MarkdownBlock from "./MarkdownBlock.svelte";

  interface Props {
    transcript: Transcript;
    running: boolean;
  }

  let { transcript, running }: Props = $props();

  const progress = $derived(core.summary.progress);
  /* Its own value, so the words are measured again only when they change,
     not whenever the stage does. */
  const streamed = $derived(core.summary.streamed);

  /* Four lines of 11.5 pt at the Mac's 14 pt leading. */
  const LIMIT = 4 * 14;

  let width = $state(0);
  let tail = $state(null as HTMLParagraphElement | null);
  let probe = $state(null as HTMLParagraphElement | null);

  /* The newest words: the last 400 characters, cut at the front to the four
     lines there is room for, so what is arriving stays in view. CSS can only
     cut the end of a paragraph, so the cut is found by measuring, as
     Truncate finds one, on an unseen copy: trying candidates there moves
     nothing else on the page, however long the transcript under the card. */
  $effect(() => {
    void width;
    if (!tail || !probe) return;
    tail.textContent = newest(streamed, probe);
  });

  function newest(text: string, measure: HTMLElement): string {
    const chars = Array.from(text).slice(-400);
    const fits = (candidate: string) => {
      measure.textContent = candidate;
      return measure.scrollHeight <= LIMIT + 0.5;
    };
    const whole = chars.join("");
    if (fits(whole)) return whole;
    // The most characters that still fit behind the ellipsis, found by halving.
    let low = 0;
    let high = chars.length;
    const cut = (keep: number) => "…" + chars.slice(chars.length - keep).join("");
    while (low < high) {
      const middle = (low + high + 1) >> 1;
      if (fits(cut(middle))) low = middle;
      else high = middle - 1;
    }
    return cut(low);
  }

  /* The Markdown as written, which is what pastes well anywhere. A clipboard
     failure has nowhere useful to go, as with the transcript's own copy. */
  function copy() {
    navigator.clipboard.writeText(transcript.summary).catch(() => {});
  }
</script>

<div class="card">
  <div class="head">
    <span class="sparkles"><Icon of={Sparkles} size={11} /></span>
    <SectionLabel>Summary</SectionLabel>
    <span class="spacer"></span>
    {#if running}
      {#if progress !== null}
        <span class="percent">{Math.floor(progress * 100)}%</span>
      {:else}
        <Spinner />
      {/if}
    {:else if transcript.summary}
      <Button variant="ghost" label="Copy summary" onclick={copy}>
        <Icon of={Copy} size={12} weight="medium" />
      </Button>
    {/if}
  </div>

  {#if running}
    <div class="running">
      <p class="stage">{core.summary.stage}</p>
      <ProgressBar value={progress} />
      {#if streamed}
        <div class="streamed" bind:clientWidth={width}>
          <p class="tail" bind:this={tail}></p>
          <p class="probe" bind:this={probe} aria-hidden="true"></p>
        </div>
      {/if}
      <p class="where">Running on this PC — {SUMMARY_MODEL.name}, nothing sent anywhere.</p>
    </div>
  {:else}
    <MarkdownBlock text={transcript.summary} />
  {/if}
</div>

<style>
  /* The live colour's hairline at 22 %, inside the padding, where the Mac's
     strokeBorder draws it. */
  .card {
    display: flex;
    flex-direction: column;
    gap: 10px;
    padding: 14px;
    border-radius: var(--radius-card);
    background: var(--raised);
    box-shadow: inset 0 0 0 1px color-mix(in srgb, var(--live) 22%, transparent);
  }

  .head {
    display: flex;
    align-items: center;
    gap: 7px;
  }

  .sparkles {
    display: grid;
    place-items: center;
    color: var(--live);
  }

  .spacer {
    flex: 1 1 0;
    min-width: 0;
  }

  .percent {
    flex: 0 0 auto;
    font: var(--mono);
    font-variant-numeric: tabular-nums;
    color: var(--text-tertiary);
  }

  .running {
    display: flex;
    flex-direction: column;
    gap: 7px;
  }

  /* Line heights are the Mac's leading: 15 pt for 12 pt text, 14 for 11.5,
     13 for 10.5. Spaces are kept, as the Mac keeps the two it puts before
     a download's sizes. */
  .stage {
    margin: 0;
    font-size: 12px;
    line-height: 15px;
    color: var(--text-tertiary);
    white-space: pre-wrap;
  }

  /* Clipped, so the unseen copy never lengthens what the page can scroll. */
  .streamed {
    position: relative;
    padding-top: 2px;
    overflow: hidden;
  }

  .tail,
  .probe {
    margin: 0;
    font-size: 11.5px;
    line-height: 14px;
    color: var(--text-secondary);
    white-space: pre-wrap;
    overflow-wrap: anywhere;
  }

  .tail {
    max-height: calc(4 * 14px);
    overflow: hidden;
  }

  /* Out of the flow, so filling it moves nothing; as wide as the words. */
  .probe {
    position: absolute;
    inset: 0 0 auto 0;
    visibility: hidden;
    pointer-events: none;
  }

  .where {
    margin: 0;
    font-size: 10.5px;
    line-height: 13px;
    color: color-mix(in srgb, var(--text-tertiary) 80%, transparent);
  }
</style>
