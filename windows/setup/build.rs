//! Packs the application into the setup program.
//!
//! The release build of huh? is compressed into the output directory and the
//! setup includes it as bytes, so one file carries everything. The page gets
//! the app's fonts inlined, the window's icon is decoded, and the program
//! gets the app's icon, its version and a manifest.
use std::env;
use std::fs;
use std::io::Write;
use std::path::PathBuf;

fn main() {
    let manifest = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let windows = manifest.parent().unwrap().to_path_buf();
    let out = PathBuf::from(env::var("OUT_DIR").unwrap());

    // The application, as `tauri build` leaves it.
    let app = windows.join("target").join("release").join("huh.exe");
    println!("cargo:rerun-if-changed={}", app.display());
    let bytes = fs::read(&app).unwrap_or_else(|_| {
        panic!(
            "\n\nThe setup carries the app inside it, and there is no release build to carry: \
             {} is missing.\nBuild the app first: `npm run tauri build` in windows\\app, \
             or `npm run setup`, which does both.\n\n",
            app.display()
        )
    });
    let packed = zstd::bulk::compress(&bytes, 19).expect("compressing the app");
    fs::write(out.join("huh.exe.zst"), &packed).unwrap();
    println!("cargo:rustc-env=HUH_PAYLOAD_SIZE={}", bytes.len());
    println!("cargo:rustc-env=HUH_PAYLOAD_PACKED={}", packed.len());

    // The version the app says it is, from its own configuration.
    let config = windows
        .join("app")
        .join("src-tauri")
        .join("tauri.conf.json");
    println!("cargo:rerun-if-changed={}", config.display());
    let text = fs::read_to_string(&config).unwrap();
    let version = text
        .lines()
        .find_map(|line| {
            let line = line.trim();
            line.strip_prefix("\"version\":").map(|rest| {
                rest.trim()
                    .trim_matches(|c| c == '"' || c == ',')
                    .to_string()
            })
        })
        .unwrap_or_else(|| env::var("CARGO_PKG_VERSION").unwrap());
    println!("cargo:rustc-env=HUH_APP_VERSION={version}");

    // The page, with the fonts the app bundles written into it, so the
    // setup looks like the app and fetches nothing. Without them it falls
    // back to Segoe UI, which is a reason to warn rather than to fail.
    let page_path = manifest.join("ui").join("index.html");
    println!("cargo:rerun-if-changed={}", page_path.display());
    let mut page = fs::read_to_string(&page_path).unwrap();
    let fonts = windows
        .join("app")
        .join("node_modules")
        .join("@fontsource-variable");
    for (marker, file) in [
        (
            "/*INTER*/",
            fonts
                .join("inter")
                .join("files")
                .join("inter-latin-opsz-normal.woff2"),
        ),
        (
            "/*MONO*/",
            fonts
                .join("jetbrains-mono")
                .join("files")
                .join("jetbrains-mono-latin-wght-normal.woff2"),
        ),
    ] {
        println!("cargo:rerun-if-changed={}", file.display());
        match fs::read(&file) {
            Ok(font) => page = page.replace(marker, &base64(&font)),
            Err(_) => println!(
                "cargo:warning={} is missing, so the setup will draw in Segoe UI. \
                 Run `npm install` in windows\\app.",
                file.display()
            ),
        }
    }
    fs::write(out.join("index.html"), page).unwrap();

    // The window icon, as raw RGBA for tao.
    let icons = windows.join("app").join("src-tauri").join("icons");
    let png_path = icons.join("32x32.png");
    println!("cargo:rerun-if-changed={}", png_path.display());
    let decoder = png::Decoder::new(fs::File::open(&png_path).unwrap());
    let mut reader = decoder.read_info().unwrap();
    let mut pixels = vec![0; reader.output_buffer_size()];
    let info = reader.next_frame(&mut pixels).unwrap();
    let rgba = match info.color_type {
        png::ColorType::Rgba => pixels[..info.buffer_size()].to_vec(),
        png::ColorType::Rgb => pixels[..info.buffer_size()]
            .chunks(3)
            .flat_map(|p| [p[0], p[1], p[2], 255])
            .collect(),
        other => panic!("the window icon is {other:?}; it should be RGBA"),
    };
    let mut file = fs::File::create(out.join("icon.rgba")).unwrap();
    file.write_all(&rgba).unwrap();
    println!("cargo:rustc-env=HUH_ICON_SIZE={}", info.width);

    // The program's own icon, version and manifest.
    let mut res = tauri_winres::WindowsResource::new();
    res.set_icon(icons.join("icon.ico").to_str().unwrap());
    res.set("FileDescription", "huh? setup");
    res.set("ProductName", "huh?");
    res.set("CompanyName", "getnsh");
    res.set(
        "LegalCopyright",
        "Copyright (C) 2026 getnsh. GPL-3.0-or-later.",
    );
    res.set("FileVersion", &version);
    res.set("ProductVersion", &version);
    res.set_manifest(MANIFEST);
    res.compile().expect("compiling the setup's resources");
}

fn base64(bytes: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut text = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let triple = (chunk[0] as u32) << 16
            | (*chunk.get(1).unwrap_or(&0) as u32) << 8
            | *chunk.get(2).unwrap_or(&0) as u32;
        text.push(TABLE[(triple >> 18) as usize & 63] as char);
        text.push(TABLE[(triple >> 12) as usize & 63] as char);
        text.push(if chunk.len() > 1 {
            TABLE[(triple >> 6) as usize & 63] as char
        } else {
            '='
        });
        text.push(if chunk.len() > 2 {
            TABLE[triple as usize & 63] as char
        } else {
            '='
        });
    }
    text
}

/// Per-monitor DPI awareness, so the page is drawn sharp at 125% and 150%,
/// and the modern controls.
const MANIFEST: &str = r#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
  <assemblyIdentity version="1.0.0.0" processorArchitecture="*" name="getnsh.huh.setup" type="win32"/>
  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v3">
    <security>
      <requestedPrivileges>
        <requestedExecutionLevel level="asInvoker" uiAccess="false"/>
      </requestedPrivileges>
    </security>
  </trustInfo>
  <application xmlns="urn:schemas-microsoft-com:asm.v3">
    <windowsSettings>
      <dpiAware xmlns="http://schemas.microsoft.com/SMI/2005/WindowsSettings">true/pm</dpiAware>
      <dpiAwareness xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">PerMonitorV2</dpiAwareness>
    </windowsSettings>
  </application>
  <dependency>
    <dependentAssembly>
      <assemblyIdentity type="win32" name="Microsoft.Windows.Common-Controls" version="6.0.0.0" processorArchitecture="*" publicKeyToken="6595b64144ccf1df" language="*"/>
    </dependentAssembly>
  </dependency>
</assembly>
"#;
