<script lang="ts">
  /* Settings, laid out as the Mac's SettingsView: one scrolling column of
     grouped cards under a 32-pixel title strip, 26 in from every edge and 22
     between groups, every control writing the moment it moves, with no Save
     and no Cancel.

     Only what Windows can honour is offered. The Mac's own rule is that a
     picker never offers a choice that would break the app, so the engine is
     stated rather than chosen, and Language, Summaries and On-device
     intelligence, which have nothing behind them here yet, are left out
     rather than shown switched off. */
  import { getCurrentWindow } from "@tauri-apps/api/window";
  import Button from "../lib/ui/Button.svelte";
  import Switch from "../lib/ui/Switch.svelte";
  import { api } from "../lib/api";
  import Group from "./Group.svelte";
  import Note from "./Note.svelte";
  import Picker from "./Picker.svelte";
  import Row from "./Row.svelte";
  import StatusLine, { type Tone } from "./StatusLine.svelte";
  import TitleStrip from "./TitleStrip.svelte";
  import ToggleRow from "./ToggleRow.svelte";
  import {
    BEHAVIOURS,
    CLEANUP,
    CLEANUP_DETAIL,
    INSERTION,
    KEYS,
    TEXT,
    callText,
    engineText,
    launchText,
    microphoneText,
  } from "./copy";
  import { change, checkInput, connect, page, setLaunch } from "./page.svelte";

  $effect(() => connect());

  const engineTone: Tone = $derived(page.engine.kind === "ready" ? "live" : "warning");

  /* Grey only until the first answer arrives, which is a moment. */
  const microphoneTone: Tone = $derived(
    page.input === null
      ? "neutral"
      : page.input.hasInput && !page.input.problem
        ? "live"
        : "warning",
  );

  /* Which Windows Settings page mends the problem: Sound for a microphone
     muted at the system, Privacy for one Windows keeps from desktop apps.
     The same test the main window's banner makes. */
  const fix: "microphone" | "sound" | null = $derived(
    page.input?.hasInput && page.input.problem
      ? page.input.problem.includes("muted")
        ? "sound"
        : "microphone"
      : null,
  );

  /* The app a call is in, as far as the session can say: the one it is
     offering to listen to, or the one it is already listening to. */
  const call: string | null = $derived(
    page.session?.offer ??
      (page.session?.running && page.session.label !== "Listening" ? page.session.label : null),
  );

  /* Ctrl+W, as ⌘W closes the Mac's Settings. */
  function keydown(event: KeyboardEvent) {
    const ctrl = event.ctrlKey && !event.altKey && !event.metaKey && !event.shiftKey;
    if (ctrl && event.key.toLowerCase() === "w") {
      event.preventDefault();
      getCurrentWindow().close();
    }
  }

  /* No browser menu on right-click: there is no text here to copy. */
  function contextmenu(event: MouseEvent) {
    event.preventDefault();
  }
</script>

<svelte:window onkeydown={keydown} oncontextmenu={contextmenu} />

