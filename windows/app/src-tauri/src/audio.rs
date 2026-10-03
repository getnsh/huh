//! Capture.
//!
//! `cpal` for the microphone, which is WASAPI underneath on Windows and
//! CoreAudio on a Mac, so the development machine can exercise the level meter
//! and the state machine without a PC in the room. Loopback -- what the machine
//! is playing, the "PC" trace beside "You" -- is WASAPI's own and Windows-only.
//!
//! A `cpal::Stream` may not leave the thread that opened it, so the microphone
//! lives on a thread of its own and is opened and closed by message. What it
//! produces -- the samples and the meter -- is shared, and read from anywhere.
use std::f64::consts::PI;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Arc;

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{FromSample, SizedSample};
use crossbeam_channel::{bounded, unbounded, Receiver, Sender};
use parking_lot::Mutex;

/// Normalised RMS level, 0 to 1.
pub type Level = f32;

/// One second of levels, which is what the meter draws. A level is taken for
/// every 1/44 s of audio, whatever size of buffer the driver delivers, so the
/// meter moves at the Mac's speed rather than at the device's.
pub const HISTORY_DEPTH: usize = 44;

/// The rate the recogniser was trained on, and the only one it reads.
pub const SPEECH_RATE: u32 = 16_000;

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

/// What would keep the microphone from being heard, said in a sentence.
///
/// Checked at every press, as the Mac checks `AudioDevices.problem`: a
/// microphone can be muted or blocked between one press and the next, and
/// both look, from inside a stream, like perfect silence. Better to say so at
/// once than after someone has talked for a minute into nothing.
pub fn input_problem() -> Option<String> {
    platform::input_problem()
}

/// One utterance, as the device delivered it: mixed to mono, at its own rate.
///
/// The samples are kept whole rather than streamed on, because the recogniser
/// wants the whole utterance: Parakeet is not a streaming model, so the live
/// preview reads the growing buffer again each time, and the final pass reads
/// all of it at once when the key comes up.
pub struct Recording {
    pub samples: Vec<f32>,
    pub rate: u32,
}

impl Recording {
    fn empty() -> Self {
        Self {
            samples: Vec::new(),
            rate: SPEECH_RATE,
        }
    }

    pub fn seconds(&self) -> f64 {
        if self.rate == 0 {
            return 0.0;
        }
        self.samples.len() as f64 / self.rate as f64
    }

    /// Whether every sample is exactly zero.
    ///
    /// No working microphone is ever that quiet. It is what Windows delivers
    /// from a muted or blocked microphone: the stream opens as though nothing
    /// were wrong and carries silence. Both of those are caught before the
    /// microphone opens; this catches whatever else does the same.
    pub fn is_blank(&self) -> bool {
        self.samples.iter().all(|sample| *sample == 0.0)
    }

    /// The recording at the rate the recogniser reads.
    pub fn for_speech(&self) -> Vec<f32> {
        resample(&self.samples, self.rate, SPEECH_RATE)
    }
}

enum Command {
    Start(Sender<Result<(), String>>),
    Stop(Sender<Recording>),
}

const GONE: &str = "The microphone thread has stopped. Restart huh?.";

/// The microphone, on its own thread.
pub struct Recorder {
    commands: Sender<Command>,
    pub meter: Arc<Meter>,
    /// What the open stream has heard so far, and at what rate. Shared, so the
    /// live preview can read the utterance while the stream goes on writing it.
    heard: Arc<Mutex<Vec<f32>>>,
    rate: Arc<AtomicU32>,
}

impl Recorder {
    pub fn new() -> Self {
        let (commands, inbox) = unbounded();
        let meter = Arc::new(Meter::default());
        let heard: Arc<Mutex<Vec<f32>>> = Arc::default();
        let rate = Arc::new(AtomicU32::new(SPEECH_RATE));
        let shared = (meter.clone(), heard.clone(), rate.clone());
        std::thread::Builder::new()
            .name("huh-microphone".into())
            .spawn(move || run(inbox, shared.0, shared.1, shared.2))
            .expect("could not start the microphone thread");
        Self {
            commands,
            meter,
            heard,
            rate,
        }
    }

