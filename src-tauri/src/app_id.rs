//! The app's own identity: what people see, what they type, and what the system calls it.
//!
//! `APP_ID` is the Wayland app id (X11 `WM_CLASS`) of every window the app opens, and the Tauri
//! `identifier`. `spawn-at` finds the popup it has to place by this class, so each shortcut passes
//! it with `-c`, and the `.desktop` files and the autostart entry carry it as `StartupWMClass`.
//!
//! `DISPLAY_NAME`, `COMMAND_NAME` and `BINARY_NAME` are the product name, the launcher on the PATH
//! and the real executable. The `LEGACY_*` constants are the names the app had before it was called
//! Win11Clip (they are the upstream project's names); they stay so that old installs, shortcuts,
//! autostart entries and data folders are recognised and migrated, never left behind.
//!
//! Rust code uses the constants. Places that cannot import them hold a literal copy that a test
//! checks: `tauri.conf.json`, `Cargo.toml`, the bundled `.desktop` files, the wrapper, the scripts,
//! the Makefile, the AUR files and the Setup Wizard text (see `tests/naming.rs`).

use std::fs;
use std::io;
use std::path::Path;

/// The one definition of the id, as a macro so that `concat!` can build constant command strings.
#[macro_export]
macro_rules! app_id {
    () => {
        "io.github.harshp2008.win11clip"
    };
}

/// The product name, as people see it (window titles, tray tooltip, desktop entries, notifications).
#[macro_export]
macro_rules! display_name {
    () => {
        "Win11Clip"
    };
}

/// The launcher on the PATH. It is also the package name and the data, config and cache folder name.
#[macro_export]
macro_rules! command_name {
    () => {
        "win11clip"
    };
}

/// This app's id. See the module docs.
pub const APP_ID: &str = app_id!();

/// The product name, as people see it.
pub const DISPLAY_NAME: &str = display_name!();

/// The launcher on the PATH (a wrapper script that sets up the environment, then runs the binary).
pub const COMMAND_NAME: &str = command_name!();

/// The real executable the launcher runs.
pub const BINARY_NAME: &str = concat!(command_name!(), "-bin");

/// The folder name under the data, config and cache directories.
pub const DATA_DIR_NAME: &str = command_name!();

/// What the app was called before it was Win11Clip: the launcher, the executable, the data folders
/// and the window title. Nothing writes these any more; they are only recognised and migrated.
pub const LEGACY_COMMAND_NAME: &str = "win11-clipboard-history";
pub const LEGACY_BINARY_NAME: &str = "win11-clipboard-history-bin";
pub const LEGACY_DATA_DIR_NAME: &str = "win11-clipboard-history";
pub const LEGACY_DISPLAY_NAME: &str = "Clipboard History";

/// The id this fork inherited from the upstream project, and was released with until it got its own.
pub const UPSTREAM_APP_ID: &str = "dev.gustavosett.clipboard-history";

/// Window classes older releases used. Entries that carry one of these (autostart entries, dock
/// states, shortcuts) are Win11Clip's own and get moved to `APP_ID`.
pub const LEGACY_APP_IDS: &[&str] = &[UPSTREAM_APP_ID, LEGACY_COMMAND_NAME];

/// Copies the directory `from` to `to`, creating `to`. Symbolic links are skipped, and so are the
/// entries directly inside `from` whose names are listed in `skip`.
fn copy_dir_all(from: &Path, to: &Path, skip: &[&str]) -> io::Result<()> {
    fs::create_dir_all(to)?;
    for entry in fs::read_dir(from)? {
        let entry = entry?;
        if skip.iter().any(|name| entry.file_name() == *name) {
            continue;
        }
        let file_type = entry.file_type()?;
        let target = to.join(entry.file_name());
        if file_type.is_dir() {
            copy_dir_all(&entry.path(), &target, &[])?;
        } else if file_type.is_file() {
            fs::copy(entry.path(), &target)?;
        }
    }
    Ok(())
}

/// Copies the folder `old_dir` to `new_dir`, once: only when `new_dir` does not exist yet and
/// `old_dir` does. `old_dir` is never moved or deleted. Returns whether a copy was made.
///
/// The copy goes to a temporary sibling first and is renamed into place, so a second instance that
/// starts meanwhile never sees a half-copied folder.
pub fn copy_dir_once(old_dir: &Path, new_dir: &Path, skip: &[&str]) -> io::Result<bool> {
    if new_dir.exists() || !old_dir.is_dir() {
        return Ok(false);
    }
    let Some(parent) = new_dir.parent() else {
        return Ok(false);
    };
    fs::create_dir_all(parent)?;

    let staging = parent.join(format!(
        ".{}.migrating-{}",
        new_dir.file_name().unwrap_or_default().to_string_lossy(),
        std::process::id()
    ));
    let _ = fs::remove_dir_all(&staging);
    if let Err(e) = copy_dir_all(old_dir, &staging, skip) {
        let _ = fs::remove_dir_all(&staging);
        return Err(e);
    }
    match fs::rename(&staging, new_dir) {
        Ok(()) => Ok(true),
        Err(_) if new_dir.exists() => {
            // Another instance finished first.
            let _ = fs::remove_dir_all(&staging);
            Ok(false)
        }
        Err(e) => {
            let _ = fs::remove_dir_all(&staging);
            Err(e)
        }
    }
}

