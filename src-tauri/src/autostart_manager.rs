// Custom autostart manager for Linux that uses the wrapper script instead of the binary directly.
// This is necessary because tauri-plugin-autostart uses current_exe() which points to the binary,
// but we need to use the wrapper script that sets up the correct environment variables
// (TAURI_TRAY, etc.) for proper tray icon functionality.

use crate::app_id::{APP_ID, BINARY_NAME, COMMAND_NAME, LEGACY_BINARY_NAME, LEGACY_COMMAND_NAME};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

const DESKTOP_ENTRY_TEMPLATE: &str = concat!(
    "[Desktop Entry]\nType=Application\nVersion=1.1\nName=",
    crate::display_name!(),
    "\nGenericName=Clipboard Manager\nComment=Windows 11-style Clipboard History Manager\n",
    r#"Exec=sh -c 'sleep 5 && "EXEC_PATH" --background'"#,
    "\nIcon=",
    crate::app_id!(),
    "\nTerminal=false\nCategories=Utility;\nStartupNotify=false\nX-GNOME-Autostart-enabled=true\nStartupWMClass=",
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

/// The autostart entry in `dir`. It is named after the app id, like the menu entry.
fn autostart_file_in(dir: &Path) -> PathBuf {
    dir.join(format!("{APP_ID}.desktop"))
}

/// The autostart entry an install from before the rename wrote into `dir`.
fn legacy_autostart_file_in(dir: &Path) -> PathBuf {
    dir.join(format!("{LEGACY_COMMAND_NAME}.desktop"))
}

/// Get the path to the autostart desktop file
fn get_autostart_file() -> Option<PathBuf> {
    get_autostart_dir().map(|p| autostart_file_in(&p))
}

/// Get the path to the autostart desktop file of the old name
fn get_legacy_autostart_file() -> Option<PathBuf> {
    get_autostart_dir().map(|p| legacy_autostart_file_in(&p))
}

/// Whether an autostart entry's content switches itself off.
fn is_switched_off(content: &str) -> bool {
    content
        .lines()
        .any(|line| line.trim() == "X-GNOME-Autostart-enabled=false")
}

/// Determines the correct executable path to use in the autostart entry.
/// Prioritizes the wrapper script over the direct binary.
fn get_exec_path() -> String {
    // Priority order for the wrapper/binary
    let possible_paths = [
        format!("/usr/bin/{COMMAND_NAME}"), // Wrapper installed by .deb/.rpm
        format!("/usr/local/bin/{COMMAND_NAME}"), // Manual install with PREFIX=/usr/local
        format!("/usr/bin/{BINARY_NAME}"),  // Direct binary (fallback)
        format!("/usr/local/bin/{BINARY_NAME}"), // Direct binary local (fallback)
    ];

    for path in &possible_paths {
        if std::path::Path::new(path).exists() {
            return path.to_string();
        }
    }

    // Last resort: use current executable
    std::env::current_exe()
        .map(|p| p.display().to_string())
        .unwrap_or_else(|_| COMMAND_NAME.to_string())
}

/// The autostart entry for the executable `exec_path`.
fn render_entry(exec_path: &str) -> String {
    DESKTOP_ENTRY_TEMPLATE.replace("EXEC_PATH", exec_path)
}

/// Writes the autostart entry for `exec_path` to `file`, replacing what is there. `enabled` false
/// writes the entry switched off, which is how an entry the user had switched off is carried over.
fn write_autostart_file(file: &Path, exec_path: &str, enabled: bool) -> Result<(), String> {
    let mut entry = render_entry(exec_path);
    if !enabled {
        entry = entry.replace(
            "X-GNOME-Autostart-enabled=true",
            "X-GNOME-Autostart-enabled=false",
        );
    }
    let mut out =
        fs::File::create(file).map_err(|e| format!("Failed to create autostart file: {}", e))?;

    out.write_all(entry.as_bytes())
        .map_err(|e| format!("Failed to write autostart file: {}", e))
}

/// Why `content` (an existing autostart entry) has to be rewritten; empty when it is current.
/// Rewriting produces `render_entry`, which gives no reasons, so a migration never repeats.
fn migration_reasons(content: &str) -> Vec<&'static str> {
    let exec_line = content
        .lines()
        .find(|line| line.trim_start().starts_with("Exec="));
    let mut reasons = Vec::new();

    // The Exec= line still runs the command or the binary of the old name
    if exec_line
        .is_some_and(|line| line.contains(LEGACY_COMMAND_NAME) || line.contains(LEGACY_BINARY_NAME))
    {
        reasons.push("Moving the entry from the old command to the Win11Clip one...");
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
    write_autostart_file(file, exec_path, !is_switched_off(&content))?;
    Ok(true)
}

/// Brings the autostart entries in `dir` up to date and returns whether it changed anything.
///
/// - An entry of the old name (`win11-clipboard-history.desktop`) with no entry of the new name is
///   carried over: the new entry is written first (switched off if the old one was), and only then
///   is the old file removed.
/// - An old entry next to a new one is removed, so the app does not start twice at login.
/// - An existing new entry is rewritten only when `migration_reasons` finds something wrong.
///
/// Running it again changes nothing.
fn migrate_autostart_dir(dir: &Path, exec_path: &str) -> Result<bool, String> {
    let new_file = autostart_file_in(dir);
    let old_file = legacy_autostart_file_in(dir);
    let mut changed = false;

    if new_file.exists() {
        changed |= migrate_autostart_file(&new_file, exec_path)?;
    } else if old_file.exists() {
        let old = fs::read_to_string(&old_file).unwrap_or_default();
        write_autostart_file(&new_file, exec_path, !is_switched_off(&old))?;
        println!(
            "[Autostart] Carried the autostart entry of the old name over to {}",
            new_file.display()
        );
        changed = true;
    }

    // Only once the new entry is in place.
    if old_file.exists() && new_file.is_file() {
        fs::remove_file(&old_file)
            .map_err(|e| format!("Failed to remove the old autostart entry: {}", e))?;
        println!(
            "[Autostart] Removed the old autostart entry {}",
            old_file.display()
        );
        changed = true;
    }
    Ok(changed)
}

/// Writes the enabled autostart entry for `exec_path` into `dir`, creating `dir` if needed.
fn enable_in(dir: &Path, exec_path: &str) -> Result<(), String> {
    fs::create_dir_all(dir).map_err(|e| format!("Failed to create autostart directory: {}", e))?;

    write_autostart_file(&autostart_file_in(dir), exec_path, true)?;
    // An entry of the old name next to the new one would start the app twice.
    let _ = fs::remove_file(legacy_autostart_file_in(dir));
    Ok(())
}

/// Creates the autostart entry in `dir` when `wanted` and no entry (of either name) exists. An
/// entry that is there is left alone, switched off or not, and so is a missing one when not
/// `wanted`. Returns whether it created the entry.
fn ensure_in(dir: &Path, exec_path: &str, wanted: bool) -> Result<bool, String> {
    if !wanted || autostart_file_in(dir).exists() || legacy_autostart_file_in(dir).exists() {
        return Ok(false);
    }
    enable_in(dir, exec_path)?;
    Ok(true)
}

/// On app start: brings back a missing autostart entry unless the user switched "Start at login"
/// off (`wanted` false). Returns whether it created the entry.
pub fn ensure_autostart(wanted: bool) -> Result<bool, String> {
    let autostart_dir = get_autostart_dir().ok_or("Could not determine config directory")?;
    let created = ensure_in(&autostart_dir, &get_exec_path(), wanted)?;
    if created {
        println!("[Autostart] The autostart entry was missing; created it");
        let _ = ensure_spawn_at_autoupdate();
    }
    Ok(created)
}

/// Enable autostart by creating a .desktop file in ~/.config/autostart/
#[tauri::command]
pub fn autostart_enable() -> Result<(), String> {
    let autostart_dir = get_autostart_dir().ok_or("Could not determine config directory")?;

    // Get the correct executable path (wrapper preferred)
    let exec_path = get_exec_path();

    enable_in(&autostart_dir, &exec_path)?;

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

    // Both names: disabling has to hold whichever one a previous install wrote.
    let mut removed = false;
    for file in [Some(autostart_file), get_legacy_autostart_file()]
        .into_iter()
        .flatten()
    {
        if file.exists() {
            fs::remove_file(&file)
                .map_err(|e| format!("Failed to remove autostart file: {}", e))?;
            removed = true;
        }
    }
    if removed {
        println!("[Autostart] Disabled autostart");
    }

    Ok(())
}

/// Check if autostart is enabled
#[tauri::command]
pub fn autostart_is_enabled() -> Result<bool, String> {
    let autostart_file = get_autostart_file().ok_or("Could not determine autostart file path")?;
    let legacy_file =
        get_legacy_autostart_file().ok_or("Could not determine autostart file path")?;

    // The entry of the new name wins; one of the old name still counts until it is carried over.
    let file = if autostart_file.exists() {
        autostart_file
    } else if legacy_file.exists() {
        legacy_file
    } else {
        return Ok(false);
    };

    // If the file exists and doesn't explicitly disable itself, it's enabled
    let content = fs::read_to_string(file).unwrap_or_default();
    Ok(!is_switched_off(&content))
}

/// Migrate from the old tauri-plugin-autostart entry to the new custom one
/// This fixes existing installations where the autostart points to the wrong binary
/// or is missing the startup delay for proper tray initialization
#[tauri::command]
pub fn autostart_migrate() -> Result<bool, String> {
    let autostart_dir = get_autostart_dir().ok_or("Could not determine autostart file path")?;

    // The entry of the old name is carried over to the new one; an existing entry gets the correct
    // path, sleep, --background and window class. Without either there is nothing to migrate.
    let migrated = migrate_autostart_dir(&autostart_dir, &get_exec_path())?;

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
    use crate::app_id::{DISPLAY_NAME, LEGACY_APP_IDS};

    const EXEC: &str = "/usr/bin/win11clip";
    const OLD_EXEC: &str = "/usr/bin/win11-clipboard-history";

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

    /// The entry the previous release wrote: old name, old command, and the app id (or an older
    /// class) as window class.
    fn old_entry(class: &str) -> String {
        format!(
            "[Desktop Entry]\nType=Application\nVersion=1.1\nName=Clipboard History\nGenericName=Clipboard Manager\nComment=Windows 11-style Clipboard History Manager\nExec=sh -c 'sleep 5 && \"{OLD_EXEC}\" --background'\nIcon=win11-clipboard-history\nTerminal=false\nCategories=Utility;\nStartupNotify=false\nX-GNOME-Autostart-enabled=true\nStartupWMClass={class}\n"
        )
    }

    #[test]
    fn template_carries_the_new_name_icon_and_window_class() {
        let entry = render_entry(EXEC);
        assert!(entry.lines().any(|l| l == format!("Name={DISPLAY_NAME}")));
        assert!(entry.lines().any(|l| l == format!("Icon={APP_ID}")));
        assert!(entry
            .lines()
            .any(|l| l == format!("StartupWMClass={APP_ID}")));
        assert!(entry.contains(&format!("\"{EXEC}\" --background")));
        assert!(entry.ends_with('\n'));
        for old in LEGACY_APP_IDS {
            assert!(!entry.contains(&format!("StartupWMClass={old}")));
        }
        assert!(!entry.contains("Clipboard History\nGeneric"));
        assert!(!entry.contains(LEGACY_COMMAND_NAME));
    }

    #[test]
    fn the_entry_is_named_after_the_app_id_and_the_old_one_after_the_old_command() {
        let dir = Path::new("/c/autostart");
        assert_eq!(
            autostart_file_in(dir),
            Path::new("/c/autostart/io.github.harshp2008.win11clip.desktop")
        );
        assert_eq!(
            legacy_autostart_file_in(dir),
            Path::new("/c/autostart/win11-clipboard-history.desktop")
        );
    }

    #[test]
    fn a_fresh_entry_needs_no_migration() {
        assert!(migration_reasons(&render_entry(EXEC)).is_empty());
    }

    #[test]
    fn an_entry_that_still_runs_the_old_command_is_rewritten_once() {
        let tmp = TempDir::new();
        let file = autostart_file_in(&tmp.0);
        for exec in [
            OLD_EXEC,
            "/usr/local/bin/win11-clipboard-history",
            "/usr/bin/win11-clipboard-history-bin",
        ] {
            fs::write(&file, render_entry(exec)).unwrap();
            assert!(migrate_autostart_file(&file, EXEC).unwrap());
            assert_eq!(fs::read_to_string(&file).unwrap(), render_entry(EXEC));
            assert!(!migrate_autostart_file(&file, EXEC).unwrap());
        }
    }

    #[test]
    fn entries_with_an_old_or_no_class_are_migrated_once_and_then_left_alone() {
        let tmp = TempDir::new();
        for old_class in LEGACY_APP_IDS {
            let file = tmp.0.join("entry.desktop");
            let old = render_entry(EXEC).replace(APP_ID, old_class);
            fs::write(&file, &old).unwrap();

            // First run rewrites it ...
            assert!(migrate_autostart_file(&file, EXEC).unwrap());
            let migrated = fs::read_to_string(&file).unwrap();
            assert!(migrated.contains(&format!("StartupWMClass={APP_ID}\n")));
            assert!(!migrated.contains(&format!("StartupWMClass={old_class}")));
            assert_eq!(migrated, render_entry(EXEC));

            // ... and the next ones do nothing (no loop).
            assert!(!migrate_autostart_file(&file, EXEC).unwrap());
            assert!(!migrate_autostart_file(&file, EXEC).unwrap());
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

    #[test]
    fn the_old_named_entry_is_carried_over_and_then_removed() {
        let tmp = TempDir::new();
        let old = legacy_autostart_file_in(&tmp.0);
        let new = autostart_file_in(&tmp.0);
        fs::write(&old, old_entry(APP_ID)).unwrap();

        assert!(migrate_autostart_dir(&tmp.0, EXEC).unwrap());
        assert_eq!(fs::read_to_string(&new).unwrap(), render_entry(EXEC));
        assert!(!old.exists());

        // Idempotent: the second start changes nothing and the old name does not come back.
        assert!(!migrate_autostart_dir(&tmp.0, EXEC).unwrap());
        assert!(!migrate_autostart_dir(&tmp.0, EXEC).unwrap());
        assert_eq!(fs::read_to_string(&new).unwrap(), render_entry(EXEC));
        assert!(!old.exists());
    }

    #[test]
    fn an_old_entry_the_user_switched_off_stays_off() {
        let tmp = TempDir::new();
        let off = old_entry(APP_ID).replace(
            "X-GNOME-Autostart-enabled=true",
            "X-GNOME-Autostart-enabled=false",
        );
        fs::write(legacy_autostart_file_in(&tmp.0), off).unwrap();

        migrate_autostart_dir(&tmp.0, EXEC).unwrap();
        let carried = fs::read_to_string(autostart_file_in(&tmp.0)).unwrap();
        assert!(is_switched_off(&carried));
        assert!(carried.contains(&format!("\"{EXEC}\" --background")));
        // A later migration of the switched-off entry keeps it off.
        assert!(!migrate_autostart_dir(&tmp.0, EXEC).unwrap());
    }

    #[test]
    fn an_old_entry_next_to_a_current_one_is_removed_so_the_app_starts_once() {
        let tmp = TempDir::new();
        fs::write(autostart_file_in(&tmp.0), render_entry(EXEC)).unwrap();
        fs::write(legacy_autostart_file_in(&tmp.0), old_entry(APP_ID)).unwrap();

        assert!(migrate_autostart_dir(&tmp.0, EXEC).unwrap());
        assert!(!legacy_autostart_file_in(&tmp.0).exists());
        assert_eq!(
            fs::read_to_string(autostart_file_in(&tmp.0)).unwrap(),
            render_entry(EXEC)
        );
    }

    #[test]
    fn the_old_entry_is_kept_when_the_new_one_cannot_be_written() {
        let tmp = TempDir::new();
        let old = legacy_autostart_file_in(&tmp.0);
        fs::write(&old, old_entry(APP_ID)).unwrap();
        // A directory where the new entry should go: writing it fails.
        fs::create_dir(autostart_file_in(&tmp.0)).unwrap();

        assert!(migrate_autostart_dir(&tmp.0, EXEC).is_err());
        assert!(
            old.exists(),
            "the old entry must survive a failed migration"
        );
    }

    #[test]
    fn nothing_to_migrate_in_an_empty_directory() {
        let tmp = TempDir::new();
        assert!(!migrate_autostart_dir(&tmp.0, EXEC).unwrap());
        assert!(!autostart_file_in(&tmp.0).exists());
    }

    #[test]
    fn startup_creates_a_missing_entry_when_wanted() {
        // "Never chosen" and "on" both reach ensure_in as wanted.
        let tmp = TempDir::new();
        let dir = tmp.0.join("autostart"); // the directory itself is missing too

        assert!(ensure_in(&dir, EXEC, true).unwrap());
        let created = fs::read_to_string(autostart_file_in(&dir)).unwrap();
        assert_eq!(created, render_entry(EXEC));
        assert!(created.contains(&format!("sleep 5 && \"{EXEC}\" --background")));

        // Idempotent: the next start finds the entry and does nothing.
        assert!(!ensure_in(&dir, EXEC, true).unwrap());
        assert_eq!(
            fs::read_to_string(autostart_file_in(&dir)).unwrap(),
            created
        );
    }

    #[test]
    fn startup_does_nothing_when_the_user_switched_it_off() {
        let tmp = TempDir::new();
        assert!(!ensure_in(&tmp.0, EXEC, false).unwrap());
        assert!(!autostart_file_in(&tmp.0).exists());
    }

    #[test]
    fn startup_leaves_an_existing_entry_alone_whatever_the_choice() {
        let tmp = TempDir::new();
        let file = autostart_file_in(&tmp.0);
        // An entry switched off from outside (GNOME Tweaks) and one with other content.
        let switched_off = render_entry(EXEC).replace(
            "X-GNOME-Autostart-enabled=true",
            "X-GNOME-Autostart-enabled=false",
        );
        for content in [switched_off, "custom content\n".to_string()] {
            for wanted in [true, false] {
                fs::write(&file, &content).unwrap();
                assert!(!ensure_in(&tmp.0, EXEC, wanted).unwrap());
                assert_eq!(fs::read_to_string(&file).unwrap(), content);
            }
        }
    }

    #[test]
    fn startup_does_not_add_a_second_entry_next_to_one_of_the_old_name() {
        let tmp = TempDir::new();
        let old = legacy_autostart_file_in(&tmp.0);
        fs::write(&old, old_entry(APP_ID)).unwrap();

        assert!(!ensure_in(&tmp.0, EXEC, true).unwrap());
        assert!(!autostart_file_in(&tmp.0).exists());
        assert!(old.exists());
    }

    #[test]
    fn the_exec_candidates_use_the_new_command_and_binary() {
        // get_exec_path() lists /usr/bin/<command> first; the names come from app_id.
        assert_eq!(COMMAND_NAME, "win11clip");
        assert_eq!(BINARY_NAME, "win11clip-bin");
    }
}
