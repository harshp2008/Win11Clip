//! GIF Manager
//! Handles downloading GIFs and preparing them for clipboard paste.
//!
//! IMPORTANT: This module handles clipboard setting via in-memory arboard on Wayland
//! and xclip on X11 to ensure GIFs are pasted as files (text/uri-list) rather than raw bytes or text.
//! This is required for rich media pasting in apps like Discord/Chrome on Linux.

use crate::session;
use arboard::Clipboard;
use std::collections::hash_map::DefaultHasher;
use std::fs;
use std::hash::{Hash, Hasher};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Duration;

// --- Constants ---

const APP_CACHE_DIR: &str = concat!(crate::command_name!(), "/gifs");
const MIME_URI_LIST: &str = "text/uri-list";
const DOWNLOAD_TIMEOUT: u64 = 10;

// --- Cache Management ---

struct GifCache;

impl GifCache {
    /// Get (and create if missing) the cache directory.
    fn get_dir() -> Result<PathBuf, String> {
        let cache_dir = dirs::cache_dir()
            .ok_or("Failed to resolve system cache directory")?
            .join(APP_CACHE_DIR);

        if !cache_dir.exists() {
            fs::create_dir_all(&cache_dir)
                .map_err(|e| format!("Failed to create cache dir: {}", e))?;
        }

        Ok(cache_dir)
    }

    /// Generate a file path based on the URL hash.
    fn get_path_for_url(url: &str) -> Result<PathBuf, String> {
        let mut hasher = DefaultHasher::new();
        url.hash(&mut hasher);
        let hash = hasher.finish();

        Ok(Self::get_dir()?.join(format!("{}.gif", hash)))
    }
}

// --- Downloader ---

struct Downloader;

impl Downloader {
    /// Downloads a URL to a local file.
    pub fn download(url: &str, destination: &Path) -> Result<(), String> {
        eprintln!("[GifManager] Downloading: {}", url);

        let client = reqwest::blocking::Client::builder()
            .timeout(Duration::from_secs(DOWNLOAD_TIMEOUT))
            .build()
            .map_err(|e| format!("Client build error: {}", e))?;

        let response = client
            .get(url)
            .send()
            .map_err(|e| format!("Network request failed: {}", e))?;

        if !response.status().is_success() {
            return Err(format!("HTTP Error: {}", response.status()));
        }

        let bytes = response
            .bytes()
            .map_err(|e| format!("Failed to read bytes: {}", e))?;

        let mut file =
            fs::File::create(destination).map_err(|e| format!("File creation failed: {}", e))?;

        file.write_all(&bytes)
            .map_err(|e| format!("File write failed: {}", e))?;

        eprintln!(
            "[GifManager] Saved {} bytes to {:?}",
            bytes.len(),
            destination
        );
        Ok(())
    }
}

// --- Clipboard Logic (The Critical Part) ---

struct ClipboardHandler;

impl ClipboardHandler {
    /// Constructs the file URI string (file:///path/to/file).
    fn make_file_uri(path: &Path) -> String {
        format!("file://{}\n", path.to_string_lossy())
    }

    /// Sets clipboard in-memory using `arboard` on Wayland.
    ///
    /// Avoids spawning external CLI subprocesses, which trigger GNOME Mutter's
    /// Focus Stealing Prevention and "wl-clipboard is ready by unknown" notifications.
    fn copy_wayland(path: &Path) -> Result<(), String> {
        let uri = Self::make_file_uri(path);
        let uri_trimmed = uri.trim();

        eprintln!(
            "[GifManager] Setting in-memory clipboard text/URI to {}",
            uri_trimmed
        );

        let mut clipboard =
            Clipboard::new().map_err(|e| format!("Failed to initialize clipboard: {}", e))?;

        clipboard
            .set_text(uri_trimmed)
            .map_err(|e| format!("Failed to set clipboard text: {}", e))?;

        #[cfg(target_os = "linux")]
        {
            use arboard::{LinuxClipboardKind, SetExtLinux};
            let _ = clipboard
                .set()
                .clipboard(LinuxClipboardKind::Primary)
                .text(uri_trimmed);
        }

        Ok(())
    }

