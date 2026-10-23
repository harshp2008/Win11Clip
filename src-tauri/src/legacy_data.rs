//! One-time copy of the data the app kept under its old name.
//!
//! Before it was called Win11Clip the app kept its files in folders named `win11-clipboard-history`:
//!
//! | what                                           | where                               |
//! |------------------------------------------------|-------------------------------------|
//! | settings, the first-run flag (`setup.json`)    | `<config dir>/…`                    |
//! | clipboard history, emoji usage, window position | `<data dir>/…`                      |
//! | downloaded GIFs                                | `<cache dir>/…`                     |
//!
//! They are now under `win11clip`. On start-up each old folder is COPIED to the new name when the
//! new folder does not exist yet. The old folders are never moved, changed or deleted (the old
//! install may still be around, and history items keep pointing at the old GIF files), and a folder
//! that already exists under the new name is never touched, so running this again does nothing.
//!
//! It runs before anything reads the new folders, so an owner whose first-run flag was copied does
//! not see the Setup Wizard again.

use crate::app_id::{copy_dir_once, DATA_DIR_NAME, LEGACY_DATA_DIR_NAME};
use std::io;
use std::path::{Path, PathBuf};

/// Files of the old config folder that are installer state, not the user's data. They are not
/// carried over (the installer keeps its own record elsewhere now).
const NOT_USER_DATA: &[&str] = &["installer-manifest"];

/// The three base directories the app keeps data under.
#[derive(Debug, Clone)]
pub struct Roots {
    pub config: PathBuf,
    pub data_local: PathBuf,
    pub cache: PathBuf,
}

impl Roots {
    /// The current user's directories, or `None` when the system cannot name them.
    pub fn current_user() -> Option<Self> {
        Some(Self {
            config: dirs::config_dir()?,
            data_local: dirs::data_local_dir()?,
            cache: dirs::cache_dir()?,
        })
    }
}

/// What happened to one folder.
#[derive(Debug)]
pub struct FolderOutcome {
    pub from: PathBuf,
    pub to: PathBuf,
    pub result: io::Result<bool>,
}

/// Copies the old folders under `roots` to their new names where the new ones do not exist yet.
pub fn migrate_in(roots: &Roots) -> Vec<FolderOutcome> {
    let folders: [(&Path, &[&str]); 3] = [
        (&roots.config, NOT_USER_DATA),
        (&roots.data_local, &[]),
        (&roots.cache, &[]),
    ];
    folders
        .iter()
        .map(|(base, skip)| {
            let from = base.join(LEGACY_DATA_DIR_NAME);
            let to = base.join(DATA_DIR_NAME);
            let result = copy_dir_once(&from, &to, skip);
            FolderOutcome { from, to, result }
        })
        .collect()
}

