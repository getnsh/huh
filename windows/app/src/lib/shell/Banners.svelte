<script lang="ts">
  /* The strips under the top bar, in both sections: a microphone that cannot
     be heard, the result of a Learn pass, and the one-time offer to start at
     sign-in. Each says what it is and what can be done about it. */
  import MicOff from "@lucide/svelte/icons/mic-off";
  import CircleCheck from "@lucide/svelte/icons/circle-check";
  import Power from "@lucide/svelte/icons/power";
  import Banner from "../ui/Banner.svelte";
  import Button from "../ui/Button.svelte";
  import Icon from "../ui/Icon.svelte";
  import { api } from "../api";
  import { core } from "../state.svelte";

  let launchEnabled: boolean | null = $state(null);

  $effect(() => {
    api.launchAtLogin()
      .then((on) => (launchEnabled = on))
      .catch(() => (launchEnabled = null));
  });

  const inputProblem = $derived(
    !core.input.hasInput
      ? "No microphone is connected. Plug one in or pair one to dictate."
      : core.input.problem,
  );

  const askAboutLogin = $derived(
    core.settings !== null && !core.settings.hasAskedLaunchAtLogin && launchEnabled === false,
  );

  async function answerLogin(start: boolean) {
    if (!core.settings) return;
    if (start) {
      await api.setLaunchAtLogin(true);
      launchEnabled = true;
    }
    await api.setSettings({ ...core.settings, hasAskedLaunchAtLogin: true });
  }

  const settingsPage = $derived(
    core.input.problem?.includes("muted") ? "sound" : ("microphone" as const),
  );
</script>

{#if inputProblem}
  <Banner tone="warning">
    <span class="icon warn"><Icon of={MicOff} size={11} weight="medium" /></span>
    <span class="text">{inputProblem}</span>
    <span class="spacer"></span>
    <span class="aside">Transcribing a recording still works.</span>
    {#if core.input.problem}
      <Button variant="ghost" tint="var(--warning)" onclick={() => api.openSystemSettings(settingsPage)}>
        Open Settings
      </Button>
    {/if}
    <Button
      variant="ghost"
      tint="var(--warning)"
      onclick={() => api.audioInput().then((v) => (core.input = v))}
    >
      Check Again
    </Button>
  </Banner>
{/if}

{#if core.learning.result}
  <Banner>
    <span class="icon live"><Icon of={CircleCheck} size={11} fill /></span>
    <span class="text">{core.learning.result}</span>
    <span class="spacer"></span>
    {#if core.learning.ignoredCount > 0}
      <Button variant="ghost" tint="var(--live)" onclick={() => api.restoreDismissed()}>
        Show Dismissed
      </Button>
    {/if}
    <Button variant="ghost" onclick={() => api.dismissScanResult()}>Dismiss</Button>
  </Banner>
{/if}

{#if askAboutLogin}
  <Banner>
    <span class="icon live"><Icon of={Power} size={12} weight="medium" /></span>
    <span class="column">
      <span class="headline">Start huh? when you sign in?</span>
      <span class="detail">The push-to-talk key only works while the app is running.</span>
    </span>
    <span class="spacer"></span>
    <Button variant="ghost" onclick={() => answerLogin(false)}>Not Now</Button>
    <Button variant="primary" onclick={() => answerLogin(true)}>Start at Sign-in</Button>
  </Banner>
{/if}

<style>
  .icon { display: grid; place-items: center; }
  .warn { color: var(--warning); }
  .live { color: var(--live); }
  .live :global(svg path) { stroke: var(--raised); }

  .text {
    font-size: 12px;
    color: var(--text-secondary);
  }

  .spacer {
    flex: 1 1 auto;
    min-width: 8px;
  }

  .aside {
    font-size: 11px;
    color: var(--text-tertiary);
    white-space: nowrap;
  }

  .column {
    display: flex;
    flex-direction: column;
    gap: 2px;
  }

  .headline {
    font-weight: 500;
    font-size: 12.5px;
    color: var(--text-primary);
  }

  .detail {
    font-size: 11.5px;
    color: var(--text-tertiary);
  }
</style>
