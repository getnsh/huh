//! Capture.
//!
//! `cpal` for the microphone, which is WASAPI underneath on Windows and
//! CoreAudio on a Mac, so the development machine can exercise the level meter
//! and the state machine without a PC in the room. Loopback -- what the machine
//! is playing, the "PC" trace beside "You" -- is WASAPI's own and Windows-only.
use std::sync::Arc;

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use parking_lot::Mutex;

/// Normalised RMS level, 0 to 1.
pub type Level = f32;

/// One second of levels at one sample per audio buffer, which is what the meter
/// draws.
pub const HISTORY_DEPTH: usize = 44;

#[derive(Default)]
pub struct Meter {
    history: Mutex<Vec<Level>>,
}

impl Meter {
    pub fn push(&self, value: Level) {
        let mut history = self.history.lock();
        history.push(value);
        if history.len() > HISTORY_DEPTH {
            let excess = history.len() - HISTORY_DEPTH;
            history.drain(..excess);
        }
    }

    pub fn history(&self) -> Vec<Level> {
        self.history.lock().clone()
    }

    pub fn clear(&self) {
        self.history.lock().clear();
    }
}

/// Scaled so that quiet speech still produces visible movement, matching the
/// Mac's `publishLevel`.
pub fn level_of(samples: &[f32]) -> Level {
    if samples.is_empty() {
        return 0.0;
    }
    let mut sum = 0.0f32;
    let mut count = 0usize;
    for value in samples.iter().step_by(8) {
        sum += value * value;
        count += 1;
    }
    let rms = (sum / count.max(1) as f32).sqrt();
    (rms * 8.0).clamp(0.0, 1.0)
}

pub struct Capture {
    stream: Option<cpal::Stream>,
    pub meter: Arc<Meter>,
    pub samples: Arc<Mutex<Vec<f32>>>,
}

impl Capture {
    pub fn new() -> Self {
        Self {
            stream: None,
            meter: Arc::new(Meter::default()),
            samples: Arc::new(Mutex::new(Vec::new())),
        }
    }

    pub fn is_running(&self) -> bool {
        self.stream.is_some()
    }

    /// Opens the default input and starts collecting.
    ///
    /// The samples are kept rather than streamed on, because the recogniser
    /// wants the whole utterance: Parakeet is not a streaming model, so the
    /// live preview re-decodes a growing buffer and the final pass reads all of
    /// it at once.
    pub fn start(&mut self) -> Result<(), String> {
        if self.stream.is_some() {
            return Ok(());
        }
        let host = cpal::default_host();
        let device = host
            .default_input_device()
            .ok_or_else(|| "No microphone is connected.".to_string())?;
        let config = device
            .default_input_config()
            .map_err(|e| format!("That microphone would not open: {e}"))?;

        let meter = self.meter.clone();
        let samples = self.samples.clone();
        samples.lock().clear();
        meter.clear();

        let channels = config.channels() as usize;
        let stream = device
            .build_input_stream(
                &config.into(),
                move |data: &[f32], _: &cpal::InputCallbackInfo| {
                    // Mixed down to mono: speech recognition wants one channel
                    // and it is half the data.
                    let mono: Vec<f32> = if channels <= 1 {
                        data.to_vec()
                    } else {
                        data.chunks(channels)
                            .map(|frame| frame.iter().sum::<f32>() / channels as f32)
                            .collect()
                    };
                    meter.push(level_of(&mono));
                    samples.lock().extend_from_slice(&mono);
                },
                move |error| tracing::error!(%error, "audio input failed"),
                None,
            )
            .map_err(|e| format!("That microphone would not open: {e}"))?;

        stream.play().map_err(|e| e.to_string())?;
        self.stream = Some(stream);
        Ok(())
    }

    pub fn stop(&mut self) -> Vec<f32> {
        self.stream = None;
        let taken = std::mem::take(&mut *self.samples.lock());
        taken
    }
}

impl Default for Capture {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn silence_is_zero() {
        assert_eq!(level_of(&[0.0; 512]), 0.0);
    }

    #[test]
    fn loud_saturates() {
        assert_eq!(level_of(&[1.0; 512]), 1.0);
    }

    #[test]
    fn the_meter_keeps_only_the_recent_past() {
        let meter = Meter::default();
        for _ in 0..(HISTORY_DEPTH * 3) {
            meter.push(0.5);
        }
        assert_eq!(meter.history().len(), HISTORY_DEPTH);
    }
}
