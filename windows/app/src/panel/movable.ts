/* Makes an element a handle for the panel: a drag moves the window, and a
   press that goes nowhere is a click.

   One gesture decides between the two, rather than a drag and a click
   competing, as on the Mac: a click handler would also fire on the release
   that puts the panel down. Only the deciding happens here. Once the pointer
   has gone further than the slop, the core is told, and it moves the window by
   the pointer's position on screen until it is told the drag has ended. The
   page moves nothing itself: it is inside the thing being moved, so anything
   it measured would shift under it every frame. */
import type { Action } from "svelte/action";
import { api } from "../lib/api";

/* How far the pointer may wander and still count as a click: the Mac's 3. */
const SLOP = 3;

type Options = { onClick?: () => void } | undefined;

export const movable: Action<HTMLElement, Options> = (node, options) => {
  let current = options;
  let press: { id: number; x: number; y: number } | null = null;
  let moving = false;

  const finish = (clicked: boolean) => {
    const dragged = moving;
    press = null;
    moving = false;
    if (dragged) api.panelDrag("ended").catch(() => {});
    else if (clicked) current?.onClick?.();
  };

  const down = (event: PointerEvent) => {
    if (event.button !== 0 || press) return;
    // A control inside a handle keeps its own press.
    if ((event.target as Element | null)?.closest("button, a, input, textarea, select")) return;
    press = { id: event.pointerId, x: event.screenX, y: event.screenY };
    moving = false;
    // Captured, so the release is heard even if the pointer has run ahead of a
    // window that is still catching up with it.
    node.setPointerCapture(event.pointerId);
  };

  const move = (event: PointerEvent) => {
    if (!press || moving || event.pointerId !== press.id) return;
    // Measured on the screen, not in the page, for the reason above.
    if (Math.hypot(event.screenX - press.x, event.screenY - press.y) > SLOP) {
      moving = true;
      api.panelDrag("began").catch(() => {});
    }
  };

  const up = (event: PointerEvent) => {
    if (!press || event.pointerId !== press.id) return;
    // Settled before the capture is let go, so the loss of it that follows
    // finds nothing left to cancel.
    finish(true);
    if (node.hasPointerCapture(event.pointerId)) node.releasePointerCapture(event.pointerId);
  };

  const cancel = (event: PointerEvent) => {
    if (!press || event.pointerId !== press.id) return;
    finish(false);
  };

  node.addEventListener("pointerdown", down);
  node.addEventListener("pointermove", move);
  node.addEventListener("pointerup", up);
  node.addEventListener("pointercancel", cancel);
  node.addEventListener("lostpointercapture", cancel);

  return {
    update(next) {
      current = next;
    },
    destroy() {
      node.removeEventListener("pointerdown", down);
      node.removeEventListener("pointermove", move);
      node.removeEventListener("pointerup", up);
      node.removeEventListener("pointercancel", cancel);
      node.removeEventListener("lostpointercapture", cancel);
      // A handle taken away mid-drag, by a face changing under the pointer,
      // must not leave the core following the pointer for good.
      if (moving) api.panelDrag("ended").catch(() => {});
    },
  };
};
