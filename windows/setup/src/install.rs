//! What the setup does to the PC: install, update and remove.
//!
//! Everything is per user, under the profile, so nothing asks for an
//! administrator and nothing is written outside what the person owns: the app
//! in `%LOCALAPPDATA%\Huh`, the same folder the stock installer used, so an
//! update lands over an earlier install of either kind; a Start menu entry;
//! and the entry Windows lists under Installed apps.
//!
//! Removing leaves the transcripts, the dictionary and the downloaded models
//! where they are unless asked otherwise, because the models are gigabytes to
//! fetch again and the transcripts cannot be fetched at all.
use std::fs;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};

use serde::Serialize;

/// The app, compressed at build time.
static PAYLOAD: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/huh.exe.zst"));
pub const PAYLOAD_SIZE: u64 = parse(env!("HUH_PAYLOAD_SIZE"));
pub const VERSION: &str = env!("HUH_APP_VERSION");

pub const fn parse(text: &str) -> u64 {
    let bytes = text.as_bytes();
    let mut value = 0u64;
    let mut i = 0;
    while i < bytes.len() {
        value = value * 10 + (bytes[i] - b'0') as u64;
        i += 1;
    }
    value
}

/// Where everything goes. Redirected wholesale into one scratch folder when
/// `HUH_SETUP_TEST` names one, so the setup can be exercised without touching
/// the real install, the real Start menu or the registry's real entries.
#[derive(Debug, Clone)]
pub struct Places {
    pub app_dir: PathBuf,
    pub data_dir: PathBuf,
    pub models_dir: PathBuf,
    pub webview_dir: PathBuf,
    pub programs: PathBuf,
    pub desktop: PathBuf,
    pub uninstall_key: String,
    pub test: bool,
}

impl Places {
    pub fn find() -> Self {
        if let Ok(root) = std::env::var("HUH_SETUP_TEST") {
            let root = PathBuf::from(root);
            return Self {
                app_dir: root.join("Local").join("Huh"),
                data_dir: root.join("Roaming").join("Huh"),
                models_dir: root.join("Local").join("Huh").join("Models"),
                webview_dir: root.join("Local").join("com.getnsh.huh"),
                programs: root.join("Start Menu"),
                desktop: root.join("Desktop"),
                uninstall_key: r"Software\getnsh\HuhSetupTest\Uninstall".into(),
                test: true,
            };
        }
        let local = env_dir("LOCALAPPDATA");
        let roaming = env_dir("APPDATA");
        Self {
            app_dir: local.join("Huh"),
            data_dir: roaming.join("Huh"),
            models_dir: local.join("Huh").join("Models"),
            webview_dir: local.join("com.getnsh.huh"),
            programs: platform::known_folder(platform::Folder::Programs)
                .unwrap_or_else(|| roaming.join(r"Microsoft\Windows\Start Menu\Programs")),
            desktop: platform::known_folder(platform::Folder::Desktop)
                .unwrap_or_else(|| env_dir("USERPROFILE").join("Desktop")),
            uninstall_key: r"Software\Microsoft\Windows\CurrentVersion\Uninstall\Huh".into(),
            test: false,
        }
    }

    pub fn app(&self) -> PathBuf {
        self.app_dir.join("huh.exe")
    }

    pub fn uninstaller(&self) -> PathBuf {
        self.app_dir.join("uninstall.exe")
    }

    /// The Start menu entry. "Huh", as the stock installer named it: a file
    /// name cannot hold the question mark.
    pub fn start_entry(&self) -> PathBuf {
        self.programs.join("Huh.lnk")
    }

    pub fn desktop_entry(&self) -> PathBuf {
        self.desktop.join("Huh.lnk")
    }
}

fn env_dir(name: &str) -> PathBuf {
    std::env::var(name)
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("."))
}

