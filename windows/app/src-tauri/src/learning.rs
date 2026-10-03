//! The learning pass: reading transcripts for the names and words worth
//! teaching it, and holding what it found until a person decides.
//!
//! The Mac's `LearningScan` reads each new transcript in 320-word passages,
//! two and a half seconds after it lands, and leaves three kinds of question:
//! names it was not sure of, mishearings it could fix, and words heard often
//! that no dictionary has. On the Mac a language model makes the guesses.
//! Windows has none to ask, so every guess here comes from what huh? already
//! knows: a word that sounds like a known name or term is offered as that,
//! and a word that looks like a name and sounds like nobody is asked about
//! plainly -- "is this someone's name?" -- so it can be told the right
//! spelling once and get it right from then on.
//!
//! Every answer is written to the ledger, so nothing is asked about twice.
//! The spell checker lives on this module's own thread, because a COM object
//! stays on the thread that made it.
use std::collections::HashSet;
use std::sync::OnceLock;
use std::time::Duration;

use crossbeam_channel::{unbounded, Receiver, Sender};
use parking_lot::Mutex;
use serde::Serialize;
use tauri::{AppHandle, Emitter, State};
use uuid::Uuid;

use huh_core::ledger::Decision;
use huh_core::model::{Transcript, TranscriptSource};
use huh_core::passages::{excerpt, passages};
use huh_core::safety::{self, Warning};
use huh_core::similar;
use huh_core::vocabulary::{self, Candidate, CapitalisedNames, SpellCheck};

use crate::{book, spelling, Shared};

/// How many of each kind the strips show at once.
const SHOWN: usize = 8;
/// How many questions are kept waiting, so a long meeting cannot bury the
/// strip in a hundred names.
const QUEUE_LIMIT: usize = 30;
/// The Mac waits this long after a transcript lands before reading it.
const QUEUE_DELAY: Duration = Duration::from_millis(2500);

/// "We heard X; it is probably Y."
#[derive(Debug, Clone, Serialize)]
pub struct Proposal {
    pub heard: String,
    pub write: String,
    pub context: String,
    pub warnings: Vec<Warning>,
}

/// "We heard X; is that someone's name?" `name` is the best guess at the
/// spelling, which is `heard` itself when nothing known sounds like it.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PersonProposal {
    pub heard: String,
    pub name: String,
    pub context: String,
    pub timecode: Option<String>,
    pub alternatives: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Suggestions {
    pub candidates: Vec<Candidate>,
    pub name_candidates: Vec<Candidate>,
    pub suppressed_count: u32,
    pub proposals: Vec<Proposal>,
    pub person_proposals: Vec<PersonProposal>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LearningState {
    pub running: bool,
    pub analysing: Option<Uuid>,
    pub stage: String,
    pub pending: usize,
    pub pending_count: usize,
    pub result: Option<String>,
    pub ignored_count: usize,
    pub last_run_found_nothing: bool,
}

#[derive(Default)]
struct Inner {
    running: bool,
    analysing: Option<Uuid>,
    stage: String,
    result: Option<String>,
    last_run_found_nothing: bool,
    candidates: Vec<Candidate>,
    name_candidates: Vec<Candidate>,
    suppressed: u32,
    proposals: Vec<Proposal>,
    person_proposals: Vec<PersonProposal>,
    queue_scheduled: bool,
}

enum Job {
    Refresh,
    Drain { manual: bool },
}

#[derive(Default)]
pub struct Learning {
    inner: Mutex<Inner>,
    jobs: OnceLock<Sender<Job>>,
}

impl Learning {
    fn send(&self, job: Job) {
        if let Some(jobs) = self.jobs.get() {
            let _ = jobs.send(job);
        }
    }

    fn suggestions(&self) -> Suggestions {
        let inner = self.inner.lock();
        Suggestions {
            candidates: inner.candidates.clone(),
            name_candidates: inner.name_candidates.clone(),
            suppressed_count: inner.suppressed,
            proposals: inner.proposals.clone(),
            person_proposals: inner.person_proposals.clone(),
        }
    }
}

/// Starts the reading thread. Called once, from setup.
pub fn start(handle: &AppHandle, app: &Shared) {
    let (jobs, inbox) = unbounded();
    let _ = app.learning.jobs.set(jobs);
    let handle = handle.clone();
    let app = app.clone();
    let _ = std::thread::Builder::new()
        .name("huh-learning".into())
        .spawn(move || run(handle, app, inbox));
}

/// Reads the new transcripts soon, unless that is already arranged.
pub fn schedule_queue(app: &Shared) {
    {
        let mut inner = app.learning.inner.lock();
        if inner.queue_scheduled {
            return;
        }
        inner.queue_scheduled = true;
    }
    let app = app.clone();
    std::thread::spawn(move || {
        std::thread::sleep(QUEUE_DELAY);
        app.learning.inner.lock().queue_scheduled = false;
        app.learning.send(Job::Drain { manual: false });
    });
}

/// Recounts the suggestions after something known changed.
pub fn refresh_soon(_handle: &AppHandle, app: &Shared) {
    app.learning.send(Job::Refresh);
}

/// Remembers what the system dictionary said about each word, because the
/// same few hundred words are asked about on every pass.
struct Cached<'a> {
    spell: &'a dyn SpellCheck,
    answers: Mutex<std::collections::HashMap<String, bool>>,
}

