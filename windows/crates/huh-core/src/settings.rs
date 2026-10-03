//! Persisted settings, in the same shape the Mac writes them.
//!
//! The Mac keeps these in `UserDefaults`; Windows has no equivalent worth
//! using, so they go in `settings.json` beside the other files. The names match
//! the Mac's keys so the two can be diffed by eye when something behaves
//! differently on one platform.
use serde::{Deserialize, Serialize};

use crate::cleanup::CleanupLevel;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum TriggerMode {
    /// Push-to-talk: transcribe while the key is down.
    #[default]
    Hold,
    /// Tap to start, tap to stop.
    Toggle,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum InjectionMode {
    /// Type it, and paste when it is long.
    #[default]
    Auto,
    AlwaysPaste,
}

/// The push-to-talk key.
///
/// Right Ctrl by default rather than the Mac's Right Option. Right Alt is
/// AltGr on many layouts, and Win and Alt open Start or the menu bar when they
/// are released on their own, which a push-to-talk key does constantly.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum HotKey {
    #[default]
    RightControl,
    LeftControl,
    RightShift,
    RightAlt,
    CapsLock,
}

impl HotKey {
    pub fn label(&self) -> &'static str {
        match self {
            Self::RightControl => "Right Ctrl",
            Self::LeftControl => "Left Ctrl",
            Self::RightShift => "Right Shift",
            Self::RightAlt => "Right Alt",
            Self::CapsLock => "Caps Lock",
        }
    }

    /// Whether releasing this key on its own does something in Windows that
    /// has to be suppressed with a dummy keystroke.
    pub fn needs_release_guard(&self) -> bool {
        matches!(self, Self::RightAlt)
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Settings {
    #[serde(default)]
    pub cleanup_level: CleanupLevel,
    /// Whether holding the key also captures what the PC is playing.
    #[serde(default)]
    pub hears_system_audio: bool,
    #[serde(default)]
    pub hotkey: HotKey,
    #[serde(default)]
    pub injection_mode: InjectionMode,
    #[serde(default = "english")]
    pub locale_identifier: String,
    #[serde(default = "yes")]
    pub play_feedback_sounds: bool,
    #[serde(default)]
    pub start_at_login: bool,
    #[serde(default)]
    pub trigger_mode: TriggerMode,
    /// Whether to notice when a call starts.
    #[serde(default = "yes")]
    pub watches_for_meetings: bool,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            cleanup_level: CleanupLevel::default(),
            hears_system_audio: false,
            hotkey: HotKey::default(),
            injection_mode: InjectionMode::default(),
            locale_identifier: english(),
            play_feedback_sounds: true,
            start_at_login: false,
            trigger_mode: TriggerMode::default(),
            watches_for_meetings: true,
        }
    }
}

fn english() -> String {
    "en_US".into()
}

fn yes() -> bool {
    true
}
