/* The Mac's two curves, for Svelte's list animations and transitions, which
   take an easing function where CSS takes the tokens. The same numbers as
   tokens.css: a spring of response 0.32 and damping 0.86 over 450 ms, and an
   ease-out over 140 ms. Under reduced motion both take no time at all, so
   everything lands on its final state. */

export const SPRING = 450;
export const QUICK = 140;

const RESPONSE = 0.32;
const DAMPING = 0.86;

/* SwiftUI's spring(response:dampingFraction:), solved directly: an
   under-damped oscillator released from rest. */
export function spring(progress: number): number {
  if (progress >= 1) return 1;
  const natural = (2 * Math.PI) / RESPONSE;
  const damped = natural * Math.sqrt(1 - DAMPING * DAMPING);
  const t = progress * (SPRING / 1000);
  const decay = Math.exp(-DAMPING * natural * t);
  return 1 - decay * (Math.cos(damped * t) + ((DAMPING * natural) / damped) * Math.sin(damped * t));
}

/* cubic-bezier(x1, y1, x2, y2), as CSS evaluates it: x solved for t by
   Newton's method, then y read off. */
function cubicBezier(x1: number, y1: number, x2: number, y2: number) {
  const cx = 3 * x1;
  const bx = 3 * (x2 - x1) - cx;
  const ax = 1 - cx - bx;
  const cy = 3 * y1;
  const by = 3 * (y2 - y1) - cy;
  const ay = 1 - cy - by;
  const x = (t: number) => ((ax * t + bx) * t + cx) * t;
  const y = (t: number) => ((ay * t + by) * t + cy) * t;
  const slope = (t: number) => (3 * ax * t + 2 * bx) * t + cx;
  return (progress: number) => {
    if (progress <= 0) return 0;
    if (progress >= 1) return 1;
    let t = progress;
    for (let step = 0; step < 8; step++) {
      const error = x(t) - progress;
      const gradient = slope(t);
      if (Math.abs(error) < 1e-5 || gradient === 0) break;
      t -= error / gradient;
    }
    return y(Math.min(1, Math.max(0, t)));
  };
}

/* easeOut(duration: 0.14). */
export const quick = cubicBezier(0, 0, 0.58, 1);

/* A duration, or none at all when the person has asked for less motion. */
export function ms(duration: number): number {
  const reduced =
    typeof matchMedia === "function" && matchMedia("(prefers-reduced-motion: reduce)").matches;
  return reduced ? 0 : duration;
}
