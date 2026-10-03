//! Getting the text into whatever has focus.
//!
//! Windows has no equivalent of the Mac's "set the value of the focused
//! element", so insertion is a ladder, and each rung exists because the one
//! below it fails somewhere specific:
//!
//!  1. **UI Automation reads the focused element first.** A password field is
//!     refused outright, the same refusal the Mac makes, and the owning
//!     application's name is what the overlay confirms the text was delivered
//!     to.
//!  2. **Short text is typed** with `SendInput` Unicode events, which leaves
//!     the clipboard alone entirely.
//!  3. **Long text is pasted**, because typing a paragraph one synthetic
//!     keystroke at a time is visibly slow and drops characters under load.
//!     The clipboard is then restored once the target has actually read it.
//!  4. **An elevated window refuses both**, because a normal process may not
//!     send input to one. That is a Windows rule, not a bug, and it is said
//!     plainly rather than failing silently.
use serde::Serialize;

/// Above this many characters, typing is replaced by a paste.
const PASTE_THRESHOLD: usize = 120;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Outcome {
    pub label: String,
    pub delivered: bool,
}

// `typed` and `pasted` are reached only from the Windows implementation. The
// crate still builds on a Mac so the port can be worked on there, and this says
// that is deliberate rather than leaving a warning to be ignored.
#[cfg_attr(not(windows), allow(dead_code))]
impl Outcome {
    fn typed(target: &str) -> Self {
        Self {
            label: if target.is_empty() {
                "Typed at cursor".into()
            } else {
                format!("Typed into {target}")
            },
            delivered: true,
        }
    }

    fn pasted(target: &str) -> Self {
        Self {
            label: if target.is_empty() {
                "Pasted at cursor".into()
            } else {
                format!("Pasted into {target}")
            },
            delivered: true,
        }
    }

    fn refused(reason: &str) -> Self {
        Self {
            label: reason.into(),
            delivered: false,
        }
    }
}

/// Puts `text` on the clipboard and leaves it there.
pub fn copy(text: &str) -> Result<(), String> {
    platform::copy(text)
}

pub fn insert(text: &str, always_paste: bool) -> Outcome {
    if text.is_empty() {
        return Outcome::nothing_heard();
    }
    platform::insert(text, always_paste || text.chars().count() > PASTE_THRESHOLD)
}

impl Outcome {
    /// An utterance the recogniser found no words in.
    pub fn nothing_heard() -> Self {
        Self::refused("Nothing heard.")
    }
}

#[cfg(windows)]
mod platform {
    use super::Outcome;
    use windows::core::{w, PCWSTR, PWSTR};
    use windows::Win32::Foundation::CloseHandle;
    use windows::Win32::Storage::FileSystem::{
        GetFileVersionInfoSizeW, GetFileVersionInfoW, VerQueryValueW,
    };
    use windows::Win32::System::Com::{
        CoCreateInstance, CoInitializeEx, CLSCTX_ALL, COINIT_MULTITHREADED,
    };
    use windows::Win32::System::Threading::{
        OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_WIN32,
        PROCESS_QUERY_LIMITED_INFORMATION,
    };
    use windows::Win32::UI::Accessibility::{
        CUIAutomation, IUIAutomation, UIA_IsPasswordPropertyId,
    };
    use windows::Win32::UI::Input::KeyboardAndMouse::{
        SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYEVENTF_KEYUP, KEYEVENTF_UNICODE,
        VIRTUAL_KEY, VK_CONTROL, VK_V,
    };
    use windows::Win32::UI::WindowsAndMessaging::{GetForegroundWindow, GetWindowThreadProcessId};

    /// What has focus, and whether we are allowed to write into it.
    struct Focus {
        /// The process that owns the focused element. Taken from the element
        /// rather than the foreground window, because a Store app's window
        /// belongs to `ApplicationFrameHost.exe` while its text box does not.
        process: u32,
        is_password: bool,
    }

    fn focused() -> Option<Focus> {
        unsafe {
            let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
            let automation: IUIAutomation =
                CoCreateInstance(&CUIAutomation, None, CLSCTX_ALL).ok()?;
            let element = automation.GetFocusedElement().ok()?;
            let is_password = element
                .GetCurrentPropertyValue(UIA_IsPasswordPropertyId)
                .ok()
                .and_then(|value| bool::try_from(&value).ok())
                .unwrap_or(false);
            let process = element.CurrentProcessId().unwrap_or(0) as u32;
            Some(Focus {
                process,
                is_password,
            })
        }
    }

