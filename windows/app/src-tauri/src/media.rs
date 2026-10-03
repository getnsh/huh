//! Reading the sound out of a recording: audio or video, any format Windows
//! itself can play.
//!
//! Media Foundation does the decoding -- mp3, m4a and AAC, wav, wma, flac, and
//! the audio track of mp4, mov and wmv -- so nothing is bundled and every codec
//! the machine has is available. It is asked for mono 32-bit float at 16 kHz,
//! which it converts to itself; when a source will not convert, it is asked
//! for float at its own rate and channel count, and the mixing and
//! resampling happen here instead.
//!
//! Audio is handed over in blocks as it is decoded, never held whole: an
//! hour-long meeting at 48 kHz stereo would be well over a gigabyte.
use std::path::Path;

/// Where the decoder is up to, for an honest progress bar.
pub struct Progress {
    /// Seconds of audio decoded so far.
    pub decoded: f64,
    /// The recording's length, when the container says.
    pub total: Option<f64>,
}

/// Decodes `path`, handing over mono blocks at `rate` Hz until it ends or the
/// callback returns false. Returns the sample rate the blocks were in.
pub fn decode(
    path: &Path,
    on_block: &mut dyn FnMut(&[f32], u32, Progress) -> bool,
) -> Result<u32, String> {
    platform::decode(path, on_block)
}

#[cfg(windows)]
mod platform {
    use super::Progress;
    use std::path::Path;
    use windows::core::HSTRING;
    use windows::Win32::Media::MediaFoundation::{
        IMFMediaType, IMFSourceReader, MFAudioFormat_Float, MFCreateMediaType,
        MFCreateSourceReaderFromURL, MFMediaType_Audio, MFShutdown, MFStartup, MFSTARTUP_FULL,
        MF_MT_AUDIO_NUM_CHANNELS, MF_MT_AUDIO_SAMPLES_PER_SECOND, MF_MT_MAJOR_TYPE, MF_MT_SUBTYPE,
        MF_PD_DURATION, MF_SOURCE_READERF_ENDOFSTREAM, MF_SOURCE_READER_ALL_STREAMS,
        MF_SOURCE_READER_FIRST_AUDIO_STREAM, MF_SOURCE_READER_MEDIASOURCE, MF_VERSION,
    };
    use windows::Win32::System::Com::{CoInitializeEx, COINIT_MULTITHREADED};

    const AUDIO: u32 = MF_SOURCE_READER_FIRST_AUDIO_STREAM.0 as u32;

    /// Media Foundation is started and stopped around each decode, on the
    /// thread doing it.
    struct Session;

    impl Session {
        fn start() -> Result<Self, String> {
            unsafe {
                let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
                MFStartup(MF_VERSION, MFSTARTUP_FULL)
                    .map_err(|e| format!("Windows couldn't start its media decoder: {e}"))?;
            }
            Ok(Self)
        }
    }

    impl Drop for Session {
        fn drop(&mut self) {
            unsafe {
                let _ = MFShutdown();
            }
        }
    }

    fn float_type(rate: Option<u32>, channels: Option<u32>) -> windows::core::Result<IMFMediaType> {
        unsafe {
            let kind = MFCreateMediaType()?;
            kind.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Audio)?;
            kind.SetGUID(&MF_MT_SUBTYPE, &MFAudioFormat_Float)?;
            if let Some(rate) = rate {
                kind.SetUINT32(&MF_MT_AUDIO_SAMPLES_PER_SECOND, rate)?;
            }
            if let Some(channels) = channels {
                kind.SetUINT32(&MF_MT_AUDIO_NUM_CHANNELS, channels)?;
            }
            Ok(kind)
        }
    }

    fn duration(reader: &IMFSourceReader) -> Option<f64> {
        unsafe {
            let value = reader
                .GetPresentationAttribute(MF_SOURCE_READER_MEDIASOURCE.0 as u32, &MF_PD_DURATION)
                .ok()?;
            // Hundreds of nanoseconds.
            u64::try_from(&value)
                .ok()
                .map(|ticks| ticks as f64 / 10_000_000.0)
        }
    }

    pub fn decode(
        path: &Path,
        on_block: &mut dyn FnMut(&[f32], u32, Progress) -> bool,
    ) -> Result<u32, String> {
        let _session = Session::start()?;
        let name = path
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default();
        unsafe {
            let url = HSTRING::from(path.as_os_str());
            let reader = MFCreateSourceReaderFromURL(&url, None)
                .map_err(|e| format!("Couldn't read the audio out of that file: {e}"))?;
            reader
                .SetStreamSelection(MF_SOURCE_READER_ALL_STREAMS.0 as u32, false)
                .map_err(|e| e.to_string())?;
            reader
                .SetStreamSelection(AUDIO, true)
                .map_err(|_| "That file has no audio track.".to_string())?;

            // Mono 16 kHz first; if this source won't convert, its own shape.
            let converted = float_type(Some(16_000), Some(1))
                .and_then(|kind| reader.SetCurrentMediaType(AUDIO, None, &kind));
            if converted.is_err() {
                let kind = float_type(None, None).map_err(|e| e.to_string())?;
                reader
                    .SetCurrentMediaType(AUDIO, None, &kind)
                    .map_err(|e| format!("Couldn't read the audio out of {name}: {e}"))?;
            }
            let current = reader
                .GetCurrentMediaType(AUDIO)
                .map_err(|e| e.to_string())?;
            let rate = current
                .GetUINT32(&MF_MT_AUDIO_SAMPLES_PER_SECOND)
                .map_err(|e| e.to_string())?;
            let channels = current
                .GetUINT32(&MF_MT_AUDIO_NUM_CHANNELS)
                .unwrap_or(1)
                .max(1) as usize;
            let total = duration(&reader);

            let mut decoded = 0usize;
            let mut mono: Vec<f32> = Vec::new();
            loop {
                let mut flags = 0u32;
                let mut sample = None;
                reader
                    .ReadSample(AUDIO, 0, None, Some(&mut flags), None, Some(&mut sample))
                    .map_err(|e| format!("Couldn't read the audio out of {name}: {e}"))?;
                if let Some(sample) = sample {
                    let buffer = sample
                        .ConvertToContiguousBuffer()
                        .map_err(|e| e.to_string())?;
                    let mut pointer = std::ptr::null_mut();
                    let mut length = 0u32;
                    buffer
                        .Lock(&mut pointer, None, Some(&mut length))
                        .map_err(|e| e.to_string())?;
                    let floats = std::slice::from_raw_parts(
                        pointer as *const f32,
                        length as usize / std::mem::size_of::<f32>(),
                    );
                    mono.clear();
                    if channels == 1 {
                        mono.extend_from_slice(floats);
                    } else {
                        mono.extend(
                            floats
                                .chunks(channels)
                                .map(|frame| frame.iter().sum::<f32>() / channels as f32),
                        );
                    }
                    let _ = buffer.Unlock();
                    decoded += mono.len();
                    let progress = Progress {
                        decoded: decoded as f64 / rate as f64,
                        total,
                    };
                    if !on_block(&mono, rate, progress) {
                        break;
                    }
                }
                if flags & MF_SOURCE_READERF_ENDOFSTREAM.0 as u32 != 0 {
                    break;
                }
            }
            Ok(rate)
        }
    }
}

#[cfg(not(windows))]
mod platform {
    use super::Progress;
    use std::path::Path;

    pub fn decode(
        _path: &Path,
        _on_block: &mut dyn FnMut(&[f32], u32, Progress) -> bool,
    ) -> Result<u32, String> {
        Err("Transcribing a recording is only implemented on Windows.".into())
    }
}