    /// The last `seconds` of what has been heard, without stopping.
    ///
    /// For the live preview, which reads the utterance again as it grows. When
    /// the utterance is longer than the window, the window starts at the
    /// quietest moment in its first second, so it opens between two words
    /// rather than inside one.
    pub fn recent(&self, seconds: f64) -> Recording {
        let rate = self.rate.load(Ordering::Relaxed);
        let window = (seconds * rate as f64) as usize;
        let heard = self.heard.lock();
        let start = if heard.len() > window {
            quietest_near(&heard, heard.len() - window, rate)
        } else {
            0
        };
        Recording {
            samples: heard[start..].to_vec(),
            rate,
        }
    }

    /// Opens the default input, and returns once audio is flowing or with the
    /// reason it will not.
    pub fn start(&self) -> Result<(), String> {
        let (reply, answer) = bounded(1);
        self.commands
            .send(Command::Start(reply))
            .map_err(|_| GONE.to_string())?;
        answer.recv().map_err(|_| GONE.to_string())?
    }

    /// Closes the microphone and hands over everything it heard. Harmless when
    /// it was never opened.
    pub fn stop(&self) -> Recording {
        let (reply, answer) = bounded(1);
        if self.commands.send(Command::Stop(reply)).is_err() {
            return Recording::empty();
        }
        answer.recv().unwrap_or_else(|_| Recording::empty())
    }
}

impl Default for Recorder {
    fn default() -> Self {
        Self::new()
    }
}

fn run(
    inbox: Receiver<Command>,
    meter: Arc<Meter>,
    heard: Arc<Mutex<Vec<f32>>>,
    rate: Arc<AtomicU32>,
) {
    let mut open: Option<(cpal::Stream, u32)> = None;
    for command in inbox {
        match command {
            Command::Start(reply) => {
                open = None;
                heard.lock().clear();
                meter.clear();
                let result =
                    open_default(heard.clone(), meter.clone()).map(|(stream, device_rate)| {
                        rate.store(device_rate, Ordering::Relaxed);
                        open = Some((stream, device_rate));
                    });
                let _ = reply.send(result);
            }
            Command::Stop(reply) => {
                // Dropping the stream is what closes the device, and it goes
                // before the samples are taken so nothing arrives after.
                let rate = open.take().map(|(_, rate)| rate).unwrap_or(SPEECH_RATE);
                let taken = std::mem::take(&mut *heard.lock());
                meter.clear();
                let _ = reply.send(Recording {
                    samples: taken,
                    rate,
                });
            }
        }
    }
}

/// Where, in the second of audio after `from`, it is quietest, to the nearest
/// 20 ms.
fn quietest_near(samples: &[f32], from: usize, rate: u32) -> usize {
    let frame = (rate as usize / 50).max(1);
    let end = (from + rate as usize).min(samples.len());
    (from..end.saturating_sub(frame))
        .step_by(frame)
        .map(|start| {
            let energy: f32 = samples[start..start + frame].iter().map(|s| s * s).sum();
            (start, energy)
        })
        .min_by(|a, b| a.1.total_cmp(&b.1))
        .map(|(start, _)| start)
        .unwrap_or(from)
}