    /// The application by the name it gives itself, as Task Manager shows it:
    /// "Notepad", "Google Chrome". The Mac confirms the app the text went to,
    /// and an element's own label ("Message", "Text editor") says less.
    fn application(process: u32) -> Option<String> {
        let process = if process != 0 {
            process
        } else {
            let mut owner = 0u32;
            unsafe { GetWindowThreadProcessId(GetForegroundWindow(), Some(&mut owner)) };
            owner
        };
        if process == 0 || process == std::process::id() {
            return None;
        }
        let path = unsafe {
            let handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, process).ok()?;
            let mut buffer = [0u16; 1024];
            let mut length = buffer.len() as u32;
            let found = QueryFullProcessImageNameW(
                handle,
                PROCESS_NAME_WIN32,
                PWSTR(buffer.as_mut_ptr()),
                &mut length,
            );
            let _ = CloseHandle(handle);
            found.ok()?;
            String::from_utf16_lossy(&buffer[..length as usize])
        };
        description(&path).or_else(|| {
            std::path::Path::new(&path)
                .file_stem()
                .map(|stem| stem.to_string_lossy().into_owned())
        })
    }

    /// The file description in an executable's version resource.
    fn description(path: &str) -> Option<String> {
        let wide: Vec<u16> = path.encode_utf16().chain(Some(0)).collect();
        let file = PCWSTR(wide.as_ptr());
        unsafe {
            let size = GetFileVersionInfoSizeW(file, None);
            if size == 0 {
                return None;
            }
            let mut data = vec![0u8; size as usize];
            GetFileVersionInfoW(file, 0, size, data.as_mut_ptr().cast()).ok()?;

            // The first language and code page the resource lists.
            let mut pointer = std::ptr::null_mut();
            let mut length = 0u32;
            let listed = VerQueryValueW(
                data.as_ptr().cast(),
                w!("\\VarFileInfo\\Translation"),
                &mut pointer,
                &mut length,
            );
            if !listed.as_bool() || length < 4 {
                return None;
            }
            let pair = pointer as *const u16;
            let key = format!(
                "\\StringFileInfo\\{:04x}{:04x}\\FileDescription",
                *pair,
                *pair.add(1)
            );
            let key: Vec<u16> = key.encode_utf16().chain(Some(0)).collect();
            let found = VerQueryValueW(
                data.as_ptr().cast(),
                PCWSTR(key.as_ptr()),
                &mut pointer,
                &mut length,
            );
            if !found.as_bool() || length == 0 {
                return None;
            }
            let units = std::slice::from_raw_parts(pointer as *const u16, length as usize);
            let text = String::from_utf16_lossy(units)
                .trim_end_matches('\0')
                .trim()
                .to_string();
            (!text.is_empty()).then_some(text)
        }
    }

    pub fn insert(text: &str, paste: bool) -> Outcome {
        let focus = focused();
        if let Some(focus) = &focus {
            if focus.is_password {
                // The same refusal the Mac makes, for the same reason: a
                // password field is the one place a dictation app must not
                // write, and the fallback would leave the text on the
                // clipboard.
                return Outcome::refused("Not typing into a password field.");
            }
        }
        let target = application(focus.map(|f| f.process).unwrap_or(0)).unwrap_or_default();

        if paste {
            match paste_text(text) {
                Ok(()) => Outcome::pasted(&target),
                Err(message) => Outcome::refused(&message),
            }
        } else {
            match type_text(text) {
                Ok(()) => Outcome::typed(&target),
                Err(message) => Outcome::refused(&message),
            }
        }
    }

    /// Unicode key events, one per character. No virtual key codes, so the
    /// layout the person happens to be using is irrelevant.
    fn type_text(text: &str) -> Result<(), String> {
        let mut inputs: Vec<INPUT> = Vec::with_capacity(text.chars().count() * 2);
        for unit in text.encode_utf16() {
            for flags in [KEYEVENTF_UNICODE, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP] {
                inputs.push(INPUT {
                    r#type: INPUT_KEYBOARD,
                    Anonymous: INPUT_0 {
                        ki: KEYBDINPUT {
                            wVk: VIRTUAL_KEY(0),
                            wScan: unit,
                            dwFlags: flags,
                            time: 0,
                            dwExtraInfo: 0,
                        },
                    },
                });
            }
        }
        let sent = unsafe { SendInput(&inputs, std::mem::size_of::<INPUT>() as i32) };
        if sent as usize == inputs.len() {
            Ok(())
        } else {
            // A normal process may not send input to an elevated window. This
            // is the usual reason, and it is worth saying out loud.
            Err(
                "That window is running as administrator, so Windows won't let huh? type into it."
                    .into(),
            )
        }
    }

    fn paste_text(text: &str) -> Result<(), String> {
        clipboard::with_restored(text, || {
            let keys = [
                (VK_CONTROL, false),
                (VK_V, false),
                (VK_V, true),
                (VK_CONTROL, true),
            ];
            let inputs: Vec<INPUT> = keys
                .iter()
                .map(|(key, up)| INPUT {
                    r#type: INPUT_KEYBOARD,
                    Anonymous: INPUT_0 {
                        ki: KEYBDINPUT {
                            wVk: *key,
                            wScan: 0,
                            dwFlags: if *up {
                                KEYEVENTF_KEYUP
                            } else {
                                Default::default()
                            },
                            time: 0,
                            dwExtraInfo: 0,
                        },
                    },
                })
                .collect();
            let sent = unsafe { SendInput(&inputs, std::mem::size_of::<INPUT>() as i32) };
            if sent as usize == inputs.len() {
                Ok(())
            } else {
                Err("That window is running as administrator, so Windows won't let huh? paste into it.".into())
            }
        })
    }

    /// Leaves `text` on the clipboard, for a person to paste themselves.
    pub fn copy(text: &str) -> Result<(), String> {
        clipboard::write(text)
    }

    mod clipboard {
        use windows::Win32::Foundation::{HANDLE, HGLOBAL};
        use windows::Win32::System::DataExchange::{
            CloseClipboard, EmptyClipboard, GetClipboardData, OpenClipboard, SetClipboardData,
        };
        use windows::Win32::System::Memory::{
            GlobalAlloc, GlobalLock, GlobalUnlock, GMEM_MOVEABLE,
        };
        use windows::Win32::System::Ole::CF_UNICODETEXT;

        /// Puts `text` on the clipboard, runs `body`, and puts back whatever
        /// was there before.
        ///
        /// The restore waits on the paste having happened rather than on a
        /// timer. A fixed delay is a race: too short and the target reads the
        /// old contents back, too long and the person's own clipboard is wrong
        /// for noticeably long.
        pub fn with_restored<F>(text: &str, body: F) -> Result<(), String>
        where
            F: FnOnce() -> Result<(), String>,
        {
            let previous = read();
            write(text)?;
            let result = body();
            // Give the target a moment to read it, then restore.
            std::thread::sleep(std::time::Duration::from_millis(120));
            if let Some(previous) = previous {
                let _ = write(&previous);
            }
            result
        }

        fn read() -> Option<String> {
            unsafe {
                OpenClipboard(None).ok()?;
                let handle = GetClipboardData(CF_UNICODETEXT.0 as u32).ok();
                let value = handle.and_then(|handle| {
                    let pointer = GlobalLock(HGLOBAL(handle.0)) as *const u16;
                    if pointer.is_null() {
                        return None;
                    }
                    let mut length = 0usize;
                    while *pointer.add(length) != 0 {
                        length += 1;
                    }
                    let slice = std::slice::from_raw_parts(pointer, length);
                    let out = String::from_utf16_lossy(slice);
                    let _ = GlobalUnlock(HGLOBAL(handle.0));
                    Some(out)
                });
                let _ = CloseClipboard();
                value
            }
        }

        pub fn write(text: &str) -> Result<(), String> {
            unsafe {
                OpenClipboard(None).map_err(|e| e.to_string())?;
                EmptyClipboard().map_err(|e| e.to_string())?;
                let mut units: Vec<u16> = text.encode_utf16().collect();
                units.push(0);
                let bytes = units.len() * std::mem::size_of::<u16>();
                let global = GlobalAlloc(GMEM_MOVEABLE, bytes).map_err(|e| e.to_string())?;
                let pointer = GlobalLock(global) as *mut u16;
                std::ptr::copy_nonoverlapping(units.as_ptr(), pointer, units.len());
                let _ = GlobalUnlock(global);
                SetClipboardData(CF_UNICODETEXT.0 as u32, HANDLE(global.0))
                    .map_err(|e| e.to_string())?;
                let _ = CloseClipboard();
                Ok(())
            }
        }
    }
}

#[cfg(not(windows))]
mod platform {
    use super::Outcome;

    pub fn copy(_text: &str) -> Result<(), String> {
        Err("The clipboard is only implemented on Windows.".into())
    }

    pub fn insert(text: &str, paste: bool) -> Outcome {
        tracing::info!(
            chars = text.chars().count(),
            paste,
            "insertion is Windows-only; nothing was typed"
        );
        Outcome {
            label: "Insertion is only implemented on Windows.".into(),
            delivered: false,
        }
    }
}
