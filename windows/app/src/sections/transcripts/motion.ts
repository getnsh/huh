/* The Mac's two curves, as Svelte transitions.

   A CSS animation can name `--spring` and `--quick` directly. A transition
   that also has to play as something leaves needs them as functions, so they
   are read from the same tokens rather than written down a second time, and
   reduced motion, which shortens the tokens to a millisecond, lands every
   transition on its final state. */
import type { TransitionConfig } from "svelte/transition";

type Easing = (t: number) => number;

const curves = new Map<string, Easing>();

const token = (name: string) =>
  getComputedStyle(document.documentElement).getPropertyValue(name).trim();

function milliseconds(name: string): number {
  const raw = token(name);
  const value = parseFloat(raw);
  if (!Number.isFinite(value)) return 0;
  return raw.endsWith("ms") ? value : value * 1000;
}

/* `linear(0.0000 0.0%, 0.0215 2.5%, …)`, the spring as tokens.css holds it. */
function linear(raw: string): Easing | null {
  const points = [...raw.matchAll(/(-?\d*\.?\d+)\s+(-?\d*\.?\d+)%/g)].map((m) => ({
    at: Number(m[2]) / 100,
    value: Number(m[1]),
  }));
  if (points.length < 2) return null;
  return (t) => {
    if (t <= points[0].at) return points[0].value;
    for (let index = 1; index < points.length; index += 1) {
      const b = points[index];
      if (t <= b.at) {
        const a = points[index - 1];
        return b.at === a.at ? b.value : a.value + ((b.value - a.value) * (t - a.at)) / (b.at - a.at);
      }
    }
    return points[points.length - 1].value;
  };
}

/* `cubic-bezier(x1, y1, x2, y2)`, solved for x by halving. */
function bezier(raw: string): Easing | null {
  const m = raw.match(/cubic-bezier\(\s*([-\d.]+)\s*,\s*([-\d.]+)\s*,\s*([-\d.]+)\s*,\s*([-\d.]+)\s*\)/);
  if (!m) return null;
  const [x1, y1, x2, y2] = m.slice(1).map(Number);
  const along = (p1: number, p2: number, s: number) =>
    3 * p1 * s * (1 - s) ** 2 + 3 * p2 * s * s * (1 - s) + s ** 3;
  return (t) => {
    if (t <= 0) return 0;
    if (t >= 1) return 1;
    let low = 0;
    let high = 1;
    let s = t;
    for (let step = 0; step < 24; step += 1) {
      s = (low + high) / 2;
      if (along(x1, x2, s) < t) low = s;
      else high = s;
    }
    return along(y1, y2, s);
  };
}

function curve(name: string): Easing {
  let easing = curves.get(name);
  if (!easing) {
    const raw = token(name);
    easing = linear(raw) ?? bezier(raw) ?? ((t) => t);
    curves.set(name, easing);
  }
  return easing;
}

/* Fade and drift on the spring: the Mac's `.opacity.combined(with: .offset)`.
   Svelte plays the curve forward in time for a leaving element too, as
   SwiftUI plays a removal, so one function serves both directions. */
export function drift(_node: Element, { x = 0, y = 0 }: { x?: number; y?: number } = {}): TransitionConfig {
  return {
    duration: milliseconds("--spring-duration"),
    easing: curve("--spring"),
    css: (t, u) => `opacity: ${t}; transform: translate(${u * x}px, ${u * y}px);`,
  };
}

/* A plain fade on the quick curve, for what appears under the pointer. */
export function quickFade(_node: Element): TransitionConfig {
  return {
    duration: milliseconds("--quick-duration"),
    easing: curve("--quick"),
    css: (t) => `opacity: ${t};`,
  };
}
