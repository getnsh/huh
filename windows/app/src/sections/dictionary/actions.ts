/* What the Dictionary does when asked. The change shows at once, as it does
   on the Mac, and is then sent to the core, which owns the files and answers
   with a fresh "dictionary" or "suggestions" event. When a command fails the
   view is read again, so it never goes on showing a change that did not
   happen. */
import { api } from "../../lib/api";
import { core, ui } from "../../lib/state.svelte";
import type { PersonProposal, Proposal, Uuid } from "../../lib/types";

const same = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();

function rereadDictionary() {
  api
    .dictionary()
    .then((value) => (core.dictionary = value))
    .catch(() => {});
}

function rereadSuggestions() {
  api
    .suggestions()
    .then((value) => (core.suggestions = value))
    .catch(() => {});
}

/* ── Entries ─────────────────────────────────────────────────────────────── */

export function setTermEnabled(id: Uuid, on: boolean) {
  const term = core.dictionary?.terms.find((entry) => entry.id === id);
  if (term) term.enabled = on;
  api.setTermEnabled(id, on).catch(rereadDictionary);
}

export function deleteTerm(id: Uuid) {
  if (core.dictionary) {
    core.dictionary.terms = core.dictionary.terms.filter((entry) => entry.id !== id);
  }
  api.deleteTerm(id).catch(rereadDictionary);
}

export function setCorrectionEnabled(id: Uuid, on: boolean) {
  const pair = core.dictionary?.corrections.find((entry) => entry.id === id);
  if (pair) pair.enabled = on;
  api.setCorrectionEnabled(id, on).catch(rereadDictionary);
}

export function deleteCorrection(id: Uuid) {
  if (core.dictionary) {
    core.dictionary.corrections = core.dictionary.corrections.filter((entry) => entry.id !== id);
  }
  api.deleteCorrection(id).catch(rereadDictionary);
}

export function setPersonEnabled(id: Uuid, on: boolean) {
  const person = core.dictionary?.people.find((entry) => entry.id === id);
  if (person) person.enabled = on;
  api.setPersonEnabled(id, on).catch(rereadDictionary);
}

export function deletePerson(id: Uuid) {
  if (core.dictionary) {
    core.dictionary.people = core.dictionary.people.filter((entry) => entry.id !== id);
  }
  api.deletePerson(id).catch(rereadDictionary);
}

export function dismissRetroNote() {
  if (core.dictionary) core.dictionary.retroNote = null;
  api.dismissRetroNote().catch(rereadDictionary);
}

/* ── Suggestions ─────────────────────────────────────────────────────────── */

/* A word sits in exactly one of the two lists, but which one depends on a
   detector, so removal always addresses both. */
function dropCandidate(word: string) {
  const suggestions = core.suggestions;
  suggestions.candidates = suggestions.candidates.filter((entry) => !same(entry.word, word));
  suggestions.nameCandidates = suggestions.nameCandidates.filter((entry) => !same(entry.word, word));
}

export function acceptCandidate(word: string) {
  dropCandidate(word);
  api.acceptCandidate(word).catch(rereadSuggestions);
}

export function acceptCandidateAsPerson(word: string) {
  dropCandidate(word);
  api.acceptCandidateAsPerson(word).catch(rereadSuggestions);
}

export function dismissCandidate(word: string) {
  dropCandidate(word);
  api.dismissCandidate(word).catch(rereadSuggestions);
}

function dropProposal(heard: string) {
  core.suggestions.proposals = core.suggestions.proposals.filter((entry) => !same(entry.heard, heard));
}

export function acceptProposal(heard: string) {
  dropProposal(heard);
  api.acceptProposal(heard).catch(rereadSuggestions);
}

export function proposalAsPerson(heard: string) {
  dropProposal(heard);
  api.proposalAsPerson(heard).catch(rereadSuggestions);
}

export function dismissProposal(heard: string) {
  dropProposal(heard);
  api.dismissProposal(heard).catch(rereadSuggestions);
}

/* As on the Mac, the proposal leaves the queue as the editor opens, with
   nothing recorded: what is saved there is the answer. */
export function editProposal(proposal: Proposal) {
  dropProposal(proposal.heard);
  ui.editor = { mode: "correction", hear: proposal.heard, write: proposal.write };
  api.takeProposalForEdit(proposal.heard).catch(rereadSuggestions);
}

function dropPersonProposal(heard: string) {
  core.suggestions.personProposals = core.suggestions.personProposals.filter(
    (entry) => !same(entry.heard, heard),
  );
}

export function acceptPersonProposal(heard: string, name: string) {
  dropPersonProposal(heard);
  api.acceptPersonProposal(heard, name).catch(rereadSuggestions);
}

export function dismissPersonProposal(heard: string) {
  dropPersonProposal(heard);
  api.dismissPersonProposal(heard).catch(rereadSuggestions);
}

/* ── Opening the editor ──────────────────────────────────────────────────── */

/* "It's a mis-hearing — fix it…": the correction editor with the word in
   place and the passage it came from, so the replacement is chosen with the
   sentence in view. The suggestion stays where it is: cancelling must leave
   it, and saving retires it, because the word is then accounted for. */
export async function fixHeardWord(word: string) {
  let context = "";
  try {
    context = await api.correctionContext(word);
  } catch {
    // Opens without the passage rather than not at all.
  }
  ui.editor = { mode: "correction", hear: word, context };
}

/* The person proposal a person editor is answering, if it was opened from
   one. Read once by the editor as it opens; acted on only when it saves, so
   cancelling leaves the question where it was. */
export const followUp = { personProposal: null as string | null };

export function fixPersonProposal(proposal: PersonProposal, name: string, alias: string) {
  followUp.personProposal = proposal.heard;
  ui.editor = { mode: "person", name, aliases: alias };
}
