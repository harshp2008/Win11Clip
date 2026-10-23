// Custom autostart manager for Linux that uses the wrapper script instead of the binary directly.
// This is necessary because tauri-plugin-autostart uses current_exe() which points to the binary,
// but we need to use the wrapper script that sets up the correct environment variables
// (TAURI_TRAY, etc.) for proper tray icon functionality.

use crate::app_id::APP_ID;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

const DESKTOP_ENTRY_TEMPLATE: &str = concat!(
    r#"[Desktop Entry]
Type=Application
Version=1.1
Name=Clipboard History
GenericName=Clipboard Manager
Comment=Windows 11-style Clipboard History Manager
Exec=sh -c 'sleep 5 && "EXEC_PATH" --background'
Icon=win11-clipboard-history
Terminal=false
Categories=Utility;
StartupNotify=false
X-GNOME-Autostart-enabled=true
StartupWMClass="#,
    crate::app_id!(),
    "\n"
);

/// The login auto-update entry. `spawn_at` is the command from `spawn_at_path::desktop_exec_in`
/// (the full path of `~/.local/bin/spawn-at` when present); the old fallbacks stay for machines
/// where that copy is missing.
fn spawn_at_autoupdate_entry(spawn_at: &str) -> String {
    format!(
        r#"[Desktop Entry]
Type=Application
Name=spawn-at Auto Update
Exec=sh -c 'sleep 10 && ({spawn_at} update --headless || ~/.local/bin/spawn-at update --headless || /usr/local/bin/spawn-at update --headless)'
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
Comment=Automatically check and install spawn-at updates on login
"#
    )
}

/// Get the path to the autostart directory
fn get_autostart_dir() -> Option<PathBuf> {
    dirs::config_dir().map(|p| p.join("autostart"))
}

/// Get the path to the autostart desktop file
fn get_autostart_file() -> Option<PathBuf> {
    get_autostart_dir().map(|p| p.join("win11-clipboard-history.desktop"))
}

/// Read the content of the autostart desktop file
fn read_autostart_content() -> Option<String> {
    get_autostart_file().and_then(|p| fs::read_to_string(p).ok())
}

/// Determines the correct executable path to use in the autostart entry.
/// Prioritizes the wrapper script over the direct binary.
fn get_exec_path() -> String {
    // Priority order for the wrapper/binary
    let possible_paths = [
        "/usr/bin/win11-clipboard-history", // Wrapper installed by .deb/.rpm
        "/usr/local/bin/win11-clipboard-history", // Manual install with PREFIX=/usr/local
        "/usr/bin/win11-clipboard-history-bin", // Direct binary (fallback)
        "/usr/local/bin/win11-clipboard-history-bin", // Direct binary local (fallback)
    ];

    for path in &possible_paths {
        if std::path::Path::new(path).exists() {
            return path.to_string();
        }
    }

    // Last resort: use current executable
    std::env::current_exe()
        .map(|p| p.display().to_string())
        .unwrap_or_else(|_| "win11-clipboard-history".to_string())
}

/// The autostart entry for the executable `exec_path`.
fn render_entry(exec_path: &str) -> String {
    DESKTOP_ENTRY_TEMPLATE.replace("EXEC_PATH", exec_path)
}

/// Writes the autostart entry for `exec_path` to `file`, replacing what is there.
fn write_autostart_file(file: &Path, exec_path: &str) -> Result<(), String> {
    let mut out =
        fs::File::create(file).map_err(|e| format!("Failed to create autostart file: {}", e))?;

    out.write_all(render_entry(exec_path).as_bytes())
        .map_err(|e| format!("Failed to write autostart file: {}", e))
}

/// Why `content` (an existing autostart entry) has to be rewritten; empty when it is current.
/// Rewriting produces `render_entry`, which gives no reasons, so a migration never repeats.
fn migration_reasons(content: &str) -> Vec<&'static str> {
    let exec_line = content
        .lines()
        .find(|line| line.trim_start().starts_with("Exec="));
    let mut reasons = Vec::new();

    // The Exec= line is using the old binary path directly
    if exec_line.is_some_and(|line| line.contains("win11-clipboard-history-bin")) {
        reasons.push("Migrating from old binary path to wrapper...");
    }
    // The Exec= line is missing the sleep (for multi-distro compatibility); sleep in exec is used
    // instead of X-GNOME-Autostart-Delay because it works everywhere
    if exec_line.is_some_and(|line| !line.contains("sleep")) {
        reasons.push("Adding sleep to exec for proper tray initialization...");
    }
    // The Exec= line is missing the --background flag
    if exec_line.is_some_and(|line| !line.contains("--background")) {
        reasons.push("Adding --background flag for minimized startup...");
    }
    // The deprecated X-GNOME-Autostart-Delay (should use sleep in exec instead)
    if content
        .lines()
        .any(|line| line.trim_start().starts_with("X-GNOME-Autostart-Delay="))
    {
        reasons.push(
            "Replacing X-GNOME-Autostart-Delay with sleep in exec (multi-distro compatibility)...",
        );
    }
    // The window class is not the app's own id (a missing line, or an older release's class)
    let wm_class = format!("StartupWMClass={APP_ID}");
    if !content.lines().any(|line| line.trim() == wm_class) {
        reasons.push("Setting StartupWMClass to the app id (the window class spawn-at matches)...");
    }
    reasons
}

