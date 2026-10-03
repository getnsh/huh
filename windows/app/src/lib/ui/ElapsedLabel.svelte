<script lang="ts">
  /* A session's running clock, ticking once a second, frozen when it ends. */
  import { elapsed } from "../format";

  interface Props {
    since: string | null;
    frozen?: number | null;
    tint?: string;
  }

  let { since, frozen = null, tint = "var(--text-secondary)" }: Props = $props();
  let now = $state(Date.now());

  $effect(() => {
    if (frozen !== null || !since) return;
    const timer = setInterval(() => (now = Date.now()), 1000);
    return () => clearInterval(timer);
  });

  const seconds = $derived(
    frozen !== null ? frozen : since ? (now - new Date(since).getTime()) / 1000 : 0,
  );
</script>

<span class="elapsed" style:color={tint}>{elapsed(seconds)}</span>

<style>
  .elapsed {
    font-weight: 500;
    font-size: 12px;
    line-height: 1.2;
    font-variant-numeric: tabular-nums;
  }
</style>