/// What the page needs to know before anything happens.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Situation {
    pub version: String,
    /// The version already installed, "" when there is a copy of unknown
    /// version, or nothing when there is none.
    pub installed: Option<String>,
    pub running: bool,
    pub app_dir: String,
    pub data_dir: String,
    /// Whether there is a desktop shortcut now, so an update keeps it.
    pub desktop: bool,
    pub size: u64,
    pub packed: u64,
    pub has_data: bool,
    pub models_size: u64,
    /// The push-to-talk key, as the person last chose it.
    pub key: String,
    pub test: bool,
}

pub fn situation(places: &Places) -> Situation {
    let installed = platform::read_value(&places.uninstall_key, "DisplayVersion")
        .or_else(|| places.app().exists().then(String::new));
    Situation {
        version: VERSION.into(),
        installed,
        running: !platform::running_copies(&places.app()).is_empty(),
        app_dir: shorten(&places.app_dir),
        data_dir: shorten(&places.data_dir),
        desktop: places.desktop_entry().exists(),
        size: PAYLOAD_SIZE,
        packed: PAYLOAD.len() as u64,
        has_data: places.data_dir.join("history.json").exists(),
        models_size: folder_size(&places.models_dir),
        key: chosen_key(places),
        test: places.test,
    }
}

/// The key named the way Settings names it, so the page can say which one
/// to hold; Right Ctrl, the default, until someone has chosen another.
fn chosen_key(places: &Places) -> String {
    let chosen = fs::read_to_string(places.data_dir.join("settings.json"))
        .ok()
        .and_then(|text| serde_json::from_str::<serde_json::Value>(&text).ok())
        .and_then(|settings| settings.get("hotkey")?.as_str().map(str::to_owned));
    match chosen.as_deref() {
        Some("leftControl") => "Left Ctrl",
        Some("rightShift") => "Right Shift",
        Some("rightAlt") => "Right Alt",
        Some("capsLock") => "Caps Lock",
        _ => "Right Ctrl",
    }
    .into()
}

/// `C:\Users\Ada\AppData\Local\Huh` as `~\AppData\Local\Huh`.
fn shorten(path: &Path) -> String {
    let text = path.display().to_string();
    match std::env::var("USERPROFILE") {
        Ok(home) if text.to_lowercase().starts_with(&home.to_lowercase()) => {
            format!("~{}", &text[home.len()..])
        }
        _ => text,
    }
}

fn folder_size(path: &Path) -> u64 {
    let Ok(entries) = fs::read_dir(path) else {
        return 0;
    };
    entries
        .flatten()
        .map(|entry| match entry.metadata() {
            Ok(meta) if meta.is_dir() => folder_size(&entry.path()),
            Ok(meta) => meta.len(),
            Err(_) => 0,
        })
        .sum()
}

/// Progress, for the page: how far along, and the step under way.
pub trait Report {
    fn step(&mut self, fraction: f64, label: &str);
}

#[derive(Debug, Clone, Copy, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InstallChoices {
    pub desktop: bool,
}

