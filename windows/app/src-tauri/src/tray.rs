//! The notification-area icon: the Mac's menu bar item, where Windows keeps
//! the same kind of thing.
//!
//! It is how the app is found again once its window is closed, which leaves
//! the app running, so it is created before anything else can hide the window.
//! The menu is the Mac's menu bar menu, line for line: a status line saying
//! what the app is doing, a microphone problem when there is one, dictation,
//! listening to a call, the last transcript, and the way back to the windows.
//!
//! The glyph is drawn rather than loaded: the five bars of the mark, grey at
//! rest and the live colour while the microphone is open, so the one place
//! colour appears is the one moment it means something. Like the Mac's four
//! menu bar symbols it also says when it is working and when it has failed.
use std::sync::OnceLock;

use crossbeam_channel::{unbounded, Sender};
use tauri::image::Image;
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Manager, Wry};

use crate::dictation::State;
use crate::speech::Status;
use crate::{audio, chrome, controller, inject, session, system, Shared};

const ID: &str = "huh";

/// Pixels on a side. Windows asks for 16 at 100 % and scales from 32 cleanly.
const SIZE: u32 = 32;

/// The mark's bars, as fractions of the full height.
const BARS: [f32; 5] = [0.34, 0.66, 1.0, 0.66, 0.34];

/// Theme.live.
const LIVE: [u8; 3] = [0x9E, 0x7B, 0xFF];

/// Theme.danger.
const DANGER: [u8; 3] = [0xE5, 0x53, 0x4B];

pub fn install(app: &AppHandle) -> tauri::Result<()> {
    TrayIconBuilder::with_id(ID)
        .icon(glyph(Look::Idle))
        .tooltip("huh?")
        .menu(&menu(app)?)
        .show_menu_on_left_click(false)
        .on_menu_event(|app, event| {
            let shared = app.state::<Shared>().inner().clone();
            match event.id().as_ref() {
                "toggle" => {
                    let app = app.clone();
                    std::thread::spawn(move || controller::toggle(&app, &shared));
                }
                "listen" => {
                    let app = app.clone();
                    std::thread::spawn(move || session::toggle(&app, &shared));
                }
                "copy" => {
                    if let Some(text) = last_transcript(&shared) {
                        if let Err(error) = inject::copy(&text) {
                            tracing::warn!(%error, "couldn't copy the last transcript");
                        }
                    }
                }
                "check" => {
                    system::recheck_input(app);
                    refresh(app);
                }
                "open" => chrome::reveal(app),
                "settings" => {
                    let app = app.clone();
                    tauri::async_runtime::spawn(async move {
                        if let Err(error) = system::open_settings(app).await {
                            tracing::warn!(%error, "couldn't open Settings");
                        }
                    });
                }
                "quit" => app.exit(0),
                _ => {}
            }
        })
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                ..
            } = event
            {
                chrome::reveal(tray.app_handle());
            }
        })
        .build(app)?;
    Ok(())
}

/// Brings the icon, its tooltip and its menu into line with the app.
///
/// Done on a thread of its own: this is called on the way to opening the
/// microphone, and reading the audio devices for the menu must never stand
/// between a key press and the overlay. Changes that land together make one
/// rebuild.
pub fn refresh(app: &AppHandle) {
    static WAKE: OnceLock<Sender<()>> = OnceLock::new();
    let wake = WAKE.get_or_init(|| {
        let (wake, woken) = unbounded::<()>();
        let app = app.clone();
        let _ = std::thread::Builder::new()
            .name("huh-tray".into())
            .spawn(move || {
                while woken.recv().is_ok() {
                    while woken.try_recv().is_ok() {}
                    rebuild(&app);
                }
            });
        wake
    });
    let _ = wake.send(());
}

/// The menu is built afresh each time rather than edited in place: lines come
/// and go with the state, as they do in the Mac's, and a menu that small costs
/// nothing to build.
fn rebuild(app: &AppHandle) {
    let Some(tray) = app.tray_by_id(ID) else {
        return;
    };
    let Some(shared) = app.try_state::<Shared>() else {
        return;
    };
    let state = shared.dictation.state();
    let _ = tray.set_icon(Some(glyph(look(&state))));
    let _ = tray.set_tooltip(Some(format!("huh? — {}", status_line(&shared, &state))));
    if let Ok(menu) = menu(app) {
        let _ = tray.set_menu(Some(menu));
    }
}