fn open_default(
    samples: Arc<Mutex<Vec<f32>>>,
    meter: Arc<Meter>,
) -> Result<(cpal::Stream, u32), String> {
    let host = cpal::default_host();
    let device = host
        .default_input_device()
        .ok_or_else(|| "No microphone is connected.".to_string())?;
    let supported = device
        .default_input_config()
        .map_err(|e| format!("That microphone would not open: {e}"))?;
    let rate = supported.sample_rate().0;
    let format = supported.sample_format();
    let config: cpal::StreamConfig = supported.into();

    // WASAPI's shared mode almost always hands over 32-bit float; the integer
    // formats are for the USB microphones that insist on their own.
    let stream = match format {
        cpal::SampleFormat::F32 => build::<f32>(&device, &config, samples, meter),
        cpal::SampleFormat::I16 => build::<i16>(&device, &config, samples, meter),
        cpal::SampleFormat::I32 => build::<i32>(&device, &config, samples, meter),
        cpal::SampleFormat::U16 => build::<u16>(&device, &config, samples, meter),
        other => {
            return Err(format!(
                "That microphone sends {other:?} samples, which huh? can't read yet."
            ))
        }
    }
    .map_err(|e| format!("That microphone would not open: {e}"))?;

    stream
        .play()
        .map_err(|e| format!("That microphone would not start: {e}"))?;
    Ok((stream, rate))
}

fn build<T>(
    device: &cpal::Device,
    config: &cpal::StreamConfig,
    samples: Arc<Mutex<Vec<f32>>>,
    meter: Arc<Meter>,
) -> Result<cpal::Stream, cpal::BuildStreamError>
where
    T: SizedSample,
    f32: FromSample<T>,
{
    let channels = (config.channels as usize).max(1);
    let block = (config.sample_rate.0 as usize / HISTORY_DEPTH).max(1);
    let mut metered = 0usize;
    device.build_input_stream(
        config,
        move |data: &[T], _: &cpal::InputCallbackInfo| {
            let mut buffer = samples.lock();
            // Mixed down to mono: speech recognition wants one channel and it
            // is half the data.
            buffer.extend(data.chunks(channels).map(|frame| {
                frame
                    .iter()
                    .map(|value| value.to_sample::<f32>())
                    .sum::<f32>()
                    / channels as f32
            }));
            while buffer.len() - metered >= block {
                meter.push(level_of(&buffer[metered..metered + block]));
                metered += block;
            }
        },
        move |error| tracing::error!(%error, "audio input failed"),
        None,
    )
}

#[cfg(windows)]
mod platform {
    use windows::core::{w, PCWSTR};
    use windows::Win32::Media::Audio::Endpoints::IAudioEndpointVolume;
    use windows::Win32::Media::Audio::{
        eCapture, eConsole, IMMDeviceEnumerator, MMDeviceEnumerator,
    };
    use windows::Win32::System::Com::{
        CoCreateInstance, CoInitializeEx, CLSCTX_ALL, COINIT_MULTITHREADED,
    };
    use windows::Win32::System::Registry::{
        RegGetValueW, HKEY, HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE, RRF_RT_REG_SZ,
    };

    pub fn input_problem() -> Option<String> {
        if denied() {
            return Some(
                "Windows is keeping the microphone from desktop apps. Turn it on in \
                 Settings › Privacy & security › Microphone."
                    .into(),
            );
        }
        if muted() {
            return Some(
                "The microphone is muted in Windows. Unmute it in Settings › System › Sound."
                    .into(),
            );
        }
        None
    }

    /// The default input's own mute, which no application can hear past.
    fn muted() -> bool {
        unsafe {
            let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
            let Ok(devices) =
                CoCreateInstance::<_, IMMDeviceEnumerator>(&MMDeviceEnumerator, None, CLSCTX_ALL)
            else {
                return false;
            };
            // No default input at all is said by the stream, when it fails to
            // open, in words of its own.
            let Ok(device) = devices.GetDefaultAudioEndpoint(eCapture, eConsole) else {
                return false;
            };
            let Ok(volume) = device.Activate::<IAudioEndpointVolume>(CLSCTX_ALL, None) else {
                return false;
            };
            volume.GetMute().map(|mute| mute.as_bool()).unwrap_or(false)
        }
    }

