//! Continuous capture for live sessions: the microphone, and what the PC is
//! playing, each its own stream of mono blocks.
//!
//! Dictation's recorder keeps an utterance whole. A session can run for an
//! hour, so here every block is handed on the moment it arrives and nothing
//! piles up. What the PC plays comes from WASAPI's loopback: an output device
//! opened for input returns the mix the speakers are playing, all of it, with
//! no permission asked, because nothing visual is involved.
//!
//! Windows sends no loopback packets at all while nothing is playing, where
//! the Mac's tap sends silence. The gaps are filled with silence here, from
//! the clock, so the PC's timeline stays in step with the microphone's and a
//! line it hears after a pause lands at the right time.
use std::time::Instant;

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{FromSample, SizedSample};
use crossbeam_channel::{bounded, Sender};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Source {
    Microphone,
    /// What the PC is playing: the default output, through loopback.
    System,
}

/// Receives mono blocks at the device's rate, on the audio thread: it must
/// only hand them on.
pub type Sink = Box<dyn FnMut(&[f32], u32) + Send>;

/// An open stream. Dropping it closes the device.
pub struct Stream {
    stop: Option<Sender<()>>,
}

impl Drop for Stream {
    fn drop(&mut self) {
        if let Some(stop) = self.stop.take() {
            let _ = stop.send(());
        }
    }
}

impl Stream {
    /// Opens `source` on a thread of its own (a cpal stream may not leave the
    /// thread that made it) and returns once audio is flowing, or with why not.
    pub fn open(source: Source, sink: Sink) -> Result<Self, String> {
        let (ready, answer) = bounded::<Result<(), String>>(1);
        let (stop, stopped) = bounded::<()>(1);
        std::thread::Builder::new()
            .name(match source {
                Source::Microphone => "huh-session-mic".into(),
                Source::System => "huh-session-pc".into(),
            })
            .spawn(move || match open(source, sink) {
                Ok(stream) => {
                    let _ = ready.send(Ok(()));
                    let _ = stopped.recv();
                    drop(stream);
                }
                Err(message) => {
                    let _ = ready.send(Err(message));
                }
            })
            .map_err(|e| e.to_string())?;
        answer
            .recv()
            .map_err(|_| "The audio thread stopped.".to_string())??;
        Ok(Self { stop: Some(stop) })
    }
}

fn open(source: Source, sink: Sink) -> Result<cpal::Stream, String> {
    let host = cpal::default_host();
    let (device, supported) = match source {
        Source::Microphone => {
            let device = host
                .default_input_device()
                .ok_or_else(|| "No microphone is connected.".to_string())?;
            let config = device
                .default_input_config()
                .map_err(|e| format!("That microphone would not open: {e}"))?;
            (device, config)
        }
        Source::System => {
            let device = host
                .default_output_device()
                .ok_or_else(|| "Nothing is set up to play sound.".to_string())?;
            let config = device
                .default_output_config()
                .map_err(|e| format!("The PC's sound would not open: {e}"))?;
            (device, config)
        }
    };
    let format = supported.sample_format();
    let config: cpal::StreamConfig = supported.into();
    let fill_gaps = source == Source::System;
    let stream = match format {
        cpal::SampleFormat::F32 => build::<f32>(&device, &config, sink, fill_gaps),
        cpal::SampleFormat::I16 => build::<i16>(&device, &config, sink, fill_gaps),
        cpal::SampleFormat::I32 => build::<i32>(&device, &config, sink, fill_gaps),
        cpal::SampleFormat::U16 => build::<u16>(&device, &config, sink, fill_gaps),
        other => {
            return Err(format!(
                "That device sends {other:?} samples, which huh? can't read yet."
            ))
        }
    }
    .map_err(|e| format!("Couldn't start listening: {e}"))?;
    stream
        .play()
        .map_err(|e| format!("Couldn't start listening: {e}"))?;
    Ok(stream)
}

fn build<T>(
    device: &cpal::Device,
    config: &cpal::StreamConfig,
    mut sink: Sink,
    fill_gaps: bool,
) -> Result<cpal::Stream, cpal::BuildStreamError>
where
    T: SizedSample,
    f32: FromSample<T>,
{
    let channels = (config.channels as usize).max(1);
    let rate = config.sample_rate.0;
    let started = Instant::now();
    let mut delivered = 0u64;
    let mut mono: Vec<f32> = Vec::new();
    device.build_input_stream(
        config,
        move |data: &[T], _: &cpal::InputCallbackInfo| {
            if fill_gaps {
                // Whatever the clock says should have arrived and did not
                // was silence.
                let expected = (started.elapsed().as_secs_f64() * rate as f64) as u64;
                let frames = (data.len() / channels) as u64;
                let missing = expected.saturating_sub(delivered + frames);
                if missing > u64::from(rate) / 5 {
                    let silence = vec![0.0f32; missing as usize];
                    sink(&silence, rate);
                    delivered += missing;
                }
            }
            mono.clear();
            mono.extend(data.chunks(channels).map(|frame| {
                frame
                    .iter()
                    .map(|value| value.to_sample::<f32>())
                    .sum::<f32>()
                    / channels as f32
            }));
            delivered += mono.len() as u64;
            sink(&mono, rate);
        },
        move |error| tracing::error!(%error, "session audio failed"),
        None,
    )
}
