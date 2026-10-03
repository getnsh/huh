//! The two feedback sounds.
//!
//! The Mac plays the system's Tink as the microphone opens and Pop as the
//! words land, when "Feedback sounds" is on. Windows has no such pair, and its
//! own notification sounds are long and loud for something heard at every
//! press, so two short ones are made here instead, once, in memory: a bright
//! tick for the start and a soft, falling pop for the end.
use std::sync::OnceLock;

#[derive(Debug, Clone, Copy)]
pub enum Chime {
    Start,
    Stop,
}

pub fn play(chime: Chime) {
    static TINK: OnceLock<Vec<u8>> = OnceLock::new();
    static POP: OnceLock<Vec<u8>> = OnceLock::new();
    let sound = match chime {
        Chime::Start => TINK.get_or_init(tink),
        Chime::Stop => POP.get_or_init(pop),
    };
    platform::play(sound);
}

const RATE: u32 = 44_100;

/// A short metallic tick: two inharmonic partials, struck and gone.
fn tink() -> Vec<u8> {
    synthesise(0.12, |t| {
        let envelope = attack(t, 0.002) * (-t / 0.022).exp();
        let tone = (std::f32::consts::TAU * 2_093.0 * t).sin() * 0.7
            + (std::f32::consts::TAU * 3_136.0 * t).sin() * 0.3;
        tone * envelope * 0.2
    })
}

/// A soft pop that falls in pitch as it fades.
fn pop() -> Vec<u8> {
    synthesise(0.12, |t| {
        let envelope = attack(t, 0.003) * (-t / 0.03).exp();
        // The phase of a sweep from 560 Hz down toward 300 Hz.
        let phase =
            std::f32::consts::TAU * (300.0 * t + 260.0 * 0.025 * (1.0 - (-t / 0.025).exp()));
        phase.sin() * envelope * 0.28
    })
}

fn attack(t: f32, length: f32) -> f32 {
    (t / length).min(1.0)
}

/// A mono 16-bit WAV image of `seconds` of `wave`.
fn synthesise(seconds: f32, wave: impl Fn(f32) -> f32) -> Vec<u8> {
    let frames = (seconds * RATE as f32) as u32;
    let data = frames * 2;
    let mut out = Vec::with_capacity(44 + data as usize);
    out.extend_from_slice(b"RIFF");
    out.extend_from_slice(&(36 + data).to_le_bytes());
    out.extend_from_slice(b"WAVEfmt ");
    out.extend_from_slice(&16u32.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes()); // PCM
    out.extend_from_slice(&1u16.to_le_bytes()); // mono
    out.extend_from_slice(&RATE.to_le_bytes());
    out.extend_from_slice(&(RATE * 2).to_le_bytes());
    out.extend_from_slice(&2u16.to_le_bytes());
    out.extend_from_slice(&16u16.to_le_bytes());
    out.extend_from_slice(b"data");
    out.extend_from_slice(&data.to_le_bytes());
    for frame in 0..frames {
        let t = frame as f32 / RATE as f32;
        let sample = (wave(t).clamp(-1.0, 1.0) * i16::MAX as f32) as i16;
        out.extend_from_slice(&sample.to_le_bytes());
    }
    out
}

#[cfg(windows)]
mod platform {
    use windows::core::PCWSTR;
    use windows::Win32::Foundation::HMODULE;
    use windows::Win32::Media::Audio::{PlaySoundW, SND_ASYNC, SND_MEMORY, SND_NODEFAULT};

    /// Plays without waiting. The image is static, so it outlives the sound.
    pub fn play(sound: &'static [u8]) {
        unsafe {
            let _ = PlaySoundW(
                PCWSTR(sound.as_ptr().cast()),
                HMODULE::default(),
                SND_MEMORY | SND_ASYNC | SND_NODEFAULT,
            );
        }
    }
}

#[cfg(not(windows))]
mod platform {
    pub fn play(_sound: &'static [u8]) {}
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_sounds_are_short_wav_images_that_never_clip() {
        for sound in [tink(), pop()] {
            assert_eq!(&sound[..4], b"RIFF");
            assert_eq!(&sound[8..12], b"WAVE");
            let samples: Vec<i16> = sound[44..]
                .chunks(2)
                .map(|pair| i16::from_le_bytes([pair[0], pair[1]]))
                .collect();
            let seconds = samples.len() as f32 / RATE as f32;
            assert!(seconds < 0.2, "{seconds} s is too long for a chime");
            let peak = samples.iter().map(|s| s.unsigned_abs()).max().unwrap();
            assert!(peak > 2_000 && peak < 16_000, "peak {peak}");
            // Ends in silence, so it doesn't click off.
            assert!(samples.last().unwrap().unsigned_abs() < 200);
        }
    }
}
