/* The panel's motion: the transitions between its faces, the glide of a card
   that has grown, and the follow of a transcript to its newest words.

   Every figure is read from tokens.css rather than written down a second time,
   so a curve has one source; and reduced motion, which shortens the tokens to a
   millisecond, lands every one of these on its final state. */
import type { TransitionConfig } from "svelte/transition";

type Easing = (t: number) => number;

/* The room the window keeps round what it shows, for the card's shadow: the
   window is the card plus this on every side, the Mac's 14. Panel.svelte pads
   by the same figure. */
export const MARGIN = 14;

const token = (name: string) =>
  getComputedStyle(document.documentElement).getPropertyValue(name).trim();

/* A duration token, in milliseconds. Read every time rather than once, because
   the reduced-motion setting can change while the panel is on screen. */
export function milliseconds(name: string): number {
  const raw = token(name);
  const value = parseFloat(raw);
  if (!Number.isFinite(value)) return 0;
  return raw.endsWith("ms") ? value : value * 1000;
}

let cached: Easing | null = null;

/* The spring, from the `linear(…)` stops tokens.css holds it as. */
export function spring(): Easing {
  if (cached) return cached;
  const stops = [...token("--spring").matchAll(/(-?\d*\.?\d+)\s+(-?\d*\.?\d+)%/g)].map((m) => ({
    at: Number(m[2]) / 100,
    value: Number(m[1]),
  }));
  // Not remembered until it has been read: before the stylesheet lands there
  // is nothing to read, and a straight line would otherwise stick for good.
  if (stops.length < 2) return (t) => t;
  const curve: Easing = (t) => {
    if (t <= stops[0].at) return stops[0].value;
    for (let index = 1; index < stops.length; index += 1) {
      const b = stops[index];
      if (t <= b.at) {
        const a = stops[index - 1];
        return b.at === a.at ? b.value : a.value + ((b.value - a.value) * (t - a.at)) / (b.at - a.at);
      }
    }
    return stops[stops.length - 1].value;
  };
  cached = curve;
  return curve;
}

/* The spring overshoots by a hair; opacity has nowhere to overshoot to. */
const unit = (t: number) => Math.min(1, Math.max(0, t));

/* A face arriving or leaving: it fades as it scales from `scale`, about its
   top-left corner.

   The Mac scales about the top-trailing corner, and then its window, anchored
   top-left and animating its frame, carries that corner across to the anchor.
   Here the window is resized at once rather than animated, so a face scaled
   about the far corner would appear a card's width from where it settles.
   Growing out of the anchored corner ends in the same place without the jump. */
export function rise(_node: Element, { scale = 0.94 }: { scale?: number } = {}): TransitionConfig {
  return {
    duration: milliseconds("--spring-duration"),
    easing: spring(),
    css: (t) =>
      `opacity: ${unit(t)}; transform: scale(${scale + (1 - scale) * t}); transform-origin: 0 0;`,
  };
}

/* The offer comes in from beyond the right edge of the window, the side the
   panel lives on, and leaves the same way: the Mac's move(edge: .trailing). It
   starts its own width plus the margin away, wholly out of sight. */
export function dock(node: Element): TransitionConfig {
  const distance = (node as HTMLElement).offsetWidth + MARGIN;
  return {
    duration: milliseconds("--spring-duration"),
    easing: spring(),
    css: (t, u) => `opacity: ${unit(t)}; transform: translateX(${u * distance}px);`,
  };
}

/* Something arriving in a list: it fades in as it settles up into place. With
   `y: "self"` it rises its own height, the Mac's move(edge: .bottom). */
export function drift(node: Element, { y = 10 }: { y?: number | "self" } = {}): TransitionConfig {
  const distance = y === "self" ? (node as HTMLElement).offsetHeight : y;
  return {
    duration: milliseconds("--spring-duration"),
    easing: spring(),
    css: (t, u) => `opacity: ${unit(t)}; transform: translateY(${u * distance}px);`,
  };
}

/* A plain fade on the spring, for a row that has no direction to come from. */
export function fade(_node: Element): TransitionConfig {
  return {
    duration: milliseconds("--spring-duration"),
    easing: spring(),
    css: (t) => `opacity: ${unit(t)};`,
  };
}

/* Lets a card that has just grown reach its new height on the spring, as the
   Mac's transcript does, without the window being resized frame by frame.

   The layout, and so the window, takes the new height at once; only the
   painting lags. The surface's bottom edge, and a clip over what the card
   holds, start where the old bottom was and run down to the new one, so the
   window grows out of sight under a card that is still the old size. A glide
   already under way is picked up from wherever it has got to.

   Shrinking is not animated: the window would have to wait for it, and a
   card that is getting shorter loses nothing by arriving early. */
export function glide(surface: HTMLElement, body: HTMLElement, grew: number) {
  const from = (parseFloat(getComputedStyle(surface).bottom) || 0) + grew;
  surface.style.transition = "none";
  body.style.transition = "none";
  surface.style.bottom = `${from}px`;
  body.style.clipPath = `inset(0 0 ${from}px 0)`;
  // Commit the starting point, so the transitions run from it rather than
  // from where they are about to be told to go.
  void surface.offsetHeight;
  const timing = "var(--spring-duration) var(--spring)";
  surface.style.transition = `bottom ${timing}`;
  body.style.transition = `clip-path ${timing}`;
  surface.style.bottom = "0px";
  body.style.clipPath = "inset(0 0 0px 0)";
}

/* Keeps a scrolling element at its end.

   `land` runs there on the spring, as the Mac scrolls when a line lands.
   `follow` jumps there at once, as the Mac does while a draft changes, unless
   a landing is already under way: that reads the end afresh every frame and
   so gets there anyway, without the jolt of being overtaken halfway. */
export function tail(node: HTMLElement) {
  let frame = 0;
  let landing = false;
  const end = () => node.scrollHeight - node.clientHeight;

  return {
    land() {
      cancelAnimationFrame(frame);
      const duration = milliseconds("--spring-duration");
      if (duration <= 1) {
        landing = false;
        node.scrollTop = end();
        return;
      }
      const ease = spring();
      const from = node.scrollTop;
      const began = performance.now();
      landing = true;
      const step = (now: number) => {
        const progress = Math.min(1, Math.max(0, (now - began) / duration));
        node.scrollTop = from + (end() - from) * ease(progress);
        if (progress < 1) frame = requestAnimationFrame(step);
        else landing = false;
      };
      frame = requestAnimationFrame(step);
    },
    follow() {
      if (!landing) node.scrollTop = end();
    },
    stop() {
      cancelAnimationFrame(frame);
      landing = false;
    },
  };
}
