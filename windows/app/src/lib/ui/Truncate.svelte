<script lang="ts">
  /* One line of text, cut where the Mac cuts it. CSS can only drop the tail;
     a file name keeps its ending ("Quarterly…review.m4a", the middle) and a
     live caption keeps its newest words ("…said it", the head). Measured
     against the space it actually has, again whenever that changes. */
  interface Props {
    text: string;
    mode?: "middle" | "head" | "tail";
    class?: string;
  }

  let { text, mode = "middle", class: className = "" }: Props = $props();

  let host: HTMLSpanElement | undefined = $state(undefined);
  let shown = $state("");
  let width = $state(0);

  function fits(candidate: string): boolean {
    if (!host) return true;
    host.textContent = candidate;
    return host.scrollWidth <= host.clientWidth + 0.5;
  }

  $effect(() => {
    void width;
    if (!host || mode === "tail") {
      shown = text;
      return;
    }
    if (fits(text)) {
      shown = text;
      return;
    }
    // The most characters that still fit, found by halving.
    let low = 0;
    let high = text.length;
    const cut = (keep: number) => {
      if (mode === "head") return "…" + text.slice(text.length - keep);
      const front = Math.ceil(keep / 2);
      return text.slice(0, front) + "…" + text.slice(text.length - (keep - front));
    };
    while (low < high) {
      const middle = (low + high + 1) >> 1;
      if (fits(cut(middle))) low = middle;
      else high = middle - 1;
    }
    shown = cut(low);
    if (host) host.textContent = shown;
  });
</script>

<span
  bind:this={host}
  bind:clientWidth={width}
  class="truncate {className}"
  class:tail={mode === "tail"}
  title={shown !== text ? text : undefined}>{shown}</span
>

<style>
  .truncate {
    display: block;
    min-width: 0;
    overflow: hidden;
    white-space: nowrap;
  }

  .tail {
    text-overflow: ellipsis;
  }
</style>