/// Runs [`migrate_in`] for the current user and says what it did. Call it first thing at start-up,
/// before settings, history or the first-run flag are read.
pub fn migrate() {
    let Some(roots) = Roots::current_user() else {
        return;
    };
    for outcome in migrate_in(&roots) {
        match outcome.result {
            Ok(true) => println!(
                "[Startup] Copied {} to {} (the old folder is left in place)",
                outcome.from.display(),
                outcome.to.display()
            ),
            Ok(false) => {}
            Err(e) => eprintln!(
                "[Startup] Could not copy {} to {}: {}",
                outcome.from.display(),
                outcome.to.display(),
                e
            ),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    struct TempDir(PathBuf);

    impl TempDir {
        fn new() -> Self {
            let path =
                std::env::temp_dir().join(format!("test_legacy_data_{}", uuid::Uuid::new_v4()));
            fs::create_dir_all(&path).unwrap();
            Self(path)
        }

        fn roots(&self) -> Roots {
            Roots {
                config: self.0.join("config"),
                data_local: self.0.join("data"),
                cache: self.0.join("cache"),
            }
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn write(path: &Path, content: &str) {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, content).unwrap();
    }

    fn seed_old_install(roots: &Roots) {
        let old = |base: &Path| base.join(LEGACY_DATA_DIR_NAME);
        write(
            &old(&roots.config).join("setup.json"),
            r#"{"first_run_completed":true}"#,
        );
        write(
            &old(&roots.config).join("user_settings.json"),
            r#"{"max_history_size":80}"#,
        );
        write(
            &old(&roots.config).join("installer-manifest"),
            "apt-build:libfoo",
        );
        write(
            &old(&roots.data_local).join("history.json"),
            r#"[{"id":"1"}]"#,
        );
        write(&old(&roots.data_local).join("config.json"), r#"{"x":1}"#);
        write(&old(&roots.cache).join("gifs/cat.gif"), "GIF89a");
    }

    #[test]
    fn copies_every_old_folder_when_the_new_ones_are_missing() {
        let tmp = TempDir::new();
        let roots = tmp.roots();
        seed_old_install(&roots);

        let outcomes = migrate_in(&roots);
        assert_eq!(outcomes.len(), 3);
        for o in &outcomes {
            assert!(matches!(o.result, Ok(true)), "{:?}", o);
        }

        let new = |base: &Path| base.join(DATA_DIR_NAME);
        // The first-run flag came along, so the Setup Wizard is not shown again.
        assert!(new(&roots.config).join("setup.json").is_file());
        assert_eq!(
            fs::read_to_string(new(&roots.config).join("user_settings.json")).unwrap(),
            r#"{"max_history_size":80}"#
        );
        assert_eq!(
            fs::read_to_string(new(&roots.data_local).join("history.json")).unwrap(),
            r#"[{"id":"1"}]"#
        );
        assert!(new(&roots.data_local).join("config.json").is_file());
        assert!(new(&roots.cache).join("gifs/cat.gif").is_file());
        // Installer state is not user data.
        assert!(!new(&roots.config).join("installer-manifest").exists());
    }

    #[test]
    fn the_old_folders_are_never_moved_or_changed() {
        let tmp = TempDir::new();
        let roots = tmp.roots();
        seed_old_install(&roots);
        migrate_in(&roots);

        let old = |base: &Path| base.join(LEGACY_DATA_DIR_NAME);
        assert!(old(&roots.config).join("setup.json").is_file());
        assert!(old(&roots.config).join("installer-manifest").is_file());
        assert_eq!(
            fs::read_to_string(old(&roots.data_local).join("history.json")).unwrap(),
            r#"[{"id":"1"}]"#
        );
        assert!(old(&roots.cache).join("gifs/cat.gif").is_file());
    }

    #[test]
    fn does_nothing_when_the_new_folder_exists() {
        let tmp = TempDir::new();
        let roots = tmp.roots();
        seed_old_install(&roots);
        write(
            &roots.data_local.join(DATA_DIR_NAME).join("history.json"),
            "[]",
        );

        let outcomes = migrate_in(&roots);
        // The data folder was left alone ...
        assert!(matches!(outcomes[1].result, Ok(false)));
        assert_eq!(
            fs::read_to_string(roots.data_local.join(DATA_DIR_NAME).join("history.json")).unwrap(),
            "[]"
        );
        assert!(!roots
            .data_local
            .join(DATA_DIR_NAME)
            .join("config.json")
            .exists());
        // ... while the folders that were still missing were copied.
        assert!(matches!(outcomes[0].result, Ok(true)));
        assert!(matches!(outcomes[2].result, Ok(true)));
    }

    #[test]
    fn running_twice_copies_once_and_keeps_later_changes() {
        let tmp = TempDir::new();
        let roots = tmp.roots();
        seed_old_install(&roots);
        migrate_in(&roots);

        // The user keeps using the new build ...
        let history = roots.data_local.join(DATA_DIR_NAME).join("history.json");
        fs::write(&history, r#"[{"id":"2"}]"#).unwrap();

        // ... and the next start-up changes nothing.
        for o in migrate_in(&roots) {
            assert!(matches!(o.result, Ok(false)), "{:?}", o);
        }
        assert_eq!(fs::read_to_string(&history).unwrap(), r#"[{"id":"2"}]"#);
    }

    #[test]
    fn a_fresh_install_has_nothing_to_copy() {
        let tmp = TempDir::new();
        let roots = tmp.roots();
        fs::create_dir_all(&roots.config).unwrap();

        for o in migrate_in(&roots) {
            assert!(matches!(o.result, Ok(false)), "{:?}", o);
        }
        assert!(!roots.config.join(DATA_DIR_NAME).exists());
        assert!(!roots.data_local.join(DATA_DIR_NAME).exists());
    }

    #[test]
    fn leaves_no_staging_folder_behind() {
        let tmp = TempDir::new();
        let roots = tmp.roots();
        seed_old_install(&roots);
        migrate_in(&roots);

        for base in [&roots.config, &roots.data_local, &roots.cache] {
            let leftovers = fs::read_dir(base)
                .unwrap()
                .filter_map(Result::ok)
                .filter(|e| e.file_name().to_string_lossy().contains(".migrating-"))
                .count();
            assert_eq!(leftovers, 0);
        }
    }

    #[test]
    fn the_setup_wizard_check_follows_the_copied_flag() {
        // permission_checker::is_first_run() is "the flag file does not exist" under the new folder.
        let tmp = TempDir::new();
        let roots = tmp.roots();
        seed_old_install(&roots);
        let flag = roots.config.join(DATA_DIR_NAME).join("setup.json");
        assert!(!flag.exists());
        migrate_in(&roots);
        assert!(flag.exists());
    }
}