impl SpellCheck for Cached<'_> {
    fn is_misspelled(&self, word: &str) -> bool {
        if let Some(answer) = self.answers.lock().get(word) {
            return *answer;
        }
        let answer = self.spell.is_misspelled(word);
        self.answers.lock().insert(word.to_string(), answer);
        answer
    }
}

fn run(handle: AppHandle, app: Shared, inbox: Receiver<Job>) {
    let locale = app.settings.read().locale_identifier.clone();
    let system = spelling::system(&locale);
    let spell = Cached {
        spell: &*system,
        answers: Mutex::default(),
    };
    recover(&app, &spell);
    refresh(&handle, &app, &spell);
    schedule_queue(&app);

    while let Ok(job) = inbox.recv() {
        // Several refreshes asked for at once are one refresh.
        let mut manual = None;
        let mut jobs = vec![job];
        jobs.extend(inbox.try_iter());
        for job in jobs {
            if let Job::Drain { manual: asked } = job {
                manual = Some(manual.unwrap_or(false) || asked);
            }
        }
        match manual {
            Some(manual) => drain(&handle, &app, &spell, manual),
            None => refresh(&handle, &app, &spell),
        }
    }
}

/// How many of the newest transcripts with findings are read again at launch.
const RECOVER_LIMIT: usize = 60;

/// Asks again, at launch, what was found and never answered.
///
/// The questions live in memory, as the Mac's do, but a Windows app is
/// restarted by updates and reboots far more often than a Mac app is quit,
/// and a name asked about once and then lost is never asked about again: the
/// transcript it came from is already marked read. So the transcripts that
/// turned something up are read again, without being marked, and whatever
/// has been answered since is skipped by the same checks a first reading
/// makes: the dictionary, the people and the ledger.
fn recover(app: &Shared, spell: &dyn SpellCheck) {
    let transcripts: Vec<Transcript> = app
        .library
        .lock()
        .history
        .iter()
        .filter(|t| t.analysis_findings > 0 && t.analyzed_at.is_some())
        .take(RECOVER_LIMIT)
        .cloned()
        .collect();
    for transcript in &transcripts {
        analyse(app, transcript, spell);
    }
}

fn publish(handle: &AppHandle, app: &Shared) {
    let _ = handle.emit("suggestions", app.learning.suggestions());
    let _ = handle.emit("learning", state(app));
}