/// On Linux Tauri keeps the webview's storage (localStorage, caches) in `<data dir>/<identifier>`.
/// The identifier changed, so this copies the old folder to the new one once, when the new one does
/// not exist yet. The old folder is never moved or deleted. Returns whether a copy was made.
pub fn migrate_legacy_webview_data_in(data_local_dir: &Path) -> io::Result<bool> {
    copy_dir_once(
        &data_local_dir.join(UPSTREAM_APP_ID),
        &data_local_dir.join(APP_ID),
        &[],
    )
}

/// Runs [`migrate_legacy_webview_data_in`] for the current user. Call it before the webview starts.
pub fn migrate_legacy_webview_data() {
    let Some(base) = dirs::data_local_dir() else {
        return;
    };
    match migrate_legacy_webview_data_in(&base) {
        Ok(true) => println!(
            "[Startup] Copied webview data from {} to {} (the old folder is left in place)",
            base.join(UPSTREAM_APP_ID).display(),
            base.join(APP_ID).display()
        ),
        Ok(false) => {}
        Err(e) => eprintln!("[Startup] Could not copy the old webview data: {}", e),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct TempDir(std::path::PathBuf);

    impl TempDir {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!("test_app_id_{}", uuid::Uuid::new_v4()));
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
    fn tauri_conf_identifier_is_the_app_id() {
        let conf: serde_json::Value =
            serde_json::from_str(include_str!("../tauri.conf.json")).unwrap();
        assert_eq!(conf["identifier"].as_str(), Some(APP_ID));
    }

    #[test]
    fn bundled_desktop_file_uses_the_app_id_as_window_class() {
        let desktop = include_str!("../bundle/linux/io.github.harshp2008.win11clip.desktop");
        assert!(desktop.contains(&format!("StartupWMClass={APP_ID}\n")));
        for old in LEGACY_APP_IDS {
            assert!(!desktop.contains(&format!("StartupWMClass={old}")));
        }
    }

    #[test]
    fn install_script_holds_the_same_app_id() {
        let script = include_str!("../../scripts/install.sh");
        assert!(script.contains(&format!("\nAPP_ID=\"{APP_ID}\"\n")));
        assert!(script.contains("StartupWMClass=$APP_ID\n"));
        assert!(!script.contains("StartupWMClass=dev."));
    }

    #[test]
    fn setup_wizard_copy_button_command_passes_the_class() {
        let wizard = include_str!("../../src/components/SetupWizard.tsx");
        assert!(wizard.contains(&format!("-m 10 -c {APP_ID} {COMMAND_NAME} --clipboard")));
    }

    #[test]
    fn the_new_id_is_not_one_of_the_old_ones() {
        assert!(!LEGACY_APP_IDS.contains(&APP_ID));
    }

    #[test]
    fn webview_data_is_copied_once_and_the_old_folder_stays() {
        let tmp = TempDir::new();
        let old = tmp.0.join(UPSTREAM_APP_ID);
        fs::create_dir_all(old.join("localstorage/nested")).unwrap();
        fs::write(old.join("localstorage/a.localstorage"), b"compact=true").unwrap();
        fs::write(old.join("localstorage/nested/b"), b"b").unwrap();
        fs::write(old.join("hsts-storage.sqlite"), b"sqlite").unwrap();

        assert!(migrate_legacy_webview_data_in(&tmp.0).unwrap());

        let new = tmp.0.join(APP_ID);
        assert_eq!(
            fs::read(new.join("localstorage/a.localstorage")).unwrap(),
            b"compact=true"
        );
        assert_eq!(fs::read(new.join("localstorage/nested/b")).unwrap(), b"b");
        assert_eq!(
            fs::read(new.join("hsts-storage.sqlite")).unwrap(),
            b"sqlite"
        );
        // Copied, never moved.
        assert!(old.join("localstorage/a.localstorage").exists());
        // No staging folder is left behind.
        let leftovers = fs::read_dir(&tmp.0)
            .unwrap()
            .filter_map(Result::ok)
            .filter(|e| e.file_name().to_string_lossy().contains(".migrating-"))
            .count();
        assert_eq!(leftovers, 0);
    }

    #[test]
    fn webview_data_is_not_copied_again_or_over_existing_data() {
        let tmp = TempDir::new();
        let old = tmp.0.join(UPSTREAM_APP_ID);
        let new = tmp.0.join(APP_ID);
        fs::create_dir_all(&old).unwrap();
        fs::write(old.join("f"), b"old").unwrap();
        fs::create_dir_all(&new).unwrap();
        fs::write(new.join("f"), b"new").unwrap();

        assert!(!migrate_legacy_webview_data_in(&tmp.0).unwrap());
        assert_eq!(fs::read(new.join("f")).unwrap(), b"new");

        // Second call after a real migration is also a no-op.
        let tmp2 = TempDir::new();
        fs::create_dir_all(tmp2.0.join(UPSTREAM_APP_ID)).unwrap();
        fs::write(tmp2.0.join(UPSTREAM_APP_ID).join("f"), b"x").unwrap();
        assert!(migrate_legacy_webview_data_in(&tmp2.0).unwrap());
        fs::write(tmp2.0.join(APP_ID).join("f"), b"changed").unwrap();
        assert!(!migrate_legacy_webview_data_in(&tmp2.0).unwrap());
        assert_eq!(fs::read(tmp2.0.join(APP_ID).join("f")).unwrap(), b"changed");
    }

    #[test]
    fn nothing_to_migrate_without_an_old_folder() {
        let tmp = TempDir::new();
        assert!(!migrate_legacy_webview_data_in(&tmp.0).unwrap());
        assert!(!tmp.0.join(APP_ID).exists());
    }
}