/// Rewrites the entry at `file` when `migration_reasons` finds something to fix. Returns whether it did.
fn migrate_autostart_file(file: &Path, exec_path: &str) -> Result<bool, String> {
    let content = fs::read_to_string(file).unwrap_or_default();
    let reasons = migration_reasons(&content);
    if reasons.is_empty() {
        return Ok(false);
    }
    for reason in reasons {
        println!("[Autostart] {}", reason);
    }
    write_autostart_file(file, exec_path)?;
    Ok(true)
}

/// Enable autostart by creating a .desktop file in ~/.config/autostart/
#[tauri::command]
pub fn autostart_enable() -> Result<(), String> {
    let autostart_dir = get_autostart_dir().ok_or("Could not determine config directory")?;
    let autostart_file = get_autostart_file().ok_or("Could not determine autostart file path")?;

    // Create autostart directory if it doesn't exist
    fs::create_dir_all(&autostart_dir)
        .map_err(|e| format!("Failed to create autostart directory: {}", e))?;

    // Get the correct executable path (wrapper preferred)
    let exec_path = get_exec_path();

    write_autostart_file(&autostart_file, &exec_path)?;

    println!(
        "[Autostart] Enabled autostart with exec path: {}",
        exec_path
    );

    // Also ensure spawn-at auto-update on login entry is deployed
    let _ = ensure_spawn_at_autoupdate();

    Ok(())
}

/// Disable autostart by removing the .desktop file
#[tauri::command]
pub fn autostart_disable() -> Result<(), String> {
    let autostart_file = get_autostart_file().ok_or("Could not determine autostart file path")?;

    if autostart_file.exists() {
        fs::remove_file(&autostart_file)
            .map_err(|e| format!("Failed to remove autostart file: {}", e))?;
        println!("[Autostart] Disabled autostart");
    }

    Ok(())
}

/// Check if autostart is enabled
#[tauri::command]
pub fn autostart_is_enabled() -> Result<bool, String> {
    let autostart_file = get_autostart_file().ok_or("Could not determine autostart file path")?;

    if !autostart_file.exists() {
        return Ok(false);
    }

    // Check if the file has X-GNOME-Autostart-enabled=false
    let content = read_autostart_content().unwrap_or_default();

    // If the file exists and doesn't explicitly disable itself, it's enabled
    let is_disabled = content
        .lines()
        .any(|line| line.trim() == "X-GNOME-Autostart-enabled=false");

    Ok(!is_disabled)
}

/// Migrate from the old tauri-plugin-autostart entry to the new custom one
/// This fixes existing installations where the autostart points to the wrong binary
/// or is missing the startup delay for proper tray initialization
#[tauri::command]
pub fn autostart_migrate() -> Result<bool, String> {
    let autostart_file = get_autostart_file().ok_or("Could not determine autostart file path")?;

    if !autostart_file.exists() {
        return Ok(false); // Nothing to migrate
    }

    // Re-enable with correct path, sleep, --background and window class
    let migrated = migrate_autostart_file(&autostart_file, &get_exec_path())?;

    // Ensure spawn-at auto-update is configured even if no Win11Clip migration was needed
    let _ = ensure_spawn_at_autoupdate();

    Ok(migrated)
}