fn state(app: &Shared) -> LearningState {
    let (pending, ignored) = {
        let library = app.library.lock();
        (
            library.pending_analysis().len(),
            library.ledger.ignored_count(),
        )
    };
    let inner = app.learning.inner.lock();
    LearningState {
        running: inner.running,
        analysing: inner.analysing,
        stage: inner.stage.clone(),
        pending,
        pending_count: inner.candidates.len()
            + inner.name_candidates.len()
            + inner.proposals.len()
            + inner.person_proposals.len(),
        result: inner.result.clone(),
        ignored_count: ignored,
        last_run_found_nothing: inner.last_run_found_nothing,
    }
}

/// The deterministic half: words heard at least twice that no dictionary
/// has, and names anywhere, against everything already accounted for.
fn refresh(handle: &AppHandle, app: &Shared, spell: &dyn SpellCheck) {
    let (texts, known, ledger) = {
        let library = app.library.lock();
        let texts: Vec<String> = library.history.iter().map(|t| t.text.clone()).collect();
        (texts, library.accounted_for(), library.ledger.clone())
    };
    let tagger = CapitalisedNames { spell };
    let references: Vec<&str> = texts.iter().map(String::as_str).collect();
    let found = vocabulary::scan(&references, 2, &known, &ledger, spell, &tagger);
    {
        let mut inner = app.learning.inner.lock();
        // A name already waiting as a question is not also a chip.
        let asked: HashSet<String> = inner
            .person_proposals
            .iter()
            .map(|p| p.heard.to_lowercase())
            .collect();
        inner.candidates = found
            .candidates
            .iter()
            .filter(|c| !c.is_name)
            .take(SHOWN)
            .cloned()
            .collect();
        inner.name_candidates = found
            .candidates
            .iter()
            .filter(|c| c.is_name && !asked.contains(&c.word.to_lowercase()))
            .take(SHOWN)
            .cloned()
            .collect();
        inner.suppressed = found.suppressed;
    }
    publish(handle, app);
}

/// Reads every transcript not yet read, newest first.
fn drain(handle: &AppHandle, app: &Shared, spell: &dyn SpellCheck, manual: bool) {
    {
        let mut inner = app.learning.inner.lock();
        if inner.running {
            return;
        }
        inner.running = true;
        if manual {
            inner.result = None;
        }
    }
    let pending = app.library.lock().pending_analysis();
    if manual && app.library.lock().history.is_empty() {
        let mut inner = app.learning.inner.lock();
        inner.running = false;
        inner.result =
            Some("Nothing to learn from yet — dictate or transcribe something first.".into());
        drop(inner);
        publish(handle, app);
        return;
    }
    publish(handle, app);

    for id in pending {
        let Some(transcript) = app
            .library
            .lock()
            .history
            .iter()
            .find(|t| t.id == id)
            .cloned()
        else {
            continue;
        };
        {
            let mut inner = app.learning.inner.lock();
            inner.analysing = Some(id);
            inner.stage = match transcript.source {
                TranscriptSource::Dictation => "Reading your dictation…".into(),
                _ => format!("Reading {}…", transcript.display_name()),
            };
        }
        publish(handle, app);
        let findings = analyse(app, &transcript, spell);
        let history = {
            let mut library = app.library.lock();
            library.mark_analysed(id, findings);
            library.history.clone()
        };
        let _ = handle.emit("history", history);
    }

    {
        let mut inner = app.learning.inner.lock();
        inner.running = false;
        inner.analysing = None;
        inner.stage.clear();
    }
    refresh(handle, app, spell);

    if manual {
        let (names, fixes, words) = {
            let inner = app.learning.inner.lock();
            (
                inner.person_proposals.len() + inner.name_candidates.len(),
                inner.proposals.len(),
                inner.candidates.len(),
            )
        };
        let ignored = app.library.lock().ledger.ignored_count();
        {
            let mut inner = app.learning.inner.lock();
            inner.last_run_found_nothing = fixes == 0;
            inner.result = Some(describe(names, fixes, words, ignored));
        }
        let tab = if names > 0 {
            "people"
        } else if fixes > 0 {
            "corrections"
        } else {
            "words"
        };
        let _ = handle.emit(
            "navigate",
            serde_json::json!({ "section": "dictionary", "tab": tab }),
        );
        publish(handle, app);
    }
}

