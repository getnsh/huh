/* The Markdown a summary is written in, read the way the Mac's MarkdownBlock
   reads it. Lines carry the structure: a heading, a bullet, or a paragraph.
   Within a line only emphasis and code are honoured, and everything else
   stays the literal text it is. Nothing here produces markup; the view draws
   each run as text, so a summary can never put HTML into the page.

   Emphasis follows CommonMark's delimiter rules, which is what the Mac's
   parser implements. The rules are what keep `snake_case_names` and `2*3*4`
   from turning italic halfway through, and what decide `***both***`. */

export type Line =
  | { kind: "heading"; text: string }
  | { kind: "bullet"; text: string }
  | { kind: "text"; text: string };

export type Run = { text: string; strong: boolean; em: boolean; code: boolean };

/* Every line trimmed and the empty ones dropped, as the Mac splits them. A
   heading loses all its leading #s and spaces; a bullet, its first two
   characters. */
export function lines(markdown: string): Line[] {
  return markdown
    .split(/\r\n|[\n\v\f\r\u0085\u2028\u2029]/)
    .map((line) => line.trim())
    .filter((line) => line !== "")
    .map((line): Line => {
      if (line.startsWith("#")) return { kind: "heading", text: line.replace(/^[# ]+/, "") };
      if (line.startsWith("- ") || line.startsWith("* ")) return { kind: "bullet", text: line.slice(2) };
      return { kind: "text", text: line };
    });
}

type Delimiter = {
  char: "*" | "_";
  /* Characters not yet used by a match. */
  count: number;
  /* Characters in the run as written, which the rule of three reads. */
  length: number;
  open: boolean;
  close: boolean;
  active: boolean;
};

type Piece = { text: string; strong: boolean; em: boolean; code: boolean; run?: Delimiter };

const SPACE = /\s/u;
const PUNCTUATION = /[\p{P}\p{S}]/u;
const ESCAPABLE = /^[!-/:-@[-`{-~]$/;

/* One line's runs of plain, strong, emphasised and code text, adjacent runs
   alike merged. */
export function inline(source: string): Run[] {
  // Code points rather than UTF-16 units, so a character either side of a
  // delimiter is a whole one when its kind is judged.
  const chars = Array.from(source);
  const pieces: Piece[] = [];

  const text = (value: string, code = false) => {
    const last = pieces[pieces.length - 1];
    if (!code && last && !last.code && !last.run) last.text += value;
    else pieces.push({ text: value, strong: false, em: false, code });
  };

  let i = 0;
  while (i < chars.length) {
    const char = chars[i];

    if (char === "\\" && ESCAPABLE.test(chars[i + 1] ?? "")) {
      text(chars[i + 1]);
      i += 2;
      continue;
    }

    if (char === "`") {
      const width = runLength(chars, i);
      const end = closingTicks(chars, i + width, width);
      if (end === -1) {
        text("`".repeat(width));
        i += width;
        continue;
      }
      let content = chars.slice(i + width, end).join("");
      // One space is taken from each end when both have one, so `` ` `` `
      // can show a backtick; a span of nothing but spaces is left as it is.
      if (content.startsWith(" ") && content.endsWith(" ") && content.trim() !== "") {
        content = content.slice(1, -1);
      }
      text(content, true);
      i = end + width;
      continue;
    }

    if (char === "*" || char === "_") {
      const width = runLength(chars, i);
      const before = chars[i - 1] ?? " ";
      const after = chars[i + width] ?? " ";
      const left =
        !SPACE.test(after) &&
        (!PUNCTUATION.test(after) || SPACE.test(before) || PUNCTUATION.test(before));
      const right =
        !SPACE.test(before) &&
        (!PUNCTUATION.test(before) || SPACE.test(after) || PUNCTUATION.test(after));
      // An underscore inside a word is part of the word.
      const open = char === "*" ? left : left && (!right || PUNCTUATION.test(before));
      const close = char === "*" ? right : right && (!left || PUNCTUATION.test(after));
      if (open || close) {
        const run: Delimiter = { char, count: width, length: width, open, close, active: true };
        pieces.push({ text: "", strong: false, em: false, code: false, run });
      } else {
        text(char.repeat(width));
      }
      i += width;
      continue;
    }

    text(char);
    i += 1;
  }

  pair(pieces);

  const runs: Run[] = [];
  for (const piece of pieces) {
    const value = piece.run ? piece.run.char.repeat(piece.run.count) : piece.text;
    if (value === "") continue;
    const last = runs[runs.length - 1];
    if (last && last.strong === piece.strong && last.em === piece.em && last.code === piece.code) {
      last.text += value;
    } else {
      runs.push({ text: value, strong: piece.strong, em: piece.em, code: piece.code });
    }
  }
  return runs;
}

/* CommonMark's "process emphasis": each closing run, left to right, takes the
   nearest opening run of its own character before it, two characters for
   strong when both have two, one for emphasis otherwise. Whatever a match
   encloses takes its style, and runs left between the two can no longer
   match. Anything still unmatched at the end is literal. */
function pair(pieces: Piece[]): void {
  const runs = pieces.flatMap((piece, at) => (piece.run ? [at] : []));

  let c = 0;
  while (c < runs.length) {
    const closerAt = runs[c];
    const closer = pieces[closerAt].run!;
    if (!closer.active || !closer.close) {
      c += 1;
      continue;
    }

    let o = c - 1;
    while (o >= 0 && !opens(pieces[runs[o]].run!, closer)) o -= 1;
    if (o < 0) {
      // Nothing for it to close; if it cannot open either, it is literal.
      if (!closer.open) closer.active = false;
      c += 1;
      continue;
    }

    const openerAt = runs[o];
    const opener = pieces[openerAt].run!;
    const use = opener.count >= 2 && closer.count >= 2 ? 2 : 1;
    for (let k = openerAt + 1; k < closerAt; k += 1) {
      if (use === 2) pieces[k].strong = true;
      else pieces[k].em = true;
    }
    for (let k = o + 1; k < c; k += 1) pieces[runs[k]].run!.active = false;

    opener.count -= use;
    closer.count -= use;
    if (opener.count === 0) opener.active = false;
    if (closer.count === 0) {
      closer.active = false;
      c += 1;
    }
  }
}

/* Whether a run can open what `closer` closes. The rule of three keeps
   `*foo**bar*` from pairing the wrong runs: where either run could both open
   and close, two whose lengths add up to a multiple of three do not pair,
   unless both lengths are multiples of three themselves. */
function opens(opener: Delimiter, closer: Delimiter): boolean {
  if (!opener.active || !opener.open || opener.char !== closer.char) return false;
  if (!(opener.close || closer.open)) return true;
  const both = opener.length % 3 === 0 && closer.length % 3 === 0;
  return (opener.length + closer.length) % 3 !== 0 || both;
}

function runLength(chars: string[], from: number): number {
  let width = 1;
  while (chars[from + width] === chars[from]) width += 1;
  return width;
}

/* Where a run of exactly `width` backticks starts, or -1. A longer or shorter
   run does not close the span. */
function closingTicks(chars: string[], from: number, width: number): number {
  let at = from;
  while (at < chars.length) {
    if (chars[at] !== "`") {
      at += 1;
      continue;
    }
    const found = runLength(chars, at);
    if (found === width) return at;
    at += found;
  }
  return -1;
}
