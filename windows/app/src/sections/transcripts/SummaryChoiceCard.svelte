<script lang="ts">
  /* Asked before the first summary: the Mac's SummaryChoiceCard, for the one
     decision Windows has to put to anyone.

     On the Mac the card appears when a meeting is too long for Apple's model,
     and one of its answers is the downloaded Qwen3 4B. Windows has only that
     model, so the question comes earlier, at the download itself: a summary
     here costs 2.9 GB the first time, and that is not a thing to start on a
     press of a button that did not say so. The other answer is the Mac's
     hand-off: the meeting and a prompt on the clipboard, and the assistant's
     site opened to paste them into. */
  import ExternalLink from "@lucide/svelte/icons/square-arrow-out-up-right";
  import HardDrive from "@lucide/svelte/icons/hard-drive";
  import HardDriveDownload from "@lucide/svelte/icons/hard-drive-download";
  import Button from "../../lib/ui/Button.svelte";
  import Icon from "../../lib/ui/Icon.svelte";
  import { api } from "../../lib/api";
  import { SUMMARY_MODEL, type Transcript } from "../../lib/types";
  import { wordCount } from "../../lib/format";

  interface Props {
    transcript: Transcript;
    onaccept: () => void;
    onclose: () => void;
  }

  let { transcript, onaccept, onclose }: Props = $props();

  const words = $derived(wordCount(transcript.text));
  /* The Mac's estimate: three characters to a token, rounded up. */
  const tokens = $derived(Math.ceil(transcript.text.length / 3));
  const grouped = (n: number) => n.toLocaleString("en-GB");

  let problem = $state(null as string | null);

  async function handOff(provider: "chatGPT" | "claude") {
    problem = null;
    try {
      await api.summaryHandoff(transcript.id, provider);
      onclose();
    } catch (error) {
      problem = typeof error === "string" ? error : String(error);
    }
  }
</script>

<div class="card">
  <div class="headline">
    <span class="glyph warn"><Icon of={HardDriveDownload} size={12} /></span>
    <div class="words">
      <span class="title">Summaries need a one-time download</span>
      <span class="detail">
        {grouped(words)} words to read. huh? writes summaries with {SUMMARY_MODEL.name} on this PC,
        and it isn't downloaded yet.
      </span>
    </div>
  </div>

  <div class="divider"></div>

  <div class="option">
    <span class="glyph live"><Icon of={HardDrive} size={12} /></span>
    <div class="words">
      <span class="name">Use {SUMMARY_MODEL.name} — stays on this PC</span>
      <span class="detail">
        Reads the whole meeting in one pass. Downloads about {SUMMARY_MODEL.size} once, then works
        offline forever, like the rest of the app. Nothing is ever sent anywhere.
      </span>
      <div class="actions">
        <Button variant="primary" onclick={onaccept}>Download and Summarise</Button>
      </div>
    </div>
  </div>

  <div class="option">
    <span class="glyph"><Icon of={ExternalLink} size={12} /></span>
    <div class="words">
      <span class="name">Send it to ChatGPT or Claude</span>
      <span class="detail">
        Copies the meeting and a prompt, then opens the site so you can paste it. These leave your
        PC — that is the trade for not downloading anything. Roughly {grouped(tokens)} tokens.
      </span>
      <div class="actions">
        <Button variant="secondary" onclick={() => handOff("chatGPT")}>ChatGPT</Button>
        <Button variant="secondary" onclick={() => handOff("claude")}>Claude</Button>
      </div>
      {#if problem}<span class="problem">{problem}</span>{/if}
    </div>
  </div>

  <div class="footer">
    <Button variant="ghost" onclick={onclose}>Not Now</Button>
  </div>
</div>

<style>
  /* The warning colour's hairline at 28 %, as the Mac strokes this card: it
     is asking something, which the summary card never does. */
  .card {
    display: flex;
    flex-direction: column;
    gap: 14px;
    padding: 16px;
    border-radius: var(--radius-card);
    background: var(--raised);
    box-shadow: inset 0 0 0 1px color-mix(in srgb, var(--warning) 28%, transparent);
    animation: arrive var(--spring-duration) var(--spring);
  }

  @keyframes arrive {
    from {
      opacity: 0;
      transform: translateY(-8px);
    }
  }

  .headline,
  .option {
    display: flex;
    align-items: flex-start;
    gap: 10px;
  }

  .headline {
    gap: 8px;
  }

  /* Sixteen wide, as the Mac frames each option's symbol, so the text of
     every option starts at the same edge. */
  .glyph {
    flex: 0 0 16px;
    display: grid;
    place-items: center;
    padding-top: 1px;
    color: var(--text-secondary);
  }

  .glyph.warn {
    color: var(--warning);
  }

  .glyph.live {
    color: var(--live);
  }

  .words {
    flex: 1 1 auto;
    min-width: 0;
    display: flex;
    flex-direction: column;
    gap: 6px;
  }

  .headline .words {
    gap: 2px;
  }

  .title {
    font: var(--medium);
    line-height: 16px;
    color: var(--text-primary);
  }

  .name {
    font: var(--medium);
    font-size: 12.5px;
    line-height: 15px;
    color: var(--text-primary);
  }

  .detail {
    font-size: 11.5px;
    line-height: 14px;
    color: var(--text-tertiary);
  }

  .actions {
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
  }

  .problem {
    font-size: 11.5px;
    line-height: 14px;
    color: var(--danger);
  }

  .divider {
    height: 1px;
    background: var(--border-soft);
  }

  .footer {
    display: flex;
    justify-content: flex-end;
  }

  @media (prefers-reduced-motion: reduce) {
    .card {
      animation: none;
    }
  }
</style>
