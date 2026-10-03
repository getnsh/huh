<script lang="ts">
  import Search from "@lucide/svelte/icons/search";
  import CircleX from "@lucide/svelte/icons/circle-x";
  import Icon from "./Icon.svelte";

  interface Props {
    value: string;
    placeholder: string;
    width?: number;
  }

  let { value = $bindable(), placeholder, width = 190 }: Props = $props();
  let input: HTMLInputElement | undefined = $state(undefined);

  export function focus() {
    input?.focus();
    input?.select();
  }
</script>

<label class="field" style:width="{width}px">
  <span class="glass"><Icon of={Search} size={11} weight="medium" /></span>
  <input bind:this={input} bind:value {placeholder} spellcheck="false" />
  {#if value}
    <button class="clear" aria-label="Clear" onclick={() => (value = "")}>
      <Icon of={CircleX} size={11} fill />
    </button>
  {/if}
</label>

<style>
  .field {
    display: flex;
    align-items: center;
    gap: 7px;
    height: 30px;
    padding: 7px 10px;
    border-radius: var(--radius-control);
    background: var(--raised);
    box-shadow: inset 0 0 0 1px var(--border);
    flex: 0 1 auto;
    min-width: 120px;
  }

  .glass {
    color: var(--text-tertiary);
  }

  input {
    flex: 1 1 auto;
    min-width: 0;
    border: 0;
    outline: 0;
    background: transparent;
    font: var(--body);
    line-height: 1.2;
    color: var(--text-primary);
    padding: 0;
  }

  input::placeholder {
    color: var(--text-secondary);
  }

  .clear {
    display: grid;
    place-items: center;
    padding: 0;
    color: var(--text-tertiary);
    animation: appear var(--quick-duration) var(--quick);
  }

  /* The cut-out cross reads against the raised field. */
  .clear :global(svg circle) {
    fill: var(--text-tertiary);
  }

  .clear :global(svg path) {
    stroke: var(--raised);
  }

  @keyframes appear {
    from { opacity: 0; }
  }
</style>
