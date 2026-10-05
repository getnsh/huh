//! Runs a WAV file through the path an utterance takes after the key comes up
//! -- the model download if it is missing, resampling to 16 kHz, recognition --
//! and prints what comes back, with how long each step took.
//!
//! ```text
//! cargo run -p huh --release --example transcribe -- path\to\speech.wav
//! ```
//!
//! For checking the recogniser on a machine with no microphone, or with no
//! one to talk into it.
use std::time::Instant;

use huh_lib::audio;
use huh_lib::speech::{self, Recogniser, Status};

fn main() {
    tracing_subscriber::fmt()
        .with_env_filter("huh_lib=info")
        .init();

    let Some(path) = std::env::args().nth(1) else {
        eprintln!("usage: transcribe <file.wav>");
        std::process::exit(2);
    };

    let mut reader = hound::WavReader::open(&path).unwrap_or_else(|e| {
        eprintln!("could not open {path}: {e}");
        std::process::exit(1);
    });
    let spec = reader.spec();
    let interleaved: Vec<f32> = match spec.sample_format {
        hound::SampleFormat::Float => reader.samples::<f32>().map(Result::unwrap).collect(),
        hound::SampleFormat::Int => {
            let scale = (1i64 << (spec.bits_per_sample - 1)) as f32;
            reader
                .samples::<i32>()
                .map(|sample| sample.unwrap() as f32 / scale)
                .collect()
        }
    };
    let channels = spec.channels.max(1) as usize;
    let mono: Vec<f32> = interleaved
        .chunks(channels)
        .map(|frame| frame.iter().sum::<f32>() / channels as f32)
        .collect();
    println!(
        "{path}: {:.2} s at {} Hz, {} channel(s)",
        mono.len() as f64 / spec.sample_rate as f64,
        spec.sample_rate,
        channels
    );
    println!("model folder: {}", speech::directory().display());

    let started = Instant::now();
    let samples = audio::resample(&mono, spec.sample_rate, audio::SPEECH_RATE);
    println!("resampled in {:.1?}", started.elapsed());

    let recogniser = Recogniser::new();
    recogniser.prepare(|status| match status {
        Status::Downloading { percent, .. } => println!("downloading… {percent}%"),
        other => println!("{other:?}"),
    });

    // Twice: the first waits for the model to load, the second is what every
    // utterance after launch costs.
    for pass in ["first (includes loading)", "second"] {
        let started = Instant::now();
        match recogniser.transcribe(samples.clone()) {
            Ok(text) => {
                println!("{pass}: {:.2?}", started.elapsed());
                println!("  {text}");
            }
            Err(message) => {
                eprintln!("{message}");
                std::process::exit(1);
            }
        }
    }
}