pub fn install(
    places: &Places,
    choices: InstallChoices,
    report: &mut dyn Report,
) -> Result<(), String> {
    let app = places.app();

    let running = platform::running_copies(&app);
    if !running.is_empty() {
        report.step(0.02, "Closing huh?");
        platform::close(&running);
    }

    report.step(0.04, "Writing huh.exe");
    fs::create_dir_all(&places.app_dir)
        .map_err(|e| format!("Couldn't create {}: {e}", places.app_dir.display()))?;
    let fresh = places.app_dir.join("huh.exe.new");
    {
        let mut decoder = zstd::stream::read::Decoder::new(PAYLOAD)
            .map_err(|e| format!("The setup is damaged: {e}"))?;
        let mut out = fs::File::create(&fresh)
            .map_err(|e| format!("Couldn't write to {}: {e}", places.app_dir.display()))?;
        let mut buffer = vec![0u8; 1 << 20];
        let mut written = 0u64;
        loop {
            let read = decoder
                .read(&mut buffer)
                .map_err(|e| format!("The setup is damaged: {e}"))?;
            if read == 0 {
                break;
            }
            out.write_all(&buffer[..read])
                .map_err(|e| format!("Couldn't write huh.exe: {e}"))?;
            written += read as u64;
            report.step(
                0.04 + 0.84 * written as f64 / PAYLOAD_SIZE.max(1) as f64,
                "Writing huh.exe",
            );
        }
        out.flush()
            .map_err(|e| format!("Couldn't write huh.exe: {e}"))?;
    }
    replace(&fresh, &app)?;

    report.step(0.90, "Adding the uninstaller");
    let me = std::env::current_exe().map_err(|e| e.to_string())?;
    if !same_file(&me, &places.uninstaller()) {
        fs::copy(&me, places.uninstaller())
            .map_err(|e| format!("Couldn't add the uninstaller: {e}"))?;
    }

    report.step(0.93, "Adding to Start");
    fs::create_dir_all(&places.programs).map_err(|e| e.to_string())?;
    platform::shortcut(&places.start_entry(), &app, &places.app_dir)?;
    if choices.desktop {
        fs::create_dir_all(&places.desktop).map_err(|e| e.to_string())?;
        platform::shortcut(&places.desktop_entry(), &app, &places.app_dir)?;
    } else if places.desktop_entry().exists() {
        let _ = fs::remove_file(places.desktop_entry());
    }

    report.step(0.97, "Registering with Windows");
    // Afresh, so nothing an earlier installer wrote there is left beside
    // what this one says.
    platform::delete_key(&places.uninstall_key);
    let uninstall = format!("\"{}\" --uninstall", places.uninstaller().display());
    let quiet = format!("{uninstall} --silent");
    let own = fs::metadata(places.uninstaller())
        .map(|m| m.len())
        .unwrap_or(0);
    let kilobytes = ((PAYLOAD_SIZE + own) / 1024) as u32;
    let values: [(&str, &str); 8] = [
        ("DisplayName", "huh?"),
        ("DisplayVersion", VERSION),
        ("Publisher", "getnsh"),
        ("DisplayIcon", &app.display().to_string()),
        ("InstallLocation", &places.app_dir.display().to_string()),
        ("UninstallString", &uninstall),
        ("QuietUninstallString", &quiet),
        ("URLInfoAbout", "https://github.com/getnsh/huh"),
    ];
    for (name, value) in values {
        platform::write_value(&places.uninstall_key, name, value)?;
    }
    platform::write_number(&places.uninstall_key, "EstimatedSize", kilobytes)?;
    platform::write_number(&places.uninstall_key, "NoModify", 1)?;
    platform::write_number(&places.uninstall_key, "NoRepair", 1)?;

    report.step(1.0, "Done");
    Ok(())
}

#[derive(Debug, Clone, Copy, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RemoveChoices {
    pub data: bool,
    pub models: bool,
}

pub fn remove(
    places: &Places,
    choices: RemoveChoices,
    report: &mut dyn Report,
) -> Result<(), String> {
    let running = platform::running_copies(&places.app());
    if !running.is_empty() {
        report.step(0.05, "Closing huh?");
        platform::close(&running);
    }

    report.step(0.15, "Removing huh.exe");
    if places.app().exists() {
        fs::remove_file(places.app()).map_err(|e| format!("Couldn't remove huh.exe: {e}"))?;
    }

    report.step(0.35, "Removing shortcuts");
    for entry in [places.start_entry(), places.desktop_entry()] {
        if entry.exists() {
            let _ = fs::remove_file(entry);
        }
    }

    report.step(0.50, "Unregistering");
    platform::delete_key(&places.uninstall_key);
    if !places.test {
        // Starting at sign-in, if it was turned on, goes with the app.
        platform::delete_value(r"Software\Microsoft\Windows\CurrentVersion\Run", "Huh");
        platform::delete_value(
            r"Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run",
            "Huh",
        );
        // Where the stock installer kept its own notes.
        platform::delete_key(r"Software\getnsh\Huh");
    }

    if choices.models && places.models_dir.exists() {
        report.step(0.65, "Deleting the downloaded models");
        let _ = fs::remove_dir_all(&places.models_dir);
    }
    if choices.data {
        report.step(0.85, "Deleting transcripts and the dictionary");
        let _ = fs::remove_dir_all(&places.data_dir);
        let _ = fs::remove_dir_all(&places.webview_dir);
    }
    report.step(1.0, "Done");
    Ok(())
}