fn count(n: usize, one: &str, many: &str) -> String {
    format!("{n} {}", if n == 1 { one } else { many })
}

/// What a manual pass says it found, in the Mac's words.
fn describe(names: usize, fixes: usize, words: usize, ignored: usize) -> String {
    let mut parts = Vec::new();
    if names > 0 {
        parts.push(count(names, "name", "names"));
    }
    if fixes > 0 {
        parts.push(count(fixes, "suggested fix", "suggested fixes"));
    }
    if words > 0 {
        parts.push(count(words, "unfamiliar word", "unfamiliar words"));
    }
    if !parts.is_empty() {
        return format!("{} to review.", parts.join(", "));
    }
    match ignored {
        0 => {
            "Nothing new — every transcript has been read and everything in them is already known."
                .into()
        }
        1 => "Nothing new. 1 suggestion is hidden because you dismissed it.".into(),
        n => format!("Nothing new. {n} suggestions are hidden because you dismissed them."),
    }
}

/// Reads one transcript and queues what it found. Returns how many.
fn analyse(app: &Shared, transcript: &Transcript, spell: &dyn SpellCheck) -> u32 {
    let (mut known, ledger, names, vocabulary) = {
        let library = app.library.lock();
        let names: Vec<String> = library
            .people
            .people
            .iter()
            .filter(|p| p.enabled)
            .map(|p| p.name.clone())
            .collect();
        let mut vocabulary: Vec<String> = library
            .dictionary
            .terms
            .iter()
            .filter(|t| t.enabled)
            .map(|t| t.text.clone())
            .collect();
        vocabulary.extend(
            library
                .dictionary
                .corrections
                .iter()
                .filter(|p| p.enabled)
                .map(|p| p.write.clone()),
        );
        vocabulary.extend(names.iter().cloned());
        vocabulary.sort();
        vocabulary.dedup();
        (
            library.accounted_for(),
            library.ledger.clone(),
            names,
            vocabulary,
        )
    };

    let tagger = CapitalisedNames { spell };
    let mut people = Vec::new();
    let mut fixes = Vec::new();
    for passage in passages(transcript) {
        // Something that sounds like a known term is a fix, not a question.
        // Something that sounds like someone already known is that person,
        // misheard: asked as a name, so the answer files the spelling with
        // them, as the Mac's reading does with its roster of people.
        for miss in similar::near_misses(&passage.text, &vocabulary, spell) {
            let key = miss.heard.to_lowercase();
            if known.contains(&key) || ledger.is_decided(&key) {
                continue;
            }
            known.insert(key);
            let person = names
                .iter()
                .any(|name| name.to_lowercase() == miss.known.to_lowercase());
            if person {
                people.push(PersonProposal {
                    name: miss.known.clone(),
                    context: excerpt(&passage.text, &miss.heard),
                    timecode: passage.timecode.clone(),
                    alternatives: vec![miss.known],
                    heard: miss.heard,
                });
                continue;
            }
            fixes.push(Proposal {
                warnings: safety::check(&miss.heard, &miss.known),
                context: excerpt(&passage.text, &miss.heard),
                heard: miss.heard,
                write: miss.known,
            });
        }
        let found = vocabulary::scan(&[&passage.text], 1, &known, &ledger, spell, &tagger);
        for candidate in found.candidates.into_iter().filter(|c| c.is_name) {
            let key = candidate.word.to_lowercase();
            if known.contains(&key) {
                continue;
            }
            known.insert(key);
            let alternatives = similar::alternatives(&candidate.word, &names, 3);
            people.push(PersonProposal {
                name: alternatives
                    .first()
                    .cloned()
                    .unwrap_or_else(|| candidate.word.clone()),
                context: excerpt(&passage.text, &candidate.word),
                timecode: passage.timecode.clone(),
                alternatives,
                heard: candidate.word,
            });
        }
    }

    let findings = (people.len() + fixes.len()) as u32;
    let mut inner = app.learning.inner.lock();
    for proposal in people {
        let key = proposal.heard.to_lowercase();
        if !inner
            .person_proposals
            .iter()
            .any(|p| p.heard.to_lowercase() == key)
            && inner.person_proposals.len() < QUEUE_LIMIT
        {
            inner.person_proposals.push(proposal);
        }
    }
    for proposal in fixes {
        let key = proposal.heard.to_lowercase();
        if !inner
            .proposals
            .iter()
            .any(|p| p.heard.to_lowercase() == key)
            && inner.proposals.len() < QUEUE_LIMIT
        {
            inner.proposals.push(proposal);
        }
    }
    findings
}

