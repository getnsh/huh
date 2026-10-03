//! huh? setup.
//!
//! One window, drawn by the WebView2 runtime every copy of huh? already
//! needs, over the plain work in `install`: the page asks, this side does,
//! and progress goes back to the page as it happens.
//!
//! The same program is the uninstaller. Installing copies it beside the app
//! as `uninstall.exe`, and Windows starts it from Installed apps with
//! `--uninstall`; named that way, it starts there without the argument too.
//! `--silent` (or `/S`) does the work without a window, for package managers.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod install;

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use serde::{Deserialize, Serialize};
use tao::dpi::LogicalSize;
use tao::event::{Event, WindowEvent};
use tao::event_loop::{ControlFlow, EventLoopBuilder, EventLoopProxy};
use tao::window::{Icon, WindowBuilder};
use wry::{WebContext, WebViewBuilder};

use install::{InstallChoices, Places, RemoveChoices, Report};

/// `ui/index.html` with the app's fonts written in by the build.
const PAGE: &str = include_str!(concat!(env!("OUT_DIR"), "/index.html"));
static ICON: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/icon.rgba"));
const ICON_SIZE: u32 = install::parse(env!("HUH_ICON_SIZE")) as u32;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
enum Mode {
    Install,
    Remove,
}

enum UserEvent {
    Script(String),
    Show,
    Drag,
    Minimize,
    Close,
}

/// What the page can ask for.
#[derive(Deserialize)]
#[serde(tag = "cmd", rename_all = "camelCase")]
enum Command {
    /// The plate has settled and the first frame is up.
    Ready,
    Install {
        desktop: bool,
    },
    Remove {
        data: bool,
        models: bool,
    },
    Open,
    Drag,
    Minimize,
    Close,
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let flag = |names: &[&str]| {
        args.iter()
            .any(|a| names.iter().any(|n| a.eq_ignore_ascii_case(n)))
    };
    let named_uninstall = std::env::current_exe()
        .ok()
        .and_then(|path| {
            path.file_stem()
                .map(|stem| stem.to_string_lossy().to_lowercase())
        })
        .is_some_and(|stem| stem.starts_with("uninstall"));
    let mode = if flag(&["--uninstall", "/uninstall"]) || named_uninstall {
        Mode::Remove
    } else {
        Mode::Install
    };
    let places = Places::find();

    if flag(&["--silent", "/s", "/silent", "/verysilent", "--quiet"]) {
        std::process::exit(silently(mode, &places, flag(&["--desktop-shortcut"])));
    }
    windowed(mode, places);
}

/// Without a window: exit code 0 when it worked, 1 with the reason in
/// `%TEMP%\huh-setup.log` when it didn't.
fn silently(mode: Mode, places: &Places, desktop: bool) -> i32 {
    struct Quiet;
    impl Report for Quiet {
        fn step(&mut self, _fraction: f64, _label: &str) {}
    }
    let result = match mode {
        Mode::Install => install::install(places, InstallChoices { desktop }, &mut Quiet),
        Mode::Remove => {
            let result = install::remove(
                places,
                RemoveChoices {
                    data: false,
                    models: false,
                },
                &mut Quiet,
            );
            if result.is_ok() {
                install::tidy_after_exit(places);
            }
            result
        }
    };
    match result {
        Ok(()) => 0,
        Err(reason) => {
            let _ = std::fs::write(std::env::temp_dir().join("huh-setup.log"), reason);
            1
        }
    }
}

/// What the page is told before it draws anything.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Boot {
    mode: Mode,
    #[serde(flatten)]
    situation: install::Situation,
}