/// After removing: the uninstaller cannot delete itself while it runs, so a
/// hidden command waits for it to exit, then takes it and the folder, which
/// goes only if nothing else is left in it.
pub fn tidy_after_exit(places: &Places) {
    let me = std::env::current_exe().unwrap_or_default();
    if !same_file(&me, &places.uninstaller()) {
        let _ = fs::remove_file(places.uninstaller());
        let _ = fs::remove_dir(&places.app_dir);
        return;
    }
    platform::delete_later(&places.uninstaller(), &places.app_dir);
}

/// Opens the installed app, without the setup's own environment: a variable
/// set for testing must not follow it into everyday use. Under test it
/// does follow, so a test copy can be pointed at test data.
pub fn open(places: &Places) -> Result<(), String> {
    let mut command = std::process::Command::new(places.app());
    command.current_dir(&places.app_dir);
    for (key, _) in std::env::vars() {
        if !places.test && (key.starts_with("HUH_") || key.starts_with("WEBVIEW2_")) {
            command.env_remove(key);
        }
    }
    command
        .spawn()
        .map(|_| ())
        .map_err(|e| format!("Couldn't open huh?: {e}"))
}

fn replace(fresh: &Path, target: &Path) -> Result<(), String> {
    // A copy that has only just been closed can hold its file a moment
    // longer than its process.
    let mut last = String::new();
    for _ in 0..40 {
        match fs::rename(fresh, target) {
            Ok(()) => return Ok(()),
            Err(error) => last = error.to_string(),
        }
        std::thread::sleep(std::time::Duration::from_millis(125));
    }
    let _ = fs::remove_file(fresh);
    Err(format!(
        "Couldn't replace huh.exe: {last}. Quit huh? from the notification area and try again."
    ))
}

fn same_file(a: &Path, b: &Path) -> bool {
    match (a.canonicalize(), b.canonicalize()) {
        (Ok(a), Ok(b)) => a == b,
        _ => false,
    }
}

#[cfg(windows)]
mod platform {
    use std::os::windows::process::CommandExt;
    use std::path::{Path, PathBuf};

    use windows::core::{Interface, HSTRING, PCWSTR, PWSTR};
    use windows::Win32::Foundation::{CloseHandle, HANDLE};
    use windows::Win32::System::Com::{
        CoCreateInstance, CoInitializeEx, CoTaskMemFree, IPersistFile, CLSCTX_INPROC_SERVER,
        COINIT_APARTMENTTHREADED,
    };
    use windows::Win32::System::Diagnostics::ToolHelp::{
        CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W,
        TH32CS_SNAPPROCESS,
    };
    use windows::Win32::System::Registry::{
        RegCloseKey, RegCreateKeyExW, RegDeleteKeyValueW, RegDeleteTreeW, RegGetValueW,
        RegSetValueExW, HKEY, HKEY_CURRENT_USER, KEY_WRITE, REG_DWORD, REG_OPTION_NON_VOLATILE,
        REG_SZ, RRF_RT_REG_SZ,
    };
    use windows::Win32::System::Threading::{
        OpenProcess, QueryFullProcessImageNameW, TerminateProcess, WaitForSingleObject,
        PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION, PROCESS_SYNCHRONIZE,
        PROCESS_TERMINATE,
    };
    use windows::Win32::UI::Shell::{
        FOLDERID_Desktop, FOLDERID_Programs, IShellLinkW, SHGetKnownFolderPath, ShellLink,
        KF_FLAG_DEFAULT,
    };

    pub enum Folder {
        Desktop,
        Programs,
    }

    pub fn known_folder(folder: Folder) -> Option<PathBuf> {
        let id = match folder {
            Folder::Desktop => &FOLDERID_Desktop,
            Folder::Programs => &FOLDERID_Programs,
        };
        unsafe {
            let path = SHGetKnownFolderPath(id, KF_FLAG_DEFAULT, None).ok()?;
            let text = path.to_string().ok();
            CoTaskMemFree(Some(path.0 as *const _));
            text.map(PathBuf::from)
        }
    }