/// Ensures the spawn-at auto-update autostart desktop entry is present and properly configured.
/// This runs silently on user login to check GitHub for updates and automatically upgrades spawn-at.
pub fn ensure_spawn_at_autoupdate() -> Result<(), String> {
    let autostart_dir = match get_autostart_dir() {
        Some(dir) => dir,
        None => return Ok(()),
    };

    if !autostart_dir.exists() {
        fs::create_dir_all(&autostart_dir)
            .map_err(|e| format!("Failed to create autostart directory: {}", e))?;
    }

    // Update spawn-at-update-check.desktop if it was generated with only --check
    let check_file = autostart_dir.join("spawn-at-update-check.desktop");
    if check_file.exists() {
        if let Ok(content) = fs::read_to_string(&check_file) {
            if content.contains("--check") {
                let updated = content.replace(" update --check --headless", " update --headless");
                let _ = fs::write(&check_file, updated);
            }
        }
    }

    // Write dedicated spawn-at-autoupdate.desktop
    let autoupdate_file = autostart_dir.join("spawn-at-autoupdate.desktop");
    let entry = spawn_at_autoupdate_entry(&crate::spawn_at_path::desktop_exec());
    let needs_write = match fs::read_to_string(&autoupdate_file) {
        Ok(c) => c.trim() != entry.trim(),
        Err(_) => true,
    };

    if needs_write {
        fs::write(&autoupdate_file, &entry)
            .map_err(|e| format!("Failed to write spawn-at autoupdate file: {}", e))?;
        println!(
            "[Autostart] Configured spawn-at auto-update on login at {}",
            autoupdate_file.display()
        );
    }

    Ok(())
}

#[cfg(test)]
mod spawn_at_entry_tests {
    use super::spawn_at_autoupdate_entry;

    #[test]
    fn bare_name_keeps_the_previous_entry_text() {
        let e = spawn_at_autoupdate_entry("spawn-at");
        assert!(e.contains("Exec=sh -c 'sleep 10 && (spawn-at update --headless || ~/.local/bin/spawn-at update --headless || /usr/local/bin/spawn-at update --headless)'\n"));
        assert!(e.starts_with("[Desktop Entry]\nType=Application\n"));
    }

    #[test]
    fn full_path_goes_first() {
        let e = spawn_at_autoupdate_entry("/home/u/.local/bin/spawn-at");
        assert!(e.contains(
            "&& (/home/u/.local/bin/spawn-at update --headless || ~/.local/bin/spawn-at"
        ));
    }
}

#[cfg(test)]
mod wm_class_tests {
    use super::*;
    use crate::app_id::{APP_ID, LEGACY_APP_IDS};

    struct TempDir(PathBuf);

    impl TempDir {
        fn new() -> Self {
            let path =
                std::env::temp_dir().join(format!("test_autostart_{}", uuid::Uuid::new_v4()));
            fs::create_dir_all(&path).unwrap();
            Self(path)
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn template_carries_the_app_id_as_window_class() {
        let entry = render_entry("/usr/bin/win11-clipboard-history");
        assert!(entry
            .lines()
            .any(|l| l == format!("StartupWMClass={APP_ID}")));
        assert!(entry.ends_with('\n'));
        for old in LEGACY_APP_IDS {
            assert!(!entry.contains(&format!("StartupWMClass={old}")));
        }
    }

    #[test]
    fn a_fresh_entry_needs_no_migration() {
        assert!(migration_reasons(&render_entry("/usr/bin/win11-clipboard-history")).is_empty());
    }

    #[test]
    fn entries_with_an_old_or_no_class_are_migrated_once_and_then_left_alone() {
        let tmp = TempDir::new();
        for old_class in LEGACY_APP_IDS {
            let file = tmp.0.join("win11-clipboard-history.desktop");
            let old = render_entry("/usr/bin/win11-clipboard-history").replace(APP_ID, old_class);
            fs::write(&file, &old).unwrap();

            // First run rewrites it ...
            assert!(migrate_autostart_file(&file, "/usr/bin/win11-clipboard-history").unwrap());
            let migrated = fs::read_to_string(&file).unwrap();
            assert!(migrated.contains(&format!("StartupWMClass={APP_ID}\n")));
            assert!(!migrated.contains(&format!("StartupWMClass={old_class}")));
            assert_eq!(migrated, render_entry("/usr/bin/win11-clipboard-history"));

            // ... and the next ones do nothing (no loop).
            assert!(!migrate_autostart_file(&file, "/usr/bin/win11-clipboard-history").unwrap());
            assert!(!migrate_autostart_file(&file, "/usr/bin/win11-clipboard-history").unwrap());
            assert_eq!(fs::read_to_string(&file).unwrap(), migrated);
        }

        // An entry with no StartupWMClass line at all gets one.
        let file = tmp.0.join("none.desktop");
        let no_class: String = render_entry("/usr/bin/x")
            .lines()
            .filter(|l| !l.starts_with("StartupWMClass="))
            .map(|l| format!("{l}\n"))
            .collect();
        fs::write(&file, no_class).unwrap();
        assert!(migrate_autostart_file(&file, "/usr/bin/x").unwrap());
        assert!(!migrate_autostart_file(&file, "/usr/bin/x").unwrap());
    }
}