fn windowed(mode: Mode, places: Places) {
    let event_loop = EventLoopBuilder::<UserEvent>::with_user_event().build();
    let proxy = event_loop.create_proxy();

    let icon = Icon::from_rgba(ICON.to_vec(), ICON_SIZE, ICON_SIZE).ok();
    let builder = WindowBuilder::new()
        .with_title(match mode {
            Mode::Install => "huh? setup",
            Mode::Remove => "Uninstall huh?",
        })
        .with_inner_size(LogicalSize::new(840.0, 520.0))
        .with_resizable(false)
        .with_maximizable(false)
        .with_decorations(false)
        .with_visible(false)
        .with_window_icon(icon);
    #[cfg(windows)]
    let builder = {
        use tao::platform::windows::WindowBuilderExtWindows;
        builder.with_undecorated_shadow(true)
    };
    let window = builder
        .build(&event_loop)
        .expect("opening the setup window");
    center(&window);
    #[cfg(windows)]
    chrome::round(&window);

    let boot = Boot {
        mode,
        situation: install::situation(&places),
    };
    let script = format!(
        "window.SETUP = {};",
        serde_json::to_string(&boot).unwrap_or_else(|_| "{}".into())
    );

    let busy = Arc::new(AtomicBool::new(false));
    let removed = Arc::new(AtomicBool::new(false));
    let handler = {
        let proxy = proxy.clone();
        let places = places.clone();
        let busy = busy.clone();
        let removed = removed.clone();
        move |request: wry::http::Request<String>| {
            let Ok(command) = serde_json::from_str::<Command>(request.body()) else {
                return;
            };
            handle(command, &proxy, &places, &busy, &removed);
        }
    };

    // The runtime's own files go to the temporary folder, not beside the
    // program: beside it would be the Downloads folder, or the app's folder
    // the uninstaller is trying to empty.
    let mut context = WebContext::new(Some(std::env::temp_dir().join("huh-setup")));
    let builder = WebViewBuilder::new_with_web_context(&mut context)
        .with_html(PAGE)
        .with_initialization_script(script)
        .with_background_color((10, 10, 10, 255))
        .with_devtools(cfg!(debug_assertions))
        .with_hotkeys_zoom(false)
        .with_ipc_handler(handler);
    #[cfg(windows)]
    let builder = {
        use wry::WebViewBuilderExtWindows;
        builder
            .with_default_context_menus(false)
            .with_browser_accelerator_keys(false)
    };
    let webview = match builder.build(&window) {
        Ok(webview) => webview,
        Err(error) => {
            #[cfg(windows)]
            chrome::no_runtime(&error.to_string());
            #[cfg(not(windows))]
            eprintln!("{error}");
            std::process::exit(1);
        }
    };

    // Shown when the page says its first frame is up, so the window never
    // opens on an empty plate; and shown regardless after a moment, in case
    // the page never says.
    {
        let proxy = proxy.clone();
        std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_millis(2500));
            let _ = proxy.send_event(UserEvent::Show);
        });
    }

    let mut shown = false;
    event_loop.run(move |event, _, control_flow| {
        *control_flow = ControlFlow::Wait;
        match event {
            Event::UserEvent(UserEvent::Script(js)) => {
                let _ = webview.evaluate_script(&js);
            }
            Event::UserEvent(UserEvent::Show) if !shown => {
                shown = true;
                window.set_visible(true);
                window.set_focus();
            }
            Event::UserEvent(UserEvent::Drag) => {
                let _ = window.drag_window();
            }
            Event::UserEvent(UserEvent::Minimize) => window.set_minimized(true),
            Event::UserEvent(UserEvent::Close)
            | Event::WindowEvent {
                event: WindowEvent::CloseRequested,
                ..
            } => {
                // Not halfway through writing the app.
                if busy.load(Ordering::SeqCst) {
                    return;
                }
                if removed.load(Ordering::SeqCst) {
                    install::tidy_after_exit(&places);
                }
                *control_flow = ControlFlow::Exit;
            }
            _ => {}
        }
    });
}

fn handle(
    command: Command,
    proxy: &EventLoopProxy<UserEvent>,
    places: &Places,
    busy: &Arc<AtomicBool>,
    removed: &Arc<AtomicBool>,
) {
    match command {
        Command::Ready => {
            let _ = proxy.send_event(UserEvent::Show);
        }
        Command::Drag => {
            let _ = proxy.send_event(UserEvent::Drag);
        }
        Command::Minimize => {
            let _ = proxy.send_event(UserEvent::Minimize);
        }
        Command::Close => {
            let _ = proxy.send_event(UserEvent::Close);
        }
        Command::Open => match install::open(places) {
            Ok(()) => {
                let _ = proxy.send_event(UserEvent::Close);
            }
            Err(reason) => tell(proxy, "window.setupNotice", Some(&reason)),
        },
        Command::Install { desktop } => {
            if busy.swap(true, Ordering::SeqCst) {
                return;
            }
            let (proxy, places, busy) = (proxy.clone(), places.clone(), busy.clone());
            std::thread::spawn(move || {
                let mut page = PageReport::new(proxy.clone());
                let result = install::install(&places, InstallChoices { desktop }, &mut page);
                busy.store(false, Ordering::SeqCst);
                tell(&proxy, "window.setupFinished", result.err().as_deref());
            });
        }
        Command::Remove { data, models } => {
            if busy.swap(true, Ordering::SeqCst) {
                return;
            }
            let (proxy, places, busy, removed) =
                (proxy.clone(), places.clone(), busy.clone(), removed.clone());
            std::thread::spawn(move || {
                let mut page = PageReport::new(proxy.clone());
                let result = install::remove(&places, RemoveChoices { data, models }, &mut page);
                removed.store(result.is_ok(), Ordering::SeqCst);
                busy.store(false, Ordering::SeqCst);
                tell(&proxy, "window.setupFinished", result.err().as_deref());
            });
        }
    }
}