    /// Every running copy of exactly this file, by process id.
    pub fn running_copies(app: &Path) -> Vec<u32> {
        let wanted = app.display().to_string().to_lowercase();
        let mut found = Vec::new();
        unsafe {
            let Ok(snapshot) = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) else {
                return found;
            };
            let mut entry = PROCESSENTRY32W {
                dwSize: std::mem::size_of::<PROCESSENTRY32W>() as u32,
                ..Default::default()
            };
            let mut more = Process32FirstW(snapshot, &mut entry).is_ok();
            while more {
                let name = String::from_utf16_lossy(&entry.szExeFile)
                    .trim_end_matches('\0')
                    .to_lowercase();
                if name == "huh.exe" {
                    if let Some(path) = image_path(entry.th32ProcessID) {
                        if path.to_lowercase() == wanted {
                            found.push(entry.th32ProcessID);
                        }
                    }
                }
                more = Process32NextW(snapshot, &mut entry).is_ok();
            }
            let _ = CloseHandle(snapshot);
        }
        found
    }

    fn image_path(pid: u32) -> Option<String> {
        unsafe {
            let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid).ok()?;
            let mut buffer = [0u16; 1024];
            let mut length = buffer.len() as u32;
            let ok = QueryFullProcessImageNameW(
                process,
                PROCESS_NAME_WIN32,
                PWSTR(buffer.as_mut_ptr()),
                &mut length,
            )
            .is_ok();
            let _ = CloseHandle(process);
            ok.then(|| String::from_utf16_lossy(&buffer[..length as usize]))
        }
    }

    /// Ends each copy and waits for it to go. The app keeps its files
    /// written whole, so a copy ended mid-write leaves the last good one.
    pub fn close(pids: &[u32]) {
        for &pid in pids {
            unsafe {
                let Ok(process) = OpenProcess(PROCESS_TERMINATE | PROCESS_SYNCHRONIZE, false, pid)
                else {
                    continue;
                };
                let _ = TerminateProcess(process, 0);
                WaitForSingleObject(process, 5000);
                let _ = CloseHandle(HANDLE(process.0));
            }
        }
    }

    pub fn shortcut(at: &Path, target: &Path, folder: &Path) -> Result<(), String> {
        unsafe {
            let _ = CoInitializeEx(None, COINIT_APARTMENTTHREADED);
            let link: IShellLinkW = CoCreateInstance(&ShellLink, None, CLSCTX_INPROC_SERVER)
                .map_err(|e| format!("Couldn't make a shortcut: {e}"))?;
            link.SetPath(&HSTRING::from(target.as_os_str()))
                .map_err(|e| e.to_string())?;
            link.SetWorkingDirectory(&HSTRING::from(folder.as_os_str()))
                .map_err(|e| e.to_string())?;
            link.SetDescription(&HSTRING::from("Hold. Speak. It's typed."))
                .map_err(|e| e.to_string())?;
            link.SetIconLocation(&HSTRING::from(target.as_os_str()), 0)
                .map_err(|e| e.to_string())?;
            let file: IPersistFile = link.cast().map_err(|e| e.to_string())?;
            file.Save(&HSTRING::from(at.as_os_str()), true)
                .map_err(|e| format!("Couldn't save {}: {e}", at.display()))
        }
    }

    fn open_key(path: &str) -> Result<HKEY, String> {
        let mut key = HKEY::default();
        unsafe {
            RegCreateKeyExW(
                HKEY_CURRENT_USER,
                &HSTRING::from(path),
                0,
                PCWSTR::null(),
                REG_OPTION_NON_VOLATILE,
                KEY_WRITE,
                None,
                &mut key,
                None,
            )
            .ok()
            .map_err(|e| format!("Couldn't register with Windows: {e}"))?;
        }
        Ok(key)
    }

    pub fn write_value(path: &str, name: &str, value: &str) -> Result<(), String> {
        let key = open_key(path)?;
        let mut units: Vec<u16> = value.encode_utf16().collect();
        units.push(0);
        let bytes =
            unsafe { std::slice::from_raw_parts(units.as_ptr().cast::<u8>(), units.len() * 2) };
        let result = unsafe { RegSetValueExW(key, &HSTRING::from(name), 0, REG_SZ, Some(bytes)) };
        unsafe {
            let _ = RegCloseKey(key);
        }
        result
            .ok()
            .map_err(|e| format!("Couldn't register with Windows: {e}"))
    }

    pub fn write_number(path: &str, name: &str, value: u32) -> Result<(), String> {
        let key = open_key(path)?;
        let bytes = value.to_le_bytes();
        let result =
            unsafe { RegSetValueExW(key, &HSTRING::from(name), 0, REG_DWORD, Some(&bytes)) };
        unsafe {
            let _ = RegCloseKey(key);
        }
        result
            .ok()
            .map_err(|e| format!("Couldn't register with Windows: {e}"))
    }

    pub fn read_value(path: &str, name: &str) -> Option<String> {
        let mut buffer = [0u16; 512];
        let mut size = (buffer.len() * 2) as u32;
        unsafe {
            RegGetValueW(
                HKEY_CURRENT_USER,
                &HSTRING::from(path),
                &HSTRING::from(name),
                RRF_RT_REG_SZ,
                None,
                Some(buffer.as_mut_ptr().cast()),
                Some(&mut size),
            )
            .ok()
            .ok()?;
        }
        let units = (size as usize / 2).saturating_sub(1);
        Some(String::from_utf16_lossy(&buffer[..units]))
    }

    pub fn delete_key(path: &str) {
        unsafe {
            let _ = RegDeleteTreeW(HKEY_CURRENT_USER, &HSTRING::from(path));
            let _ = windows::Win32::System::Registry::RegDeleteKeyW(
                HKEY_CURRENT_USER,
                &HSTRING::from(path),
            );
        }
    }

    pub fn delete_value(path: &str, name: &str) {
        unsafe {
            let _ = RegDeleteKeyValueW(
                HKEY_CURRENT_USER,
                &HSTRING::from(path),
                &HSTRING::from(name),
            );
        }
    }

    pub fn delete_later(file: &Path, folder: &Path) {
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        let script = format!(
            "ping 127.0.0.1 -n 3 > nul & del /f /q \"{}\" & rmdir \"{}\"",
            file.display(),
            folder.display()
        );
        // Verbatim: the standard quoting turns each `"` into `\"`, which cmd
        // does not read as a quote. Wrapped whole, cmd strips the outer pair
        // and runs the rest as written.
        let _ = std::process::Command::new("cmd")
            .raw_arg("/C")
            .raw_arg(format!("\"{script}\""))
            .creation_flags(CREATE_NO_WINDOW)
            .spawn();
    }
}

#[cfg(not(windows))]
mod platform {
    use std::path::{Path, PathBuf};
    pub enum Folder {
        Desktop,
        Programs,
    }
    pub fn known_folder(_folder: Folder) -> Option<PathBuf> {
        None
    }
    pub fn running_copies(_app: &Path) -> Vec<u32> {
        Vec::new()
    }
    pub fn close(_pids: &[u32]) {}
    pub fn shortcut(_at: &Path, _target: &Path, _folder: &Path) -> Result<(), String> {
        Err("Shortcuts are Windows-only.".into())
    }
    pub fn write_value(_path: &str, _name: &str, _value: &str) -> Result<(), String> {
        Ok(())
    }
    pub fn write_number(_path: &str, _name: &str, _value: u32) -> Result<(), String> {
        Ok(())
    }
    pub fn read_value(_path: &str, _name: &str) -> Option<String> {
        None
    }
    pub fn delete_key(_path: &str) {}
    pub fn delete_value(_path: &str, _name: &str) {}
    pub fn delete_later(_file: &Path, _folder: &Path) {}
}
