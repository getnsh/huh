<script lang="ts">
  /* One transcript, open. The header says what it is and how long; the body
     is the text, or for a recording or a session, its timeline, one line to
     a row, each with the time it was said.

     A recording's times are seek targets, and the line being played is lit
     in the live colour. Nothing scrolls to follow it, as nothing does on the
     Mac: a person reading further down is not pulled back up.

     An hour-long meeting is thousands of rows. The browser skips laying out
     and painting the rows that are off screen, so only what is visible costs
     anything, however long the meeting.

     Its summary, once there is one or while one is being written, leads the
     body, and the header offers to write it, or to write it again. */
  import ChevronLeft from "@lucide/svelte/icons/chevron-left";
  import Pause from "@lucide/svelte/icons/pause";
  import Play from "@lucide/svelte/icons/play";
  import Button from "../../lib/ui/Button.svelte";
  import Icon from "../../lib/ui/Icon.svelte";
  import Spinner from "../../lib/ui/Spinner.svelte";
  import Truncate from "../../lib/ui/Truncate.svelte";
  import CorrectionAudit from "./CorrectionAudit.svelte";
  import FailureBanner from "./FailureBanner.svelte";
  import LearningBadge from "./LearningBadge.svelte";
  import SummaryCard from "./SummaryCard.svelte";
  import SummaryChoiceCard from "./SummaryChoiceCard.svelte";
  import TranscriptActions from "./TranscriptActions.svelte";
  import { api } from "../../lib/api";
  import { clock, timecode, wordCount } from "../../lib/format";
  import { core, ui } from "../../lib/state.svelte";
  import type { Transcript, Uuid } from "../../lib/types";
  import { displayName } from "./naming";
  import { checkPlayable, play, playable, playback, stop, toggle } from "./playback.svelte";

  let { transcript }: { transcript: Transcript } = $props();

  const canPlay = $derived(playable(transcript));
  /* The player's controls belong to the transcript it is playing, and appear
     only there. */
  const owning = $derived(playback.transcriptId === transcript.id);
  const summarising = $derived(core.summary.runningFor === transcript.id);

  /* Asked afresh each time it is opened: the original may have been moved
     or recycled since. */
  $effect(() => {
    checkPlayable(transcript, true);
  });

  /* A press the core turned down, most often because another transcript is
     being summarised already. It is said where the press was made, and only
     while things stand as they did when it was refused: once that other
     summary ends, so does the reason. */
  let refusal = $state(null as { id: Uuid; message: string; during: Uuid | null } | null);
  /* One request at a time: a second press before the core has answered the
     first could only be turned down. */
  let asking = false;

  /* As on the Mac, the core's last failure shows only once nothing is
     running; a refusal of this transcript's own press takes its place. */
  const failure = $derived.by(() => {
    if (summarising) return null;
    if (refusal?.id === transcript.id && refusal.during === core.summary.runningFor) {
      return refusal.message;
    }
    return core.summary.runningFor === null ? core.summary.failure : null;
  });

  /* The transcript whose first summary is waiting on the download question.
     Asked only while the model is not on disk and nothing is fetching it. */
  let choosing = $state(null as Uuid | null);

  function pressed() {
    const model = core.summaryModel;
    if (!model.downloaded && !model.busy && core.summary.runningFor === null) {
      refusal = null;
      choosing = transcript.id;
      return;
    }
    summarise();
  }

  async function summarise() {
    choosing = null;
    if (asking) return;
    asking = true;
    refusal = null;
    const id = transcript.id;
    try {
      await api.summarise(id);
    } catch (error) {
      refusal = { id, message: describe(error), during: core.summary.runningFor };
    } finally {
      asking = false;
    }
  }

  /* Whatever the banner says, it goes: an older failure left under a
     dismissed refusal would only appear in its place. */
  function dismiss() {
    refusal = null;
    if (core.summary.failure !== null) api.dismissSummaryFailure().catch(() => {});
  }

  /* The core's refusals are its own sentences, sent as strings. */
  function describe(error: unknown): string {
    if (typeof error === "string") return error;
    if (error instanceof Error) return error.message;
    return String(error);
  }
</script>

