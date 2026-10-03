//! Noticing that a call has started.
//!
//! The Mac asks Core Audio which processes have the microphone open. Windows
//! keeps the same fact where its own "microphone in use" indicator reads it:
//! each app's last use of the microphone, start and stop, under the privacy
//! consent store. An app that has started and not stopped has it open now.
//! Nothing else is read -- no screen, no window titles, no audio -- which is
//! the same promise the Mac makes about its version.
//!
//! huh? itself is left out, and so are the parts of Windows that listen for
//! their own reasons: voice access, live captions, the speech service.

/// The apps using the microphone right now, by the names people call them,
/// most recently started first.
pub fn in_use() -> Vec<String> {
    let mut found = platform::in_use();
    found.sort_by_key(|(since, _)| std::cmp::Reverse(*since));
    let mut names: Vec<String> = Vec::new();
    for (_, name) in found {
        if !names.contains(&name) {
            names.push(name);
        }
    }
    names
}

/// Packaged and desktop apps that listen without being a call.
const NOT_CALLS: &[&str] = &[
    "huh",
    "voiceaccess",
    "livecaptions",
    "sapisvr",
    "speechruntime",
    "cortana",
    "microsoft.549981c3f5f10",
    "soundrecorder",
    "windowssoundrecorder",
];

/// The name an app goes by, from its executable or package. Exact names
/// first, then fragments, then the file name as it is.
pub fn display_name(stem: &str) -> String {
    let lowered = stem.to_lowercase();
    const EXACT: &[(&str, &str)] = &[
        ("ms-teams", "Teams"),
        ("msteams", "Teams"),
        ("teams", "Teams"),
        ("microsoftteams", "Teams"),
        ("zoom", "Zoom"),
        ("slack", "Slack"),
        ("discord", "Discord"),
        ("discordptb", "Discord"),
        ("discordcanary", "Discord"),
        ("ciscocollabhost", "Webex"),
        ("atmgr", "Webex"),
        ("chrome", "Chrome"),
        ("msedge", "Edge"),
        ("firefox", "Firefox"),
        ("brave", "Brave"),
        ("opera", "Opera"),
        ("vivaldi", "Vivaldi"),
        ("arc", "Arc"),
        ("skype", "Skype"),
        ("telegram", "Telegram"),
        ("signal", "Signal"),
        ("goto", "GoTo"),
        ("ringcentral", "RingCentral"),
    ];
    if let Some((_, name)) = EXACT.iter().find(|(key, _)| *key == lowered) {
        return (*name).to_string();
    }
    const FRAGMENTS: &[(&str, &str)] = &[
        ("teams", "Teams"),
        ("zoom", "Zoom"),
        ("slack", "Slack"),
        ("discord", "Discord"),
        ("webex", "Webex"),
        ("whatsapp", "WhatsApp"),
        ("skype", "Skype"),
        ("phonelink", "Phone Link"),
        ("yourphone", "Phone Link"),
    ];
    if let Some((_, name)) = FRAGMENTS.iter().find(|(key, _)| lowered.contains(key)) {
        return (*name).to_string();
    }
    let mut chars = stem.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().chain(chars).collect(),
        None => String::new(),
    }
}

/// "MSTeams_8wekyb3d8bbwe" → "MSTeams"; "5319275A.WhatsAppDesktop_cv1g1gvanyjgm"
/// → "WhatsAppDesktop".
fn package_stem(family: &str) -> &str {
    let before = family.split('_').next().unwrap_or(family);
    before.rsplit('.').next().unwrap_or(before)
}

/// "C:#Program Files#Zoom#bin#Zoom.exe" → "Zoom".
fn executable_stem(mangled: &str) -> String {
    let path = mangled.replace('#', "\\");
    std::path::Path::new(&path)
        .file_stem()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or(path)
}

fn is_call(stem: &str) -> bool {
    let lowered = stem.to_lowercase();
    !NOT_CALLS
        .iter()
        .any(|skip| lowered == *skip || lowered.starts_with(skip))
}

#[cfg(windows)]
mod platform {
    use super::{display_name, executable_stem, is_call, package_stem};
    use windows::core::{HSTRING, PCWSTR, PWSTR};
    use windows::Win32::Foundation::ERROR_NO_MORE_ITEMS;
    use windows::Win32::System::Registry::{
        RegCloseKey, RegEnumKeyExW, RegGetValueW, RegOpenKeyExW, HKEY, HKEY_CURRENT_USER, KEY_READ,
        RRF_RT_REG_QWORD,
    };

