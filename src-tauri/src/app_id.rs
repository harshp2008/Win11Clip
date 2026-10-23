//! The app's own identity.
//!
//! `APP_ID` is the Wayland app id (X11 `WM_CLASS`) of every window the app opens, and the Tauri
//! `identifier`. `spawn-at` finds the popup it has to place by this class, so each shortcut passes
//! it with `-c`, and the `.desktop` files and the autostart entry carry it as `StartupWMClass`.
//!
//! Rust code uses the constant. Places that cannot import it hold a literal copy that a test checks:
//! `tauri.conf.json`, the bundled `.desktop` file, `scripts/install.sh` and the Setup Wizard text.

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

/// This app's id. See the module docs.
pub const APP_ID: &str = app_id!();

/// The id this fork inherited from the upstream project, and was released with until it got its own.
pub const UPSTREAM_APP_ID: &str = "dev.gustavosett.clipboard-history";

/// Window classes older releases used. Entries that carry one of these (autostart entries, dock
/// states, shortcuts) are Win11Clip's own and get moved to `APP_ID`.
pub const LEGACY_APP_IDS: &[&str] = &[UPSTREAM_APP_ID, "win11-clipboard-history"];

/// Copies the directory `from` to `to`, creating `to`. Symbolic links are skipped.
fn copy_dir_all(from: &Path, to: &Path) -> io::Result<()> {
    fs::create_dir_all(to)?;
    for entry in fs::read_dir(from)? {
        let entry = entry?;
        let file_type = entry.file_type()?;
        let target = to.join(entry.file_name());
        if file_type.is_dir() {
            copy_dir_all(&entry.path(), &target)?;
        } else if file_type.is_file() {
            fs::copy(entry.path(), &target)?;
        }
    }
    Ok(())
}

/// On Linux Tauri keeps the webview's storage (localStorage, caches) in `<data dir>/<identifier>`.
/// The identifier changed, so this copies the old folder to the new one once, when the new one does
/// not exist yet. The old folder is never moved or deleted. Returns whether a copy was made.
///
/// The copy goes to a temporary sibling first and is renamed into place, so a second instance that
/// starts meanwhile never sees a half-copied folder.
pub fn migrate_legacy_webview_data_in(data_local_dir: &Path) -> io::Result<bool> {
    let new_dir = data_local_dir.join(APP_ID);
    let old_dir = data_local_dir.join(UPSTREAM_APP_ID);
    if new_dir.exists() || !old_dir.is_dir() {
        return Ok(false);
    }

    let staging = data_local_dir.join(format!(".{}.migrating-{}", APP_ID, std::process::id()));
    let _ = fs::remove_dir_all(&staging);
    if let Err(e) = copy_dir_all(&old_dir, &staging) {
        let _ = fs::remove_dir_all(&staging);
        return Err(e);
    }
    match fs::rename(&staging, &new_dir) {
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
        let desktop = include_str!("../bundle/linux/win11-clipboard-history.desktop");
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
        assert!(wizard.contains(&format!(
            "-m 10 -c {APP_ID} win11-clipboard-history --clipboard"
        )));
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