fn menu(app: &AppHandle) -> tauri::Result<Menu<Wry>> {
    let shared = app.state::<Shared>().inner().clone();
    let state = shared.dictation.state();
    let session = shared.session.state();
    let menu = Menu::new(app)?;

    let status = MenuItem::with_id(
        app,
        "status",
        format!("huh? — {}", status_line(&shared, &state)),
        false,
        None::<&str>,
    )?;
    menu.append(&status)?;

    if let Some(problem) = audio::input_problem() {
        menu.append(&PredefinedMenuItem::separator(app)?)?;
        menu.append(&MenuItem::with_id(
            app,
            "problem",
            problem,
            false,
            None::<&str>,
        )?)?;
        menu.append(&MenuItem::with_id(
            app,
            "check",
            "Check Again",
            true,
            None::<&str>,
        )?)?;
    }

    menu.append(&PredefinedMenuItem::separator(app)?)?;
    let busy = !matches!(state, State::Idle | State::Failed { .. });
    menu.append(&MenuItem::with_id(
        app,
        "toggle",
        if busy {
            "Stop Dictation"
        } else {
            "Start Dictation"
        },
        true,
        None::<&str>,
    )?)?;
    // Named after the call when there is one, so the menu says what it is
    // about to start listening to rather than leaving it to be guessed.
    let listen = if session.running {
        "Stop Listening".to_string()
    } else if let Some(call) = &session.call {
        format!("Listen to the {call} Call")
    } else {
        "Listen to This Meeting".to_string()
    };
    menu.append(&MenuItem::with_id(
        app,
        "listen",
        listen,
        !session.stopping,
        None::<&str>,
    )?)?;
    if last_transcript(&shared).is_some() {
        menu.append(&MenuItem::with_id(
            app,
            "copy",
            "Copy Last Transcript",
            true,
            None::<&str>,
        )?)?;
    }

    menu.append(&PredefinedMenuItem::separator(app)?)?;
    menu.append(&MenuItem::with_id(
        app,
        "open",
        "Open huh?",
        true,
        None::<&str>,
    )?)?;
    menu.append(&MenuItem::with_id(
        app,
        "settings",
        "Settings…",
        true,
        None::<&str>,
    )?)?;
    menu.append(&PredefinedMenuItem::separator(app)?)?;
    menu.append(&MenuItem::with_id(
        app,
        "quit",
        "Quit huh?",
        true,
        None::<&str>,
    )?)?;
    Ok(menu)
}

/// The Mac's status line: what a glance at the menu should tell you.
fn status_line(shared: &Shared, state: &State) -> String {
    match state {
        State::Idle => {
            if shared.session.state().running {
                return "in a session".into();
            }
            if audio::default_input_name().is_none() {
                return "no microphone".into();
            }
            match shared.recogniser.status() {
                Status::Ready => {
                    format!("hold {}", shared.settings.read().hotkey.label())
                }
                Status::Downloading { percent, .. } => format!("downloading model… {percent}%"),
                Status::Failed { .. } => "model failed to load".into(),
                Status::Waiting | Status::Loading => "loading model…".into(),
            }
        }
        State::Starting | State::Listening => "listening".into(),
        State::Transcribing => "transcribing".into(),
        State::Failed { .. } => "error".into(),
    }
}

/// The newest dictation, for Copy Last Transcript.
fn last_transcript(shared: &Shared) -> Option<String> {
    let library = shared.library.lock();
    library
        .history
        .iter()
        .find(|t| t.source == huh_core::model::TranscriptSource::Dictation)
        .map(|t| t.text.clone())
        .filter(|text| !text.trim().is_empty())
}

/// The Mac's four menu bar symbols: waveform, waveform.circle.fill,
/// waveform.badge.magnifyingglass and waveform.slash.
#[derive(Clone, Copy)]
enum Look {
    Idle,
    Listening,
    Working,
    Failed,
}

fn look(state: &State) -> Look {
    match state {
        State::Idle => Look::Idle,
        State::Starting | State::Listening => Look::Listening,
        State::Transcribing => Look::Working,
        State::Failed { .. } => Look::Failed,
    }
}

