/* The few rules the Dictionary applies in the view itself, each written to
   match the Mac's line for line, so the view and the core never disagree
   about what an entry does. */
import type { CorrectionPair } from "../../lib/types";

/* Whether an enabled correction already guarantees this spelling. A word
   without one is only a hint to the recogniser, and its row says so. */
export function hasCorrectionTargeting(corrections: CorrectionPair[], term: string): boolean {
  const target = term.trim().toLowerCase();
  if (!target) return false;
  return corrections.some((pair) => pair.enabled && pair.write.trim().toLowerCase() === target);
}

/* "Also heard as" is one comma-separated field rather than a list control:
   a name usually has one or two mis-hearings, and a list editor for two
   items costs more to use than it saves. */
export const splitAliases = (raw: string): string[] =>
  raw
    .split(/[,\n]/)
    .map((alias) => alias.trim())
    .filter(Boolean);

/* The literal forms a trigger also matches, so separator tolerance is shown
   rather than implied. Split on whitespace and hyphens only, as the Mac's
   editor splits; the engine accepts underscores too. Sorted by code point,
   as Swift sorts strings. */
export function catchesVariants(hear: string): string[] {
  const words = hear.trim().split(/[\s-]+/).filter(Boolean);
  const forms = words.length > 1 ? [words.join(" "), words.join(""), words.join("-")] : words;
  return [...new Set(forms)].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
}

/* Search matches the way the Mac's localizedCaseInsensitiveContains does:
   any part of the text, ignoring case. `query` is already lower-cased. */
export const contains = (text: string, query: string): boolean =>
  text.toLocaleLowerCase().includes(query);
