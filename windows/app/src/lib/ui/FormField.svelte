<script lang="ts">
  /* A labelled input, as the Mac's editor sheet draws one: the label small,
     uppercase and tracked, the input sunk to the base grey. */
  interface Props {
    label: string;
    value: string;
    placeholder?: string;
    mono?: boolean;
    autofocus?: boolean;
  }

  let { label, value = $bindable(), placeholder = "", mono = false, autofocus = false }: Props =
    $props();

  let input: HTMLInputElement | undefined = $state(undefined);

  $effect(() => {
    if (autofocus && input) {
      // After the sheet has finished arriving, so the caret lands visibly.
      const timer = setTimeout(() => input?.focus(), 30);
      return () => clearTimeout(timer);
    }
  });
</script>

<label class="field">
  <span class="caption">{label}</span>
  <input bind:this={input} bind:value {placeholder} class:mono spellcheck="false" />
</label>

<style>
  .field {
    display: flex;
    flex-direction: column;
    gap: 6px;
  }

  .caption {
    font-weight: 500;
    font-size: 11px;
    line-height: 1.2;
    letter-spacing: 0.6px;
    text-transform: uppercase;
    color: var(--text-tertiary);
  }

  input {
    font: var(--body);
    font-size: 14px;
    line-height: 1.2;
    color: var(--text-primary);
    padding: 9px 11px;
    background: var(--base);
    /* A hairline inside the field, as the Mac draws it: a real border would
       add two pixels to every input. */
    border: 0;
    box-shadow: inset 0 0 0 1px var(--border);
    border-radius: var(--radius-control);
    outline: 0;
  }

  input.mono {
    font: var(--mono);
    line-height: 1.2;
  }

  input::placeholder {
    color: var(--text-secondary);
  }
</style>