/* ── Commands ── */

type Done = Result<(), String>;

fn retire(app: &Shared, word: &str) {
    let key = word.to_lowercase();
    let mut inner = app.learning.inner.lock();
    inner.candidates.retain(|c| c.word.to_lowercase() != key);
    inner
        .name_candidates
        .retain(|c| c.word.to_lowercase() != key);
}

/// After an answer: the window hears about the dictionary, the history the
/// answer may have rewritten, and what is left to decide.
fn answered(handle: &AppHandle, app: &Shared) {
    book::publish(handle, app, true);
    publish(handle, app);
}

#[tauri::command]
pub fn suggestions(app: State<'_, Shared>) -> Suggestions {
    app.learning.suggestions()
}

#[tauri::command]
pub fn learning_state(app: State<'_, Shared>) -> LearningState {
    state(&app)
}

#[tauri::command]
pub fn run_learning(app: State<'_, Shared>) {
    app.learning.send(Job::Drain { manual: true });
}

#[tauri::command]
pub async fn accept_candidate(app: State<'_, Shared>, handle: AppHandle, word: String) -> Done {
    {
        let mut library = app.library.lock();
        library.add_term(&word, "");
        library.decide(&word, Decision::Term, &word);
    }
    retire(&app, &word);
    answered(&handle, &app);
    Ok(())
}

#[tauri::command]
pub async fn accept_candidate_as_person(
    app: State<'_, Shared>,
    handle: AppHandle,
    word: String,
) -> Done {
    {
        let mut library = app.library.lock();
        library.add_person(&word, None, "", true);
        library.decide(&word, Decision::Person, &word);
    }
    retire(&app, &word);
    answered(&handle, &app);
    Ok(())
}

#[tauri::command]
pub async fn dismiss_candidate(app: State<'_, Shared>, handle: AppHandle, word: String) -> Done {
    app.library.lock().decide(&word, Decision::Ignored, "");
    retire(&app, &word);
    answered(&handle, &app);
    Ok(())
}

#[tauri::command]
pub async fn reset_dismissed(app: State<'_, Shared>, handle: AppHandle) -> Done {
    app.library.lock().restore_ignored();
    answered(&handle, &app);
    Ok(())
}

fn take_proposal(app: &Shared, heard: &str) -> Option<Proposal> {
    let key = heard.to_lowercase();
    let mut inner = app.learning.inner.lock();
    let index = inner
        .proposals
        .iter()
        .position(|p| p.heard.to_lowercase() == key)?;
    Some(inner.proposals.remove(index))
}

