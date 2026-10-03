<script lang="ts">
  /* An on/off switch at the Mac's two sizes: mini for list rows (36 x 16) and
     small for Settings (44 x 20).

     As the Mac draws its own: an untinted system switch, so the system blue
     when on, a dark track when off, and a white knob either way. Never the
     live colour, which would say something is listening when nothing is. */
  interface Props {
    checked: boolean;
    size?: "mini" | "small";
    label?: string;
    onchange?: (checked: boolean) => void;
  }

  let { checked, size = "mini", label, onchange }: Props = $props();
</script>

<button
  class="switch {size}"
  class:on={checked}
  role="switch"
  aria-checked={checked}
  aria-label={label}
  onclick={(event) => {
    event.stopPropagation();
    onchange?.(!checked);
  }}
>
  <span class="knob"></span>
</button>

<style>
  .switch {
    --w: 36px;
    --h: 16px;
    --kw: 21px;
    --kh: 13px;
    --inset: 1.5px;
    position: relative;
    flex: 0 0 auto;
    width: var(--w);
    height: var(--h);
    padding: 0;
    border-radius: 999px;
    background: var(--pressed);
    transition: background-color var(--quick-duration) var(--quick);
  }

  .switch.small {
    --w: 44px;
    --h: 20px;
    --kw: 25px;
    --kh: 16px;
    --inset: 2px;
  }

  .switch.on {
    background: var(--switch-on);
  }

  .knob {
    position: absolute;
    top: var(--inset);
    left: var(--inset);
    width: var(--kw);
    height: var(--kh);
    border-radius: 999px;
    background: var(--switch-knob);
    box-shadow: 0 0.5px 1.5px rgb(0 0 0 / 0.35);
    transition: transform var(--spring-duration) var(--spring);
  }

  .on .knob {
    transform: translateX(calc(var(--w) - var(--kw) - 2 * var(--inset)));
  }
</style>