<div class="window">
  <TitleStrip />

  <div class="scroll">
    {#if page.settings}
      {@const s = page.settings}
      <div class="content">
        <Group title="Push-to-talk">
          <Row label="Key" width={150}>
            <Picker
              label="Key"
              value={s.hotkey}
              options={KEYS}
              onchange={(key) => change("hotkey", key)}
            />
          </Row>
          <Row label="Behaviour" width={150}>
            <Picker
              label="Behaviour"
              value={s.triggerMode}
              options={BEHAVIOURS}
              onchange={(mode) => change("triggerMode", mode)}
            />
          </Row>
          <Note>{TEXT.keyNote}</Note>
          {#if s.hotkey === "capsLock"}
            <Note>{TEXT.capsLock}</Note>
          {/if}
        </Group>

        <Group title="Microphone">
          <StatusLine tone={microphoneTone} text={page.input ? microphoneText(page.input) : ""}>
            <Button variant="ghost" onclick={checkInput}>Check Again</Button>
          </StatusLine>
          {#if fix}
            <div class="action">
              <Button
                variant="secondary"
                onclick={() => {
                  if (fix) api.openSystemSettings(fix);
                }}
              >
                {fix === "sound" ? TEXT.openSound : TEXT.openMicrophone}
              </Button>
            </div>
          {/if}
          {#if page.input && !page.input.hasInput}
            <Note>{TEXT.noInputNote}</Note>
          {/if}
        </Group>

        <Group title="What it hears">
          <ToggleRow
            title={TEXT.hearsPC}
            detail={TEXT.hearsPCDetail}
            checked={s.hearsSystemAudio}
            onchange={(on) => change("hearsSystemAudio", on)}
          />
          <div class="divider"></div>
          <ToggleRow
            title={TEXT.notice}
            detail={callText(s.watchesForMeetings, call)}
            checked={s.watchesForMeetings}
            onchange={(on) => change("watchesForMeetings", on)}
          />
          {#if s.watchesForMeetings}
            <ToggleRow
              title={TEXT.startsOwn}
              checked={s.capturesMeetingsAutomatically}
              onchange={(on) => change("capturesMeetingsAutomatically", on)}
            />
            <Note>{s.capturesMeetingsAutomatically ? TEXT.startsOwnOn : TEXT.startsOwnOff}</Note>
          {/if}
          <Note>{TEXT.spotting}</Note>
          <Note>{TEXT.consent}</Note>
        </Group>

        <Group title="Model">
          <Row label="Engine">
            <span class="value">{TEXT.engine}</span>
          </Row>
          <Note>{TEXT.engineNote}</Note>
          <StatusLine tone={engineTone} text={engineText(page.engine)} />
        </Group>

        <Group title="Cleanup">
          <Row label="Tidy transcripts" width={200}>
            <Picker
              label="Tidy transcripts"
              value={s.cleanupLevel}
              options={CLEANUP}
              onchange={(level) => change("cleanupLevel", level)}
            />
          </Row>
          <Note>{CLEANUP_DETAIL[s.cleanupLevel]}</Note>
        </Group>

        <Group title="Startup">
          <ToggleRow
            title={TEXT.startAtSignIn}
            checked={page.launch === true}
            spacing={8}
            onchange={setLaunch}
          />
          <StatusLine
            tone={page.launch ? "live" : "neutral"}
            text={page.launchFailure ?? launchText(page.launch === true)}
            small
            danger={page.launchFailure !== null}
          />
        </Group>

        <Group title="Insertion">
          <Row label="Insert with" width={250}>
            <Picker
              label="Insert with"
              value={s.injectionMode}
              options={INSERTION}
              onchange={(mode) => change("injectionMode", mode)}
            />
          </Row>
          <!-- A labelled switch, which the Mac lays out label then switch,
               side by side, rather than pushed apart like the rows above. -->
          <span class="labelled">
            <span>{TEXT.feedbackSounds}</span>
            <Switch
              size="small"
              checked={s.playFeedbackSounds}
              label={TEXT.feedbackSounds}
              onchange={(on) => change("playFeedbackSounds", on)}
            />
          </span>
          <Note>{TEXT.insertionNote}</Note>
        </Group>
      </div>
    {/if}
  </div>
</div>

<style>
  .window {
    display: grid;
    grid-template-rows: auto minmax(0, 1fr);
    height: 100vh;
  }

  /* The gutter is kept even when nothing overflows, so a group opening or
     closing never shifts the cards sideways. */
  .scroll {
    min-height: 0;
    overflow-y: auto;
    scrollbar-gutter: stable;
  }

  .content {
    display: flex;
    flex-direction: column;
    gap: 22px;
    padding: 26px;
  }

  .divider {
    flex: 0 0 auto;
    height: 1px;
    background: var(--border-soft);
  }

  .value {
    font: var(--body);
    line-height: 16px;
    color: var(--text-primary);
    white-space: nowrap;
  }

  .action {
    display: flex;
  }

  .labelled {
    display: flex;
    align-items: center;
    gap: 8px;
    align-self: flex-start;
    font: var(--body);
    line-height: 16px;
    color: var(--text-secondary);
  }
</style>