/// The five bars, drawn into a square of RGBA, with a badge or a slash for
/// the states that need one.
fn glyph(look: Look) -> Image<'static> {
    let rest = resting();
    let colour = match look {
        Look::Listening => LIVE,
        _ => rest,
    };
    let mut pixels = vec![0u8; (SIZE * SIZE * 4) as usize];
    let width = 4u32;
    let gap = 2u32;
    let span = BARS.len() as u32 * width + (BARS.len() as u32 - 1) * gap;
    let left = (SIZE - span) / 2;
    let tallest = SIZE - 6;
    for (index, fraction) in BARS.iter().enumerate() {
        let height = ((tallest as f32 * fraction).round() as u32).max(width);
        let x0 = left + index as u32 * (width + gap);
        let y0 = (SIZE - height) / 2;
        for y in y0..y0 + height {
            for x in x0..x0 + width {
                // Rounded ends: the corner pixels of each bar fall away.
                let end = y == y0 || y == y0 + height - 1;
                let edge = x == x0 || x == x0 + width - 1;
                let alpha = if end && edge { 0x60 } else { 0xFF };
                put(&mut pixels, x as i32, y as i32, colour, alpha);
            }
        }
    }
    match look {
        // A dot in the corner, cut out of the bars: the badge of something
        // being worked on.
        Look::Working => badge(&mut pixels, LIVE),
        // A stroke across, cut out of the bars, in the danger colour.
        Look::Failed => slash(&mut pixels, DANGER),
        Look::Idle | Look::Listening => {}
    }
    Image::new_owned(pixels, SIZE, SIZE)
}

fn put(pixels: &mut [u8], x: i32, y: i32, colour: [u8; 3], alpha: u8) {
    if x < 0 || y < 0 || x >= SIZE as i32 || y >= SIZE as i32 {
        return;
    }
    let at = ((y as u32 * SIZE + x as u32) * 4) as usize;
    pixels[at..at + 4].copy_from_slice(&[colour[0], colour[1], colour[2], alpha]);
}

fn clear(pixels: &mut [u8], x: i32, y: i32) {
    if x < 0 || y < 0 || x >= SIZE as i32 || y >= SIZE as i32 {
        return;
    }
    let at = ((y as u32 * SIZE + x as u32) * 4) as usize;
    pixels[at + 3] = 0;
}

fn badge(pixels: &mut [u8], colour: [u8; 3]) {
    let (cx, cy) = (24.5f32, 24.5f32);
    for y in 0..SIZE as i32 {
        for x in 0..SIZE as i32 {
            let d = ((x as f32 + 0.5 - cx).powi(2) + (y as f32 + 0.5 - cy).powi(2)).sqrt();
            if d <= 5.5 {
                put(pixels, x, y, colour, 0xFF);
            } else if d <= 7.5 {
                clear(pixels, x, y);
            }
        }
    }
}

fn slash(pixels: &mut [u8], colour: [u8; 3]) {
    // From the top left to the bottom right, as SF's slash variants run.
    for y in 0..SIZE as i32 {
        for x in 0..SIZE as i32 {
            let distance = ((x - y) as f32).abs() / std::f32::consts::SQRT_2;
            if distance <= 1.6 && (3..SIZE as i32 - 3).contains(&x) {
                put(pixels, x, y, colour, 0xFF);
            } else if distance <= 3.4 {
                clear(pixels, x, y);
            }
        }
    }
}

/// The resting glyph matches the taskbar: light on a dark one, dark on a
/// light one, as the system's own icons are.
fn resting() -> [u8; 3] {
    if platform::light_taskbar() {
        [0x1C, 0x1C, 0x1C]
    } else {
        [0xEC, 0xEC, 0xEC]
    }
}

#[cfg(windows)]
mod platform {
    use windows::core::w;
    use windows::Win32::System::Registry::{RegGetValueW, HKEY_CURRENT_USER, RRF_RT_REG_DWORD};

    pub fn light_taskbar() -> bool {
        let mut value = 0u32;
        let mut size = std::mem::size_of::<u32>() as u32;
        let status = unsafe {
            RegGetValueW(
                HKEY_CURRENT_USER,
                w!("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize"),
                w!("SystemUsesLightTheme"),
                RRF_RT_REG_DWORD,
                None,
                Some(std::ptr::from_mut(&mut value).cast()),
                Some(&mut size),
            )
        };
        status.is_ok() && value == 1
    }
}

#[cfg(not(windows))]
mod platform {
    pub fn light_taskbar() -> bool {
        false
    }
}