    /// Uses `xclip` to set clipboard on X11.
    ///
    /// CRITICAL: We spawn xclip and detach the thread so it persists.
    fn copy_x11(path: &Path) -> Result<(), String> {
        let uri = Self::make_file_uri(path);
        let display = std::env::var("DISPLAY").map_err(|_| "DISPLAY not set".to_string())?;

        eprintln!("[GifManager] Executing xclip ({})", MIME_URI_LIST);

        let mut child = Command::new("xclip")
            .env("DISPLAY", display)
            .args([
                "-selection",
                "clipboard",
                "-t",
                MIME_URI_LIST,
                "-loops",
                "0",
            ])
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|e| format!("Failed to spawn xclip: {}", e))?;

        if let Some(mut stdin) = child.stdin.take() {
            stdin
                .write_all(uri.as_bytes())
                .map_err(|e| format!("Pipe write error: {}", e))?;
        }

        // Detach to allow xclip to serve requests indefinitely
        std::thread::spawn(move || {
            let _ = child.wait();
        });

        Ok(())
    }

    /// Fallback: Just put the text URL on the clipboard.
    fn copy_url_fallback(url: &str) -> Result<(), String> {
        eprintln!("[GifManager] Fallback: Setting clipboard to URL text");
        Clipboard::new()
            .map_err(|e| e.to_string())?
            .set_text(url)
            .map_err(|e| e.to_string())
    }
}

// --- Public API ---

/// Downloads a GIF from the URL and returns the local file path.
pub fn download_gif_to_file(url: &str) -> Result<PathBuf, String> {
    let target_path = GifCache::get_path_for_url(url)?;

    // Check if we already have it to avoid redownload (optional optimization,
    // but the original code overwrote every time. I'll maintain overwrite
    // to ensure validity, but using `Downloader` keeps it clean).
    Downloader::download(url, &target_path)?;

    Ok(target_path)
}

/// Downloads GIF and sets clipboard.
/// Returns Ok(Some(uri)) if successful (for history marking),
/// Ok(Some(url)) if fallback used,
/// Err if everything failed.
pub fn paste_gif_to_clipboard_with_uri(url: &str) -> Result<Option<String>, String> {
    let is_wayland = session::is_wayland();
    eprintln!(
        "[GifManager] Mode: {}",
        if is_wayland { "Wayland" } else { "X11" }
    );

    // 1. Attempt Download
    let gif_path = match download_gif_to_file(url) {
        Ok(path) => path,
        Err(e) => {
            eprintln!("[GifManager] Download failed ({}), using URL fallback.", e);
            ClipboardHandler::copy_url_fallback(url)?;
            return Ok(Some(url.to_string()));
        }
    };

    // 2. Attempt Copy
    let copy_result = if is_wayland {
        ClipboardHandler::copy_wayland(&gif_path).or_else(|e| {
            eprintln!("[GifManager] Wayland copy failed ({}), trying X11...", e);
            ClipboardHandler::copy_x11(&gif_path)
        })
    } else {
        ClipboardHandler::copy_x11(&gif_path)
    };

    // 3. Handle Result
    match copy_result {
        Ok(_) => {
            let uri = format!("file://{}", gif_path.to_string_lossy());
            Ok(Some(uri))
        }
        Err(e) => {
            eprintln!("[GifManager] File copy failed ({}), using URL fallback.", e);
            ClipboardHandler::copy_url_fallback(url)?;
            Ok(Some(url.to_string()))
        }
    }
}

/// Convenience wrapper for cases where the URI return isn't needed.
pub fn paste_gif_to_clipboard(url: &str) -> Result<(), String> {
    paste_gif_to_clipboard_with_uri(url).map(|_| ())
}

/// Helper for external use if needed (legacy support)
pub fn copy_url_to_clipboard(url: &str) -> Result<(), String> {
    ClipboardHandler::copy_url_fallback(url)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_cache_resolution() {
        let dir = GifCache::get_dir();
        assert!(dir.is_ok());
        assert!(dir.unwrap().ends_with("win11clip/gifs"));
    }

    #[test]
    fn test_path_generation() {
        let path = GifCache::get_path_for_url("http://example.com/cat.gif");
        assert!(path.is_ok());
        assert!(path.unwrap().extension().unwrap() == "gif");
    }
}