#[tauri::command]
pub async fn accept_proposal(app: State<'_, Shared>, handle: AppHandle, heard: String) -> Done {
    if let Some(proposal) = take_proposal(&app, &heard) {
        let mut library = app.library.lock();
        library.add_correction(&proposal.heard, &proposal.write);
        library.decide(&proposal.heard, Decision::Correction, &proposal.write);
    }
    retire(&app, &heard);
    answered(&handle, &app);
    Ok(())
}

#[tauri::command]
pub async fn proposal_as_person(app: State<'_, Shared>, handle: AppHandle, heard: String) -> Done {
    if let Some(proposal) = take_proposal(&app, &heard) {
        let mut library = app.library.lock();
        library.add_person(&proposal.write, Some(&proposal.heard), "", true);
        library.decide(&proposal.heard, Decision::Person, &proposal.write);
    }
    retire(&app, &heard);
    answered(&handle, &app);
    Ok(())
}

/// Removed without a ruling: the editor opens with it, and saving there is
/// the decision.
#[tauri::command]
pub async fn take_proposal_for_edit(
    app: State<'_, Shared>,
    handle: AppHandle,
    heard: String,
) -> Done {
    take_proposal(&app, &heard);
    publish(&handle, &app);
    Ok(())
}

#[tauri::command]
pub async fn dismiss_proposal(app: State<'_, Shared>, handle: AppHandle, heard: String) -> Done {
    take_proposal(&app, &heard);
    app.library.lock().decide(&heard, Decision::Ignored, "");
    retire(&app, &heard);
    answered(&handle, &app);
    Ok(())
}

fn take_person_proposal(app: &Shared, heard: &str) {
    let key = heard.to_lowercase();
    app.learning
        .inner
        .lock()
        .person_proposals
        .retain(|p| p.heard.to_lowercase() != key);
}

/// "Yes, that is a name, and this is how it is spelled." When the spelling
/// differs from what was heard, what was heard becomes an alias that rewrites
/// to the name: in every transcript already kept, and in every one after.
#[tauri::command]
pub async fn accept_person_proposal(
    app: State<'_, Shared>,
    handle: AppHandle,
    heard: String,
    name: String,
) -> Done {
    take_person_proposal(&app, &heard);
    {
        let mut library = app.library.lock();
        let alias =
            (heard.trim().to_lowercase() != name.trim().to_lowercase()).then_some(heard.as_str());
        library.add_person(&name, alias, "", true);
        library.decide(&heard, Decision::Person, &name);
    }
    retire(&app, &heard);
    answered(&handle, &app);
    Ok(())
}

#[tauri::command]
pub async fn dismiss_person_proposal(
    app: State<'_, Shared>,
    handle: AppHandle,
    heard: String,
) -> Done {
    take_person_proposal(&app, &heard);
    app.library.lock().decide(&heard, Decision::Ignored, "");
    retire(&app, &heard);
    answered(&handle, &app);
    Ok(())
}

/// "Show Dismissed": forget every dismissal, then read again.
#[tauri::command]
pub async fn restore_dismissed(app: State<'_, Shared>, handle: AppHandle) -> Done {
    app.library.lock().restore_ignored();
    publish(&handle, &app);
    app.learning.send(Job::Drain { manual: true });
    Ok(())
}

#[tauri::command]
pub fn dismiss_scan_result(app: State<'_, Shared>, handle: AppHandle) {
    app.learning.inner.lock().result = None;
    publish(&handle, &app);
}

#[cfg(test)]
mod tests {
    use super::describe;

    #[test]
    fn a_pass_says_what_it_found_in_the_macs_words() {
        assert_eq!(describe(2, 1, 0, 0), "2 names, 1 suggested fix to review.");
        assert_eq!(describe(0, 0, 3, 0), "3 unfamiliar words to review.");
        assert_eq!(
            describe(0, 0, 0, 1),
            "Nothing new. 1 suggestion is hidden because you dismissed it."
        );
        assert_eq!(
            describe(0, 0, 0, 0),
            "Nothing new — every transcript has been read and everything in them is already known."
        );
    }
}