    /// The privacy switches: for the machine, for this account, and for
    /// desktop apps as a group. Any one of them set to deny is enough.
    fn denied() -> bool {
        const STORE: PCWSTR = w!(
            "Software\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\microphone"
        );
        const DESKTOP: PCWSTR = w!(
            "Software\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\microphone\\NonPackaged"
        );
        [
            (HKEY_LOCAL_MACHINE, STORE),
            (HKEY_CURRENT_USER, STORE),
            (HKEY_CURRENT_USER, DESKTOP),
        ]
        .into_iter()
        .any(|(root, path)| consent(root, path).as_deref() == Some("Deny"))
    }

    fn consent(root: HKEY, path: PCWSTR) -> Option<String> {
        let mut buffer = [0u16; 16];
        let mut size = std::mem::size_of_val(&buffer) as u32;
        let status = unsafe {
            RegGetValueW(
                root,
                path,
                w!("Value"),
                RRF_RT_REG_SZ,
                None,
                Some(buffer.as_mut_ptr().cast()),
                Some(&mut size),
            )
        };
        if status.is_err() {
            return None;
        }
        let length = buffer
            .iter()
            .position(|unit| *unit == 0)
            .unwrap_or(buffer.len());
        Some(String::from_utf16_lossy(&buffer[..length]))
    }
}

#[cfg(not(windows))]
mod platform {
    pub fn input_problem() -> Option<String> {
        None
    }
}

/// Converts mono audio from `from` Hz to `to` Hz.
///
/// A windowed-sinc low-pass, so that coming down from a microphone's 48 kHz
/// does not fold everything above 8 kHz back into the band the recogniser
/// listens to. The kernel is tabulated at 256 fractional offsets rather than
/// evaluated for every sample, which keeps a minute of speech to a few
/// milliseconds.
pub fn resample(input: &[f32], from: u32, to: u32) -> Vec<f32> {
    if from == to || from == 0 || to == 0 || input.is_empty() {
        return input.to_vec();
    }
    const PHASES: usize = 256;
    const ZERO_CROSSINGS: f64 = 16.0;

    // Input samples per output sample.
    let step = from as f64 / to as f64;
    // Just under the lower of the two Nyquist frequencies, in cycles per input
    // sample. The 5 % margin is the filter's transition band.
    let cutoff = 0.5 * (to as f64 / from as f64).min(1.0) * 0.95;
    let half = ZERO_CROSSINGS / (2.0 * cutoff);
    let reach = half.ceil() as usize;
    let taps = 2 * reach + 1;

    // Row `p` is the kernel for an output that falls `p / PHASES` of the way
    // past an input sample; tap `i` weighs the input `i - reach` from it.
    let mut table = vec![0f32; (PHASES + 1) * taps];
    for (phase, row) in table.chunks_mut(taps).enumerate() {
        let offset = phase as f64 / PHASES as f64;
        let mut weights = vec![0f64; taps];
        for (tap, weight) in weights.iter_mut().enumerate() {
            let distance = tap as f64 - reach as f64 - offset;
            if distance.abs() < half {
                *weight = 2.0 * cutoff * sinc(2.0 * cutoff * distance) * blackman(distance / half);
            }
        }
        // Unity gain at every offset, so a steady level stays steady.
        let total: f64 = weights.iter().sum();
        for (slot, weight) in row.iter_mut().zip(&weights) {
            *slot = (weight / total) as f32;
        }
    }

    let mut padded = vec![0f32; reach];
    padded.extend_from_slice(input);
    padded.resize(padded.len() + reach + 1, 0.0);

    let length = (input.len() as f64 / step).floor() as usize;
    let mut output = Vec::with_capacity(length);
    for index in 0..length {
        let position = index as f64 * step;
        let base = position.floor();
        let phase = ((position - base) * PHASES as f64).round() as usize;
        let start = base as usize;
        let window = &padded[start..start + taps];
        let kernel = &table[phase * taps..(phase + 1) * taps];
        output.push(window.iter().zip(kernel).map(|(x, h)| x * h).sum());
    }
    output
}

