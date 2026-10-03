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
const MINIMUM_UTTERANCE: Duration = Duration::from_millis(180);

struct Inner {
    state: State,
    pressed_at: Option<Instant>,
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
                pressed_at: None,
            }),
        }
    }

    pub fn state(&self) -> State {
        self.inner.lock().state.clone()
    }

    pub fn press(&self) {
        let mut inner = self.inner.lock();
        if inner.state.is_busy() {
            return;
        }
        inner.pressed_at = Some(Instant::now());
        inner.state = State::Listening;
    }

    /// Returns true when the utterance was long enough to transcribe.
    pub fn release(&self) -> bool {
        let mut inner = self.inner.lock();
        if inner.state != State::Listening {
            return false;
        }
        let long_enough = inner
            .pressed_at
            .map(|at| at.elapsed() >= MINIMUM_UTTERANCE)
            .unwrap_or(false);
        inner.pressed_at = None;
        inner.state = if long_enough {
            State::Transcribing
        } else {
            State::Idle
        };
        long_enough
    }

    pub fn toggle(&self) {
        let busy = self.state().is_busy();
        if busy {
            self.release();
        } else {
            self.press();
        }
    }

    pub fn finish(&self) {
        self.inner.lock().state = State::Idle;
    }

    pub fn fail(&self, message: impl Into<String>) {
        self.inner.lock().state = State::Failed {
            message: message.into(),
        };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_stray_tap_is_ignored() {
        let machine = Machine::new();
        machine.press();
        assert_eq!(machine.state(), State::Listening);
        // Released immediately, so below the minimum.
        assert!(!machine.release());
        assert_eq!(machine.state(), State::Idle);
    }

    #[test]
    fn a_real_utterance_transcribes() {
        let machine = Machine::new();
        machine.press();
        std::thread::sleep(MINIMUM_UTTERANCE + Duration::from_millis(20));
        assert!(machine.release());
        assert_eq!(machine.state(), State::Transcribing);
        machine.finish();
        assert_eq!(machine.state(), State::Idle);
    }

    #[test]
    fn a_second_press_while_busy_does_nothing() {
        let machine = Machine::new();
        machine.press();
        let first = machine.state();
        machine.press();
        assert_eq!(machine.state(), first);
    }
}
