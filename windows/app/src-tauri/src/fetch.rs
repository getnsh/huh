//! Model files, fetched once from a pinned revision on Hugging Face.
//!
//! Shared by the recogniser and the summariser. Every file is named by the
//! commit it comes from rather than by a branch, so what arrives is what was
//! checked; every file is hashed as it arrives and only renamed into place
//! once the hash has matched; and a download that stops part-way carries on
//! from where it stopped next time rather than starting again.
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::path::Path;
use std::time::Duration;

use sha2::{Digest, Sha256};

/// One file, as published at one revision.
pub struct Part {
    /// The name on disk, and the last part of the name in the repository.
    pub name: &'static str,
    pub bytes: u64,
    pub sha256: &'static str,
}

/// Where a model's files are published.
pub struct Source {
    pub repository: &'static str,
    pub revision: &'static str,
    /// The folder within the repository, with a trailing slash, or nothing.
    pub prefix: &'static str,
}

/// Whether a file is in place. Only the size is checked: a file is renamed
/// into place only after its hash has matched, and hashing gigabytes at every
/// launch would cost seconds for nothing.
pub fn complete(folder: &Path, part: &Part) -> bool {
    fs::metadata(folder.join(part.name))
        .map(|meta| meta.len() == part.bytes)
        .unwrap_or(false)
}

/// Whether every file is in place.
pub fn present(folder: &Path, parts: &[Part]) -> bool {
    parts.iter().all(|part| complete(folder, part))
}

/// Fetches whatever is missing, reporting the bytes done and the bytes
/// wanted, counting only what was missing.
pub fn download(
    source: &Source,
    folder: &Path,
    parts: &[Part],
    progress: &mut dyn FnMut(u64, u64),
) -> Result<(), String> {
    fs::create_dir_all(folder).map_err(|e| e.to_string())?;
    let missing: Vec<&Part> = parts
        .iter()
        .filter(|part| !complete(folder, part))
        .collect();
    let total: u64 = missing.iter().map(|part| part.bytes).sum();
    let agent = agent();
    let mut finished = 0u64;
    for part in missing {
        fetch(&agent, source, folder, part, &mut |bytes| {
            progress(finished + bytes, total)
        })?;
        finished += part.bytes;
    }
    Ok(())
}

/// A size as people read one: "640 MB", "2.9 GB".
pub fn readable(bytes: u64) -> String {
    const MB: f64 = 1_000_000.0;
    const GB: f64 = 1_000_000_000.0;
    let value = bytes as f64;
    if value >= GB {
        format!("{:.1} GB", value / GB)
    } else {
        format!("{:.0} MB", (value / MB).max(1.0))
    }
}

fn agent() -> ureq::Agent {
    use ureq::tls::{RootCerts, TlsConfig, TlsProvider};
    // The system's TLS and the system's certificate store: the same trust
    // Edge has, including any root a company has installed.
    let tls = TlsConfig::builder()
        .provider(TlsProvider::NativeTls)
        .root_certs(RootCerts::PlatformVerifier)
        .build();
    ureq::Agent::config_builder()
        .tls_config(tls)
        .timeout_connect(Some(Duration::from_secs(20)))
        .user_agent(concat!("huh/", env!("CARGO_PKG_VERSION")))
        .build()
        .new_agent()
}

fn fetch(
    agent: &ureq::Agent,
    source: &Source,
    folder: &Path,
    part: &Part,
    progress: &mut dyn FnMut(u64),
) -> Result<(), String> {
    let target = folder.join(part.name);
    let partial = folder.join(format!("{}.part", part.name));

    // What is already on disk is hashed first, so the check at the end still
    // covers every byte of a download that was resumed.
    let mut hasher = Sha256::new();
    let mut have = match File::open(&partial) {
        Ok(mut existing) => absorb(&mut existing, &mut hasher).unwrap_or(0),
        Err(_) => 0,
    };
    // All of it, from an attempt that ended before the rename: checked, and
    // kept when it is right, rather than thrown away and fetched again.
    if have == part.bytes && format!("{:x}", hasher.clone().finalize()) == part.sha256 {
        progress(have);
        return fs::rename(&partial, &target).map_err(|e| e.to_string());
    }
    if have >= part.bytes {
        let _ = fs::remove_file(&partial);
        hasher = Sha256::new();
        have = 0;
    }

    let url = format!(
        "https://huggingface.co/{}/resolve/{}/{}{}",
        source.repository, source.revision, source.prefix, part.name
    );
    let mut request = agent.get(&url);
    if have > 0 {
        request = request.header("Range", format!("bytes={have}-"));
    }
    let mut response = request
        .call()
        .map_err(|e| format!("{} could not be fetched: {e}", part.name))?;

    // A server is free to ignore a range and send the whole file again.
    let resumed = have > 0 && response.status().as_u16() == 206;
    if !resumed {
        hasher = Sha256::new();
        have = 0;
    }
    let mut file = OpenOptions::new()
        .create(true)
        .write(true)
        .append(resumed)
        .truncate(!resumed)
        .open(&partial)
        .map_err(|e| e.to_string())?;

    let mut reader = response.body_mut().as_reader();
    let mut buffer = vec![0u8; 1 << 16];
    progress(have);
    loop {
        let read = reader
            .read(&mut buffer)
            .map_err(|e| format!("{} stopped arriving: {e}", part.name))?;
        if read == 0 {
            break;
        }
        file.write_all(&buffer[..read]).map_err(|e| e.to_string())?;
        hasher.update(&buffer[..read]);
        have += read as u64;
        progress(have);
    }
    file.flush().map_err(|e| e.to_string())?;
    drop(file);

    if have != part.bytes {
        // Kept, so the next attempt resumes.
        return Err(format!(
            "{} arrived incomplete, {have} of {} bytes.",
            part.name, part.bytes
        ));
    }
    let digest = format!("{:x}", hasher.finalize());
    if digest != part.sha256 {
        let _ = fs::remove_file(&partial);
        return Err(format!("{} did not match its checksum.", part.name));
    }
    fs::rename(&partial, &target).map_err(|e| e.to_string())
}

fn absorb(file: &mut File, hasher: &mut Sha256) -> io::Result<u64> {
    let mut buffer = vec![0u8; 1 << 16];
    let mut total = 0u64;
    loop {
        let read = file.read(&mut buffer)?;
        if read == 0 {
            return Ok(total);
        }
        hasher.update(&buffer[..read]);
        total += read as u64;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sizes_read_the_way_people_say_them() {
        assert_eq!(readable(2_885_434_880), "2.9 GB");
        assert_eq!(readable(670_000_000), "670 MB");
        assert_eq!(readable(11_422_648), "11 MB");
        assert_eq!(readable(1_000), "1 MB");
    }
}