fn sinc(x: f64) -> f64 {
    if x == 0.0 {
        1.0
    } else {
        (PI * x).sin() / (PI * x)
    }
}

/// For `x` in -1..1.
fn blackman(x: f64) -> f64 {
    0.42 + 0.5 * (PI * x).cos() + 0.08 * (2.0 * PI * x).cos()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tone(frequency: f64, rate: u32, seconds: f64) -> Vec<f32> {
        (0..(rate as f64 * seconds) as usize)
            .map(|n| (0.5 * (2.0 * PI * frequency * n as f64 / rate as f64).sin()) as f32)
            .collect()
    }

    /// Root mean square over the middle, away from the edges the filter has to
    /// ramp in and out of.
    fn rms(samples: &[f32]) -> f32 {
        let middle = &samples[samples.len() / 4..samples.len() * 3 / 4];
        (middle.iter().map(|s| s * s).sum::<f32>() / middle.len() as f32).sqrt()
    }

    fn crossings(samples: &[f32]) -> usize {
        samples
            .windows(2)
            .filter(|pair| (pair[0] < 0.0) != (pair[1] < 0.0))
            .count()
    }

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

    #[test]
    fn speech_band_survives_the_trip_down_from_48k() {
        let output = resample(&tone(440.0, 48_000, 1.0), 48_000, SPEECH_RATE);
        assert_eq!(output.len(), 16_000);
        // A 0.5 sine has an RMS of 0.354.
        assert!((rms(&output) - 0.354).abs() < 0.01, "rms {}", rms(&output));
        // 440 Hz crosses zero 880 times a second.
        assert!((crossings(&output) as i32 - 880).abs() <= 2);
    }

    #[test]
    fn a_rate_that_does_not_divide_evenly_works_too() {
        let output = resample(&tone(1_000.0, 44_100, 1.0), 44_100, SPEECH_RATE);
        assert_eq!(output.len(), 16_000);
        assert!((rms(&output) - 0.354).abs() < 0.01, "rms {}", rms(&output));
        assert!((crossings(&output) as i32 - 2_000).abs() <= 2);
    }

    #[test]
    fn what_16k_cannot_hold_is_removed_rather_than_folded_back() {
        // 12 kHz is above the new Nyquist frequency of 8 kHz. Decimating
        // without a filter would fold it to 4 kHz at full strength.
        let output = resample(&tone(12_000.0, 48_000, 1.0), 48_000, SPEECH_RATE);
        assert!(rms(&output) < 0.005, "rms {}", rms(&output));
    }

    #[test]
    fn a_matching_rate_is_left_alone() {
        let input = tone(440.0, SPEECH_RATE, 0.1);
        assert_eq!(resample(&input, SPEECH_RATE, SPEECH_RATE), input);
    }

    #[test]
    fn a_preview_window_opens_in_the_pause_between_words() {
        // A second of speech-loud noise with one 20 ms gap at 600 ms.
        let rate = 16_000;
        let mut samples: Vec<f32> = (0..rate * 3)
            .map(|n| if n % 2 == 0 { 0.3 } else { -0.3 })
            .collect();
        let gap = rate as usize + 600 * rate as usize / 1000;
        for sample in &mut samples[gap..gap + rate as usize / 50] {
            *sample = 0.0;
        }
        assert_eq!(quietest_near(&samples, rate as usize, rate), gap);
    }

    #[test]
    fn a_blocked_microphone_is_recognised_by_its_perfect_silence() {
        let blocked = Recording {
            samples: vec![0.0; 48_000],
            rate: 48_000,
        };
        let quiet = Recording {
            samples: vec![0.0001; 48_000],
            rate: 48_000,
        };
        assert!(blocked.is_blank());
        assert!(!quiet.is_blank());
        assert_eq!(blocked.seconds(), 1.0);
    }
}
