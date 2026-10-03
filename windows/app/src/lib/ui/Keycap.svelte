<script lang="ts">
  /* A key, named the way the keyboard prints it. Lit while the key is
     physically held, which makes it a key tester as well as a label. */
  interface Props {
    label: string;
    held?: boolean;
  }

  let { label, held = false }: Props = $props();
</script>

<kbd class:held>{label}</kbd>

<style>
  kbd {
    display: inline-block;
    font-family: var(--font);
    font-weight: 600;
    font-size: 10.5px;
    line-height: 1.2;
    padding: 2px 5px;
    border-radius: 4px;
    color: var(--text-secondary);
    background: var(--raised);
    white-space: nowrap;
    transition:
      color var(--quick-duration) var(--quick),
      background-color var(--quick-duration) var(--quick);
  }

  kbd.held {
    color: var(--live);
    background: color-mix(in srgb, var(--live) 12%, var(--raised));
  }
</style>
