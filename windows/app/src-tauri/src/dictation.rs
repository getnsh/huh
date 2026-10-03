//! The state machine everything else hangs off.
//!
//! ```text
//!   idle ──press──▶ starting ──▶ listening ──release──▶ transcribing ──▶ idle
//!                                    │                                    ▲
//!                                    └──────── too-short / error ─────────┘
//! ```
//!
//! The same five states as the Mac, for the same reason: every surface --
//! overlay, tray, window -- reads one value, so they cannot disagree about
//! whether the microphone is open.
//!
//! It decides and records, and does nothing else. Opening the microphone and
//! running the recogniser belong to the controller, which asks this what each
//! press and release means, so the rules are testable without either.
use std::time::{Duration, Instant};

use parking_lot::Mutex;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum State {
    Idle,
    Starting,
    Listening,
    Transcribing,
    Failed { message: String },
}

impl State {
    pub fn is_busy(&self) -> bool {
        matches!(self, Self::Starting | Self::Listening | Self::Transcribing)
    }
}

/// Activations shorter than this are stray keypresses, not speech.
pub const MINIMUM_UTTERANCE: Duration = Duration::from_millis(180);

/// What a release, or a stop from the window, turned out to mean.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Ending {
    /// Too short to be speech. Dropped.
    Cancelled,
    /// The microphone is still opening. The utterance ends the moment it is
    /// open, as the Mac's `stopRequested` ends it.
    Deferred,
    /// Transcribe what was heard.
    Transcribe,
    /// Nothing was under way.
    Ignored,
}

/// What the microphone opening turned out to mean.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Opened {
    Listening,
    /// The key came up while the microphone was opening.
    Transcribe,
    /// The utterance was cancelled or failed while the microphone opened.
    Abandoned,
}

struct Inner {
    state: State,
    began_at: Option<Instant>,
    stop_requested: bool,
}

pub struct Machine {
    inner: Mutex<Inner>,
}

impl Default for Machine {
    fn default() -> Self {
        Self::new()
    }
}

impl Machine {
    pub fn new() -> Self {
        Self {
            inner: Mutex::new(Inner {
                state: State::Idle,
                began_at: None,
                stop_requested: false,
            }),
        }
    }

    pub fn state(&self) -> State {
        self.inner.lock().state.clone()
    }

    /// Idle or failed to starting. False when an utterance is already under
    /// way, so a second press does nothing.
    pub fn begin(&self) -> bool {
        let mut inner = self.inner.lock();
        if inner.state.is_busy() {
            return false;
        }
        inner.state = State::Starting;
        inner.began_at = Some(Instant::now());
        inner.stop_requested = false;
        true
    }

    /// Starting to listening, once the microphone is open.
    pub fn opened(&self) -> Opened {
        let mut inner = self.inner.lock();
        if inner.state != State::Starting {
            return Opened::Abandoned;
        }
        if std::mem::take(&mut inner.stop_requested) {
            inner.state = State::Transcribing;
            Opened::Transcribe
        } else {
            inner.state = State::Listening;
            Opened::Listening
        }
    }

    /// The key came up. A tap shorter than the minimum is cancelled.
    pub fn release(&self) -> Ending {
        self.end(true)
    }

    /// A stop from the window or a toggle, which is never too short.
    pub fn stop(&self) -> Ending {
        self.end(false)
    }

    fn end(&self, from_key: bool) -> Ending {
        let mut inner = self.inner.lock();
        let too_short = from_key
            && inner
                .began_at
                .map(|at| at.elapsed() < MINIMUM_UTTERANCE)
                .unwrap_or(false);
        match inner.state {
            State::Starting | State::Listening if too_short => {
                inner.state = State::Idle;
                Ending::Cancelled
            }
            State::Starting => {
                inner.stop_requested = true;
                Ending::Deferred
            }
            State::Listening => {
                inner.state = State::Transcribing;
                Ending::Transcribe
            }
            _ => Ending::Ignored,
        }
    }

    /// Time since the press, which is what the Mac records as a dictation's
    /// duration.
    pub fn since_begin(&self) -> Duration {
        self.inner
            .lock()
            .began_at
            .map(|at| at.elapsed())
            .unwrap_or_default()
    }

    pub fn finish(&self) {
        self.inner.lock().state = State::Idle;
    }

    pub fn fail(&self, message: impl Into<String>) {
        self.inner.lock().state = State::Failed {
            message: message.into(),
        };
    }

    /// A failure is shown for a moment and then cleared, unless a new press has
    /// already replaced it. True when it was cleared.
    pub fn clear_failure(&self) -> bool {
        let mut inner = self.inner.lock();
        if matches!(inner.state, State::Failed { .. }) {
            inner.state = State::Idle;
            true
        } else {
            false
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn wait_out_the_minimum() {
        std::thread::sleep(MINIMUM_UTTERANCE + Duration::from_millis(20));
    }

    #[test]
    fn a_stray_tap_is_ignored() {
        let machine = Machine::new();
        assert!(machine.begin());
        assert_eq!(machine.opened(), Opened::Listening);
        // Released immediately, so below the minimum.
        assert_eq!(machine.release(), Ending::Cancelled);
        assert_eq!(machine.state(), State::Idle);
    }

    #[test]
    fn a_real_utterance_transcribes() {
        let machine = Machine::new();
        machine.begin();
        assert_eq!(machine.state(), State::Starting);
        machine.opened();
        assert_eq!(machine.state(), State::Listening);
        wait_out_the_minimum();
        assert_eq!(machine.release(), Ending::Transcribe);
        assert_eq!(machine.state(), State::Transcribing);
        machine.finish();
        assert_eq!(machine.state(), State::Idle);
    }

    #[test]
    fn a_second_press_while_busy_does_nothing() {
        let machine = Machine::new();
        machine.begin();
        let first = machine.state();
        assert!(!machine.begin());
        assert_eq!(machine.state(), first);
    }

    #[test]
    fn a_release_while_the_microphone_opens_ends_it_once_open() {
        let machine = Machine::new();
        machine.begin();
        wait_out_the_minimum();
        assert_eq!(machine.release(), Ending::Deferred);
        assert_eq!(machine.state(), State::Starting);
        assert_eq!(machine.opened(), Opened::Transcribe);
        assert_eq!(machine.state(), State::Transcribing);
    }

    #[test]
    fn a_stop_from_the_window_is_never_too_short() {
        let machine = Machine::new();
        machine.begin();
        machine.opened();
        assert_eq!(machine.stop(), Ending::Transcribe);
    }

    #[test]
    fn a_microphone_that_opens_after_a_cancel_is_abandoned() {
        let machine = Machine::new();
        machine.begin();
        assert_eq!(machine.release(), Ending::Cancelled);
        assert_eq!(machine.opened(), Opened::Abandoned);
        assert_eq!(machine.state(), State::Idle);
    }

    #[test]
    fn a_failure_clears_but_not_over_a_new_press() {
        let machine = Machine::new();
        machine.fail("No microphone is connected.");
        assert!(machine.begin());
        assert!(!machine.clear_failure());
        assert_eq!(machine.state(), State::Starting);
    }
}
