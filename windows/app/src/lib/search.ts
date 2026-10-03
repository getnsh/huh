/* Full-text search across every transcript: the Mac's SearchIndex, ported
   rule for rule so the same query finds the same transcripts, in the same
   order, with the same lines quoted, on both.

   An inverted index rather than a scan. A substring scan is fine for a
   handful of dictations and hopeless at the store's 500-transcript cap, where
   some of them are hour-long meetings; tokenising once and intersecting
   posting lists keeps every keystroke cheap. It is built once per history and
   dropped with it. Nothing here leaves the machine. */
import { timecode } from "./format";
import type { Transcript, Uuid } from "./types";

export type Snippet = {
  /* Seconds into the recording, for a line of a timeline; null for an
     excerpt of a transcript that has none. */
  start: number | null;
  timecode: string | null;
  text: string;
};

export type Hit = { transcript: Transcript; score: number; snippets: Snippet[] };

/* Letters, numbers and the straight apostrophe, as the Mac splits: "don't" is
   one word, "state-of-the-art" four, and a curly apostrophe splits like any
   other punctuation. Marks travel with their letter, so a decomposed "é" is
   not cut in two. */
const WORD = /[\p{L}\p{M}\p{N}']+/gu;

const graphemes = new Intl.Segmenter(undefined, { granularity: "grapheme" });

/* Characters as Swift counts them. Code points agree for nearly every word;
   only a short one can be the difference between one character and two, so
   only those are segmented properly. */
function characters(token: string): number {
  let count = 0;
  for (const _ of token) {
    if (++count > 3) return count;
  }
  return [...graphemes.segment(token)].length;
}

/* Lowercased words of two characters or more. Normalised to one form, as
   Swift's String equality is, so a word typed precomposed finds the same word
   stored decomposed. */
export function tokenise(text: string): string[] {
  const out: string[] = [];
  for (const [token] of text.toLowerCase().normalize("NFC").matchAll(WORD)) {
    if (characters(token) > 1) out.push(token);
  }
  return out;
}

const fold = (text: string) => text.toLocaleLowerCase().normalize("NFC");

/* Non-overlapping occurrences, as `components(separatedBy:).count - 1`. */
function occurrences(haystack: string, needle: string): number {
  if (!needle) return 0;
  let count = 0;
  for (let at = haystack.indexOf(needle); at !== -1; at = haystack.indexOf(needle, at + needle.length)) {
    count += 1;
  }
  return count;
}

const escape = (text: string) => text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

const isHighSurrogate = (code: number) => code >= 0xd800 && code <= 0xdbff;
const isLowSurrogate = (code: number) => code >= 0xdc00 && code <= 0xdfff;

/* Where the query turns up in a transcript. A timeline is preferred: for a
   long recording, knowing which transcript holds a word is not a useful
   answer, and the line it was said in, with its time, is. */
function snippetsIn(transcript: Transcript, phrase: string, terms: string[]): Snippet[] {
  const needle = phrase === "" ? terms[0] : phrase;

  if (transcript.segments.length > 0) {
    const folded = fold(needle);
    const out: Snippet[] = [];
    for (const segment of transcript.segments) {
      const text = fold(segment.text);
      if (text.includes(folded) || terms.every((term) => text.includes(term))) {
        out.push({ start: segment.start, timecode: timecode(segment.start), text: segment.text });
        if (out.length === 6) break;
      }
    }
    return out;
  }

  // Seventy characters either side of the first occurrence, as the Mac
  // quotes it. Searched in the original text so the offsets stay true.
  const text = transcript.text;
  const match = new RegExp(escape(needle), "iu").exec(text);
  if (!match) return [];
  let start = Math.max(0, match.index - 70);
  let end = Math.min(text.length, match.index + match[0].length + 70);
  if (start > 0 && isLowSurrogate(text.charCodeAt(start))) start -= 1;
  if (end < text.length && isHighSurrogate(text.charCodeAt(end - 1))) end += 1;
  let excerpt = text.slice(start, end);
  if (start > 0) excerpt = "…" + excerpt;
  if (end < text.length) excerpt += "…";
  return [{ start: null, timecode: null, text: excerpt }];
}

export class SearchIndex {
  private readonly postings = new Map<string, Set<Uuid>>();
  /* Every word, sorted, so a prefix is a contiguous run found by halving. */
  private readonly words: string[];
  private readonly byId = new Map<Uuid, Transcript>();

  constructor(private readonly transcripts: Transcript[]) {
    for (const transcript of transcripts) {
      this.byId.set(transcript.id, transcript);
      this.add(transcript.id, transcript.text);
      // A recording's file name is part of what it is called.
      if (transcript.sourceName) this.add(transcript.id, transcript.sourceName);
    }
    this.words = [...this.postings.keys()].sort();
  }

  private add(id: Uuid, text: string) {
    for (const token of tokenise(text)) {
      let ids = this.postings.get(token);
      if (!ids) this.postings.set(token, (ids = new Set()));
      ids.add(id);
    }
  }

  /* Every transcript holding a word that begins with `prefix`. */
  private prefixed(prefix: string): Set<Uuid> {
    let low = 0;
    let high = this.words.length;
    while (low < high) {
      const middle = (low + high) >> 1;
      if (this.words[middle] < prefix) low = middle + 1;
      else high = middle;
    }
    const out = new Set<Uuid>();
    for (let index = low; index < this.words.length && this.words[index].startsWith(prefix); index += 1) {
      for (const id of this.postings.get(this.words[index]) ?? []) out.add(id);
    }
    return out;
  }

  /* Every word must be present, and the last one is matched as a prefix, so
     results narrow as the query is typed rather than vanishing mid-word. A
     query with no words in it, a single letter, say, matches everything. */
  search(query: string): Hit[] {
    const terms = tokenise(query);
    if (terms.length === 0) {
      return this.transcripts.map((transcript) => ({ transcript, score: 0, snippets: [] }));
    }

    let candidates: Set<Uuid> | null = null;
    for (const [offset, term] of terms.entries()) {
      const matches: Set<Uuid> =
        offset === terms.length - 1 ? this.prefixed(term) : (this.postings.get(term) ?? new Set<Uuid>());
      const narrowed: Set<Uuid> =
        candidates === null ? matches : new Set([...candidates].filter((id) => matches.has(id)));
      if (narrowed.size === 0) return [];
      candidates = narrowed;
    }

    const phrase = query.trim();
    const hits: Hit[] = [];
    for (const id of candidates ?? []) {
      const transcript = this.byId.get(id);
      if (!transcript) continue;
      const snippets = snippetsIn(transcript, phrase, terms);
      // Ranked by density: quoted lines count for most, then how often the
      // first word recurs anywhere in the text.
      const score = snippets.length * 10 + occurrences(transcript.text.toLowerCase(), terms[0]);
      hits.push({ transcript, score, snippets });
    }
    return hits.sort(
      (a, b) => b.score - a.score || Date.parse(b.transcript.date) - Date.parse(a.transcript.date),
    );
  }
}

const built = new WeakMap<Transcript[], SearchIndex>();

/* The index for a history, built on first use and kept until the history is
   replaced: the core always sends a new list, so a new list is a new index. */
export function searchIndex(transcripts: Transcript[]): SearchIndex {
  let index = built.get(transcripts);
  if (!index) built.set(transcripts, (index = new SearchIndex(transcripts)));
  return index;
}