    const STORE: &str =
        "Software\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\microphone";

    struct Key(HKEY);

    impl Drop for Key {
        fn drop(&mut self) {
            unsafe {
                let _ = RegCloseKey(self.0);
            }
        }
    }

    fn open(parent: HKEY, path: &str) -> Option<Key> {
        let mut key = HKEY::default();
        let path = HSTRING::from(path);
        unsafe { RegOpenKeyExW(parent, &path, 0, KEY_READ, &mut key) }
            .is_ok()
            .then_some(Key(key))
    }

    fn subkeys(key: &Key) -> Vec<String> {
        let mut out = Vec::new();
        let mut index = 0u32;
        loop {
            let mut buffer = [0u16; 512];
            let mut length = buffer.len() as u32;
            let status = unsafe {
                RegEnumKeyExW(
                    key.0,
                    index,
                    PWSTR(buffer.as_mut_ptr()),
                    &mut length,
                    None,
                    PWSTR::null(),
                    None,
                    None,
                )
            };
            if status == ERROR_NO_MORE_ITEMS || status.is_err() {
                break;
            }
            out.push(String::from_utf16_lossy(&buffer[..length as usize]));
            index += 1;
        }
        out
    }

    fn qword(key: &Key, subkey: &str, value: &str) -> Option<u64> {
        let mut data = 0u64;
        let mut size = std::mem::size_of::<u64>() as u32;
        let subkey = HSTRING::from(subkey);
        let value = HSTRING::from(value);
        let status = unsafe {
            RegGetValueW(
                key.0,
                PCWSTR(subkey.as_ptr()),
                PCWSTR(value.as_ptr()),
                RRF_RT_REG_QWORD,
                None,
                Some(std::ptr::from_mut(&mut data).cast()),
                Some(&mut size),
            )
        };
        status.is_ok().then_some(data)
    }

    /// When an app started using the microphone, if it has not stopped.
    fn listening_since(key: &Key, subkey: &str) -> Option<u64> {
        let start = qword(key, subkey, "LastUsedTimeStart")?;
        let stop = qword(key, subkey, "LastUsedTimeStop").unwrap_or(0);
        (start > 0 && stop == 0).then_some(start)
    }

    pub fn in_use() -> Vec<(u64, String)> {
        let mut found = Vec::new();
        let Some(store) = open(HKEY_CURRENT_USER, STORE) else {
            return found;
        };
        let ours = std::env::current_exe()
            .ok()
            .and_then(|path| path.file_stem().map(|s| s.to_string_lossy().to_lowercase()));

        for package in subkeys(&store) {
            if package == "NonPackaged" {
                continue;
            }
            if let Some(since) = listening_since(&store, &package) {
                let stem = package_stem(&package);
                if is_call(stem) {
                    found.push((since, display_name(stem)));
                }
            }
        }

        if let Some(desktop) = open(store.0, "NonPackaged") {
            for program in subkeys(&desktop) {
                if let Some(since) = listening_since(&desktop, &program) {
                    let stem = executable_stem(&program);
                    if Some(stem.to_lowercase()) == ours || !is_call(&stem) {
                        continue;
                    }
                    found.push((since, display_name(&stem)));
                }
            }
        }
        found
    }
}

#[cfg(not(windows))]
mod platform {
    pub fn in_use() -> Vec<(u64, String)> {
        Vec::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn apps_go_by_the_names_people_call_them() {
        assert_eq!(display_name(package_stem("MSTeams_8wekyb3d8bbwe")), "Teams");
        assert_eq!(
            display_name(&executable_stem(
                "C:#Users#ada#AppData#Roaming#Zoom#bin#Zoom.exe"
            )),
            "Zoom"
        );
        assert_eq!(
            display_name(package_stem("5319275A.WhatsAppDesktop_cv1g1gvanyjgm")),
            "WhatsApp"
        );
        assert_eq!(display_name("msedge"), "Edge");
        assert_eq!(display_name("obs64"), "Obs64");
    }

    #[test]
    fn windows_own_listeners_are_not_calls() {
        assert!(!is_call("VoiceAccess"));
        assert!(!is_call("LiveCaptions"));
        assert!(!is_call("huh"));
        assert!(is_call("Zoom"));
    }
}
