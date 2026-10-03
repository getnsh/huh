/* Numbers and dates the way the Mac writes them. Intl cannot produce the
   Mac's "4 mins ago" or "1d ago", so these are written out by hand. */

const plural = (n: number, one: string, many: string) => (n === 1 ? one : many);

/* "{n} transcript{s}" and friends, for the strings the Mac pluralises. */
export const counted = (n: number, word: string, many = word + "s") =>
  `${n} ${plural(n, word, many)}`;

/* The largest whole unit: "1 min ago", "4 mins ago", "2 hrs ago", "1d ago". */
export function relative(iso: string, now = Date.now()): string {
  const then = new Date(iso).getTime();
  const seconds = Math.max(0, Math.floor((now - then) / 1000));
  if (seconds < 60) return seconds <= 1 ? "now" : `${seconds} secs ago`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return minutes === 1 ? "1 min ago" : `${minutes} mins ago`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return hours === 1 ? "1 hr ago" : `${hours} hrs ago`;
  const days = Math.floor(hours / 24);
  if (days < 7) return `${days}d ago`;
  const weeks = Math.floor(days / 7);
  if (days < 30) return `${weeks}w ago`;
  const months = Math.floor(days / 30);
  if (days < 365) return `${months}mo ago`;
  return `${Math.floor(days / 365)}y ago`;
}

/* A duration on a card or header: rounded, "0:05", "12:40", "1:02:09". */
export function clock(seconds: number): string {
  const total = Math.max(0, Math.round(seconds));
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  const ss = String(s).padStart(2, "0");
  return h > 0 ? `${h}:${String(m).padStart(2, "0")}:${ss}` : `${m}:${ss}`;
}

/* A segment's place in a transcript: rounded, "03:41", minutes unbounded. */
export function timecode(seconds: number): string {
  const total = Math.max(0, Math.round(seconds));
  return `${String(Math.floor(total / 60)).padStart(2, "0")}:${String(total % 60).padStart(2, "0")}`;
}

/* A running session's clock: truncated, "MM:SS", "H:MM:SS". */
export function elapsed(seconds: number): string {
  const total = Math.max(0, Math.floor(seconds));
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = String(total % 60).padStart(2, "0");
  return h > 0 ? `${h}:${String(m).padStart(2, "0")}:${s}` : `${String(m).padStart(2, "0")}:${s}`;
}

/* Words as the Mac counts them: split on spaces and newlines, empties out. */
export const wordCount = (text: string) => text.split(/[ \n]/).filter(Boolean).length;

export const shortDateTime = (iso: string) =>
  new Date(iso).toLocaleString(undefined, { dateStyle: "short", timeStyle: "short" });

export const mediumDateTime = (iso: string) => {
  const date = new Date(iso);
  const day = date.toLocaleDateString(undefined, { dateStyle: "medium" });
  const time = date.toLocaleTimeString(undefined, { timeStyle: "short" });
  return `${day} at ${time}`;
};

/* "C:\Users\ada\AppData\Roaming\Huh\dictionary.json" →
   "~\AppData\Roaming\Huh\dictionary.json", as the Mac shows "~/Library/…". */
export function homeRelative(path: string): string {
  const match = path.match(/^[A-Za-z]:\\Users\\[^\\]+/);
  return match ? "~" + path.slice(match[0].length) : path;
}