/// Calls a function on the page with one string argument, or `null`.
fn tell(proxy: &EventLoopProxy<UserEvent>, function: &str, text: Option<&str>) {
    let argument = text.map_or_else(
        || "null".into(),
        |t| serde_json::to_string(t).unwrap_or_default(),
    );
    let _ = proxy.send_event(UserEvent::Script(format!("{function}({argument})")));
}

/// Progress, sent to the page at most once per percent.
struct PageReport {
    proxy: EventLoopProxy<UserEvent>,
    fraction: f64,
    label: String,
}

impl PageReport {
    fn new(proxy: EventLoopProxy<UserEvent>) -> Self {
        Self {
            proxy,
            fraction: -1.0,
            label: String::new(),
        }
    }
}

impl Report for PageReport {
    fn step(&mut self, fraction: f64, label: &str) {
        if fraction - self.fraction < 0.01 && label == self.label {
            return;
        }
        self.fraction = fraction;
        self.label = label.into();
        let label = serde_json::to_string(label).unwrap_or_default();
        let _ = self.proxy.send_event(UserEvent::Script(format!(
            "window.setupProgress({fraction:.4},{label})"
        )));
    }
}

fn center(window: &tao::window::Window) {
    if let Some(monitor) = window.current_monitor() {
        let screen = monitor.size();
        let size = window.outer_size();
        let origin = monitor.position();
        window.set_outer_position(tao::dpi::PhysicalPosition::new(
            origin.x + (screen.width as i32 - size.width as i32) / 2,
            origin.y + (screen.height as i32 - size.height as i32) / 2,
        ));
    }
}

#[cfg(windows)]
mod chrome {
    use tao::platform::windows::WindowExtWindows;
    use windows::core::HSTRING;
    use windows::Win32::Foundation::{COLORREF, HWND};
    use windows::Win32::Graphics::Dwm::{
        DwmSetWindowAttribute, DWMWA_BORDER_COLOR, DWMWA_WINDOW_CORNER_PREFERENCE, DWMWCP_ROUND,
        DWM_WINDOW_CORNER_PREFERENCE,
    };
    use windows::Win32::UI::Shell::ShellExecuteW;
    use windows::Win32::UI::WindowsAndMessaging::{
        MessageBoxW, IDYES, MB_ICONINFORMATION, MB_YESNO, SW_SHOWNORMAL,
    };

    /// Windows 11's own rounded corners and a hairline in the border grey,
    /// as the app's windows have.
    pub fn round(window: &tao::window::Window) {
        let hwnd = HWND(window.hwnd() as *mut _);
        unsafe {
            let corner = DWMWCP_ROUND;
            let _ = DwmSetWindowAttribute(
                hwnd,
                DWMWA_WINDOW_CORNER_PREFERENCE,
                (&corner as *const DWM_WINDOW_CORNER_PREFERENCE).cast(),
                std::mem::size_of_val(&corner) as u32,
            );
            let colour = COLORREF(0x0026_2626);
            let _ = DwmSetWindowAttribute(
                hwnd,
                DWMWA_BORDER_COLOR,
                (&colour as *const COLORREF).cast(),
                std::mem::size_of::<COLORREF>() as u32,
            );
        }
    }

    /// Without the WebView2 runtime there is no page to draw, and no app to
    /// run either: say so, and offer Microsoft's download.
    pub fn no_runtime(detail: &str) {
        let text = format!(
            "huh? needs the Microsoft Edge WebView2 Runtime, and this PC doesn't have it.\n\n\
             Open Microsoft's download page? Install the runtime, then run this setup again.\n\n({detail})"
        );
        unsafe {
            let answer = MessageBoxW(
                None,
                &HSTRING::from(text),
                &HSTRING::from("huh? setup"),
                MB_YESNO | MB_ICONINFORMATION,
            );
            if answer == IDYES {
                ShellExecuteW(
                    None,
                    &HSTRING::from("open"),
                    &HSTRING::from("https://developer.microsoft.com/microsoft-edge/webview2/"),
                    None,
                    None,
                    SW_SHOWNORMAL,
                );
            }
        }
    }
}
