<script lang="ts">
  /* What went wrong, in the danger colour, until it is dismissed: the Mac's
     FailureBanner, which says so for a recording that could not be
     transcribed and for a summary that could not be written. */
  import TriangleAlert from "@lucide/svelte/icons/triangle-alert";
  import Button from "../../lib/ui/Button.svelte";
  import Icon from "../../lib/ui/Icon.svelte";

  interface Props {
    message: string;
    ondismiss: () => void;
  }

  let { message, ondismiss }: Props = $props();
</script>

<div class="failure">
  <span class="alert"><Icon of={TriangleAlert} size={11} fill /></span>
  <p class="message">{message}</p>
  <span class="spacer"></span>
  <Button variant="ghost" tint="var(--danger)" onclick={ondismiss}>Dismiss</Button>
</div>

<style>
  .failure {
    display: flex;
    align-items: center;
    gap: 9px;
    padding: 11px;
    border-radius: var(--radius-card);
    color: var(--danger);
    background: color-mix(in srgb, var(--danger) 10%, transparent);
  }

  /* exclamationmark.triangle.fill: the mark cut out of a solid triangle, in
     the colour of what lies under the banner. */
  .alert {
    display: grid;
    place-items: center;
  }

  .alert :global(svg path:not(:first-child)) {
    stroke: color-mix(in srgb, var(--danger) 10%, var(--base));
  }

  .message {
    margin: 0;
    min-width: 0;
    font-size: 12px;
    line-height: 15px;
  }

  .spacer {
    flex: 1 1 8px;
    min-width: 8px;
  }
</style>