<div class="detail">
  <header>
    <Button variant="secondary" label="Back" onclick={() => (ui.openTranscript = null)}>
      <span class="chevron"><Icon of={ChevronLeft} size={14.6} weight="semibold" /></span>
    </Button>

    <div class="titles">
      <span class="name"><Truncate text={displayName(transcript)} mode="middle" /></span>
      <span class="meta">
        {#if transcript.duration > 0}<span>{clock(transcript.duration)}</span>{/if}
        <span>{wordCount(transcript.text)} words</span>
        {#if transcript.cleanupRemoved > 0}<span>−{transcript.cleanupRemoved} fillers</span>{/if}
        {#if canPlay === false && transcript.source === "file"}<span>· original not available</span>{/if}
      </span>
    </div>

    <span class="spacer"></span>

    <LearningBadge {transcript} />

    {#if owning}
      <Button
        variant="secondary"
        tint="var(--live)"
        label={playback.isPlaying ? "Pause" : "Play"}
        onclick={toggle}
      >
        <Icon of={playback.isPlaying ? Pause : Play} size={10} weight="bold" fill />
      </Button>
      <Button variant="ghost" onclick={stop}>Stop</Button>
    {/if}

    {#if summarising}
      <span class="summarising">
        <Spinner />
        <span class="stage">{core.summary.stage}</span>
      </span>
    {:else}
      <!-- Pressable whatever else is running, as on the Mac: a press either
           starts a summary or is told why not, where a disabled button would
           say neither. -->
      <Button variant="secondary" onclick={pressed}>
        {transcript.summary ? "Redo Summary" : "Summarise"}
      </Button>
    {/if}

    <TranscriptActions {transcript} />
  </header>

  {#key transcript.id}
    <div class="body">
      {#if choosing === transcript.id && !summarising}
        <div class="summary">
          <SummaryChoiceCard {transcript} onaccept={summarise} onclose={() => (choosing = null)} />
        </div>
      {/if}

      {#if summarising || transcript.summary}
        <div class="summary"><SummaryCard {transcript} running={summarising} /></div>
      {/if}

      {#if failure}
        <div class="failure"><FailureBanner message={failure} ondismiss={dismiss} /></div>
      {/if}

      {#if transcript.segments.length === 0}
        <p class="plain selectable">{transcript.text}</p>
      {:else}
        {#each transcript.segments as segment}
          {@const active = playback.activeSegmentId === segment.id}
          <div class="segment" class:active>
            <button
              class="time"
              class:playable={canPlay !== false}
              class:active
              disabled={canPlay !== true}
              onclick={() => play(transcript, segment.start)}>{timecode(segment.start)}</button
            >
            <p class="line selectable">{segment.text}</p>
          </div>
        {/each}

        <!-- As on the Mac, the audit closes a timeline only; a dictation's
             changes are counted on its card instead. -->
        {#if transcript.corrections.length > 0}
          <CorrectionAudit corrections={transcript.corrections} />
        {/if}
      {/if}
    </div>
  {/key}
</div>

<style>
  .detail {
    flex: 1 1 auto;
    min-height: 0;
    display: flex;
    flex-direction: column;
  }

  header {
    flex: 0 0 auto;
    display: flex;
    align-items: center;
    gap: 10px;
    min-width: 0;
    padding: 11px 16px;
    background: var(--surface);
    border-bottom: 1px solid var(--border-soft);
  }

  /* Lucide's chevron sits small in a square box. Drawn at the height of the
     Mac's glyph and cropped to the Mac's width, it keeps the back button at
     the Mac's 34.5 x 26. */
  .chevron {
    display: grid;
    margin: -3.5px -6.25px;
  }

  .titles {
    flex: 0 1 auto;
    min-width: 0;
    display: flex;
    flex-direction: column;
    gap: 2px;
  }

  /* Line heights here and below are the Mac's own leading, 16 pt for 13 pt
     text and 14 pt for 11 pt, which is what makes the header 54 tall. */
  .name {
    display: block;
    min-width: 0;
    font: var(--medium);
    font-size: 13.5px;
    line-height: 16px;
    color: var(--text-primary);
  }

  .meta {
    display: flex;
    gap: 7px;
    min-width: 0;
    overflow: hidden;
    font-size: 11px;
    line-height: 14px;
    color: var(--text-tertiary);
    white-space: nowrap;
  }

  .spacer {
    flex: 1 1 8px;
    min-width: 8px;
  }

  /* What the summary is doing, in the button's place. The title gives way
     to it rather than the other way round, so the stage is never cut. */
  .summarising {
    flex: 0 0 auto;
    display: flex;
    align-items: center;
    gap: 7px;
  }

  /* Spaces kept, as the Mac keeps the two it puts before a download's
     sizes. */
  .stage {
    font-size: 11.5px;
    line-height: 14px;
    color: var(--text-tertiary);
    white-space: pre;
  }

  .body {
    flex: 1 1 auto;
    min-height: 0;
    overflow-y: auto;
    padding-bottom: 16px;
  }

  /* The Mac's padding: the card 14 below the header, 16 in from the sides
     and 4 above what follows; a failure 12 below that. The timeline comes
     straight after, with no space of its own. */
  .summary {
    padding: 14px 16px 4px;
  }

  .failure {
    padding: 12px 16px 0;
  }

  /* The Mac's 14 pt, with four points between lines and none above the
     first or below the last: CSS shares the extra out above and below every
     line, so two points of it are taken back from the padding. */
  .plain {
    margin: 0;
    padding: 14px 16px;
    font-size: 14px;
    line-height: 21px;
    color: var(--text-primary);
    white-space: pre-wrap;
    overflow-wrap: anywhere;
  }

  /* The intrinsic size is the content box of a one-line row, which is what
     an unpainted row stands in as. */
  .segment {
    display: flex;
    align-items: flex-start;
    gap: 10px;
    margin: 0 10px;
    padding: 4px 8px;
    border-radius: 6px;
    content-visibility: auto;
    contain-intrinsic-size: auto 16px;
  }

  .segment.active {
    background: color-mix(in srgb, var(--live) 10%, transparent);
  }

  .time {
    flex: 0 0 auto;
    font: var(--mono);
    font-variant-numeric: tabular-nums;
    color: color-mix(in srgb, var(--text-tertiary) 70%, transparent);
  }

  .time.playable {
    color: var(--text-secondary);
  }

  .time.active {
    color: var(--live);
  }

  /* 13 pt with two points between lines, and none outside them: the point
     CSS puts above the first line and below the last is taken back, so a
     one-line row is the Mac's 24 tall. */
  .line {
    flex: 1 1 auto;
    min-width: 0;
    margin: -1px 0;
    font-size: 13px;
    line-height: 18px;
    color: var(--text-secondary);
    white-space: pre-wrap;
    overflow-wrap: anywhere;
  }

  .segment.active .line {
    color: var(--text-primary);
  }
</style>
