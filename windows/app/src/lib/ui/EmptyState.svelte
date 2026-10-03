<script lang="ts">
  /* What a view says when it has nothing in it yet. The words do the work:
     what goes here, and how it gets here. */
  import type { Component, Snippet } from "svelte";
  import Icon from "./Icon.svelte";

  interface Props {
    icon: Component<any>;
    title: string;
    message: string;
    children?: Snippet;
  }

  let { icon, title, message, children }: Props = $props();
</script>

<div class="empty">
  <span class="glyph"><Icon of={icon} size={26} weight="light" /></span>
  <p class="title">{title}</p>
  <p class="message">{message}</p>
  {@render children?.()}
</div>

<style>
  .empty {
    flex: 1 1 auto;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 10px;
    padding: 40px;
    text-align: center;
  }

  .glyph {
    color: var(--text-tertiary);
  }

  .title {
    margin: 0;
    font: var(--heading);
    font-size: 14px;
    color: var(--text-secondary);
  }

  .message {
    margin: 0;
    font-size: 12.5px;
    line-height: 1.35;
    color: var(--text-tertiary);
    max-width: 320px;
    text-wrap: balance;
  }
</style>
