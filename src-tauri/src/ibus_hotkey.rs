//! IBus emoji hotkey conflict handling.
//!
//! IBus binds `<Super>period` to its own emoji picker by default, which shadows
//! Win11Clip's emoji shortcut. When the emoji shortcut is registered, we remove
//! exactly that entry from the IBus emoji hotkey list, keeping every other
//! binding intact, and stash the original value under
//! `~/.local/state/win11clip-installer/ibus-emoji-hotkey.orig` so it can be
//! restored later. Every failure is non-fatal: callers only log a warning.

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Command;

const SCHEMA: &str = "org.freedesktop.ibus.panel.emoji";
const KEY: &str = "hotkey";
const CONFLICTING_HOTKEY: &str = "<Super>period";
const STATE_DIR_NAME: &str = "win11clip-installer";
const ORIGINAL_FILE_NAME: &str = "ibus-emoji-hotkey.orig";

/// Thin abstraction over the `gsettings` CLI so the logic can be unit tested
/// without touching a real GNOME/IBus configuration.
pub trait GsettingsRunner {
    fn schema_exists(&self, schema: &str) -> bool;
    fn get(&self, schema: &str, key: &str) -> Result<String, String>;
    fn set(&self, schema: &str, key: &str, value: &str) -> Result<(), String>;
}

/// Production implementation backed by the `gsettings` command line tool.
pub struct RealGsettings;

impl GsettingsRunner for RealGsettings {
    fn schema_exists(&self, schema: &str) -> bool {
        let Ok(output) = Command::new("gsettings").arg("list-schemas").output() else {
            return false;
        };
        if !output.status.success() {
            return false;
        }
        String::from_utf8_lossy(&output.stdout)
            .lines()
            .any(|line| line.trim() == schema)
    }

    fn get(&self, schema: &str, key: &str) -> Result<String, String> {
        let output = Command::new("gsettings")
            .args(["get", schema, key])
            .output()
            .map_err(|err| format!("failed to run `gsettings get {schema} {key}`: {err}"))?;
        if !output.status.success() {
            return Err(format!(
                "`gsettings get {schema} {key}` failed: {}",
                String::from_utf8_lossy(&output.stderr).trim()
            ));
        }
        Ok(String::from_utf8_lossy(&output.stdout)
            .trim_end()
            .to_string())
    }

    fn set(&self, schema: &str, key: &str, value: &str) -> Result<(), String> {
        let output = Command::new("gsettings")
            .args(["set", schema, key, value])
            .output()
            .map_err(|err| {
                format!("failed to run `gsettings set {schema} {key} {value}`: {err}")
            })?;
        if !output.status.success() {
            return Err(format!(
                "`gsettings set {schema} {key}` failed: {}",
                String::from_utf8_lossy(&output.stderr).trim()
            ));
        }
        Ok(())
    }
}

/// Result of a successful (non-error) run of
/// [`ensure_super_period_removed_with`].
#[derive(Debug, PartialEq, Eq)]
pub enum Outcome {
    /// The IBus emoji schema is not installed; nothing to do.
    NoSchema,
    /// The schema exists but does not bind `<Super>period`; nothing to do.
    NoPeriod,
    /// `<Super>period` was removed from the hotkey list.
    Removed { remaining: Vec<String> },
}

/// Removes `<Super>period` from the IBus emoji hotkey list, saving the original
/// value under `state_dir` before the first change.
///
/// The original value is only written when a change is actually needed, and an
/// existing original file is never overwritten. If saving the original fails,
/// the IBus setting is left untouched and an error is returned.
pub fn ensure_super_period_removed_with(
    runner: &dyn GsettingsRunner,
    state_dir: &Path,
) -> Result<Outcome, String> {
    if !runner.schema_exists(SCHEMA) {
        return Ok(Outcome::NoSchema);
    }

    let original = runner.get(SCHEMA, KEY)?;
    let mut entries = parse_variant_list(&original)?;
    if !entries.iter().any(|entry| entry == CONFLICTING_HOTKEY) {
        return Ok(Outcome::NoPeriod);
    }

    save_original_value_if_missing(state_dir, &original)?;

    entries.retain(|entry| entry != CONFLICTING_HOTKEY);
    let new_value = serialize_variant_list(&entries);
    runner.set(SCHEMA, KEY, &new_value)?;

    Ok(Outcome::Removed { remaining: entries })
}

/// Convenience entry point for the current user.
///
/// Resolves the state directory from `dirs::state_dir()` (falling back to
/// `$HOME/.local/state`) and never panics or propagates errors: failures are
/// reported as warnings so shortcut registration always continues.
pub fn ensure_super_period_removed_for_current_user() {
    let Some(state_dir) = default_state_dir() else {
        eprintln!(
            "[IBus] Warning: could not resolve a state directory; \
             skipping IBus emoji hotkey conflict fix"
        );
        return;
    };

    match ensure_super_period_removed_with(&RealGsettings, &state_dir) {
        Ok(Outcome::Removed { remaining }) => {
            println!(
                "[IBus] Removed <Super>period from the IBus emoji hotkey (remaining: {})",
                serialize_variant_list(&remaining)
            );
        }
        Ok(Outcome::NoSchema) | Ok(Outcome::NoPeriod) => {}
        Err(err) => eprintln!(
            "[IBus] Warning: could not remove <Super>period from the IBus emoji hotkey: {err}"
        ),
    }
}

fn default_state_dir() -> Option<PathBuf> {
    dirs::state_dir()
        .or_else(|| {
            std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".local").join("state"))
        })
        .map(|state_dir| state_dir.join(STATE_DIR_NAME))
}

/// Writes `value` (plus a trailing newline) to the original-value file, unless
/// that file already exists. Creates the parent directories as needed.
fn save_original_value_if_missing(state_dir: &Path, value: &str) -> Result<(), String> {
    fs::create_dir_all(state_dir).map_err(|err| {
        format!(
            "failed to create state directory '{}': {err}",
            state_dir.display()
        )
    })?;

    let path = state_dir.join(ORIGINAL_FILE_NAME);
    match OpenOptions::new().write(true).create_new(true).open(&path) {
        Ok(mut file) => writeln!(file, "{value}").map_err(|err| {
            format!(
                "failed to write original IBus hotkey value to '{}': {err}",
                path.display()
            )
        }),
        Err(err) if err.kind() == std::io::ErrorKind::AlreadyExists => Ok(()),
        Err(err) => Err(format!(
            "failed to create original IBus hotkey file '{}': {err}",
            path.display()
        )),
    }
}

/// Parses a GVariant string array such as `['a', 'b']` (also accepting the
/// `@as []` form printed for empty arrays) into its elements.
fn parse_variant_list(raw: &str) -> Result<Vec<String>, String> {
    let text = raw.trim();
    let text = match text.strip_prefix("@as") {
        Some(rest) => rest.trim_start(),
        None => text,
    };
    let Some(inner) = text
        .strip_prefix('[')
        .and_then(|rest| rest.strip_suffix(']'))
    else {
        return Err(format!(
            "unexpected gsettings value (expected a string array): {raw}"
        ));
    };

    let mut values = Vec::new();
    let mut chars = inner.chars();
    loop {
        match chars.next() {
            None => break,
            Some(c) if c.is_whitespace() || c == ',' => continue,
            Some('\'') => {
                let mut value = String::new();
                loop {
                    match chars.next() {
                        Some('\\') => match chars.next() {
                            Some(escaped) => value.push(escaped),
                            None => {
                                return Err(format!(
                                    "unterminated escape in gsettings value: {raw}"
                                ));
                            }
                        },
                        Some('\'') => break,
                        Some(other) => value.push(other),
                        None => {
                            return Err(format!("unterminated string in gsettings value: {raw}"));
                        }
                    }
                }
                values.push(value);
            }
            Some(other) => {
                return Err(format!(
                    "unexpected character '{other}' in gsettings value: {raw}"
                ));
            }
        }
    }
    Ok(values)
}

/// Serializes a string array back into GVariant text, e.g. `['a', 'b']` or `[]`.
fn serialize_variant_list(values: &[String]) -> String {
    let mut serialized = String::from("[");
    for (index, value) in values.iter().enumerate() {
        if index > 0 {
            serialized.push_str(", ");
        }
        serialized.push('\'');
        for c in value.chars() {
            if c == '\\' || c == '\'' {
                serialized.push('\\');
            }
            serialized.push(c);
        }
        serialized.push('\'');
    }
    serialized.push(']');
    serialized
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    type SetCall = (String, String, String);

    struct FakeGsettings {
        schema_present: bool,
        value: RefCell<String>,
        set_calls: RefCell<Vec<SetCall>>,
    }

    impl FakeGsettings {
        fn new(value: &str) -> Self {
            Self {
                schema_present: true,
                value: RefCell::new(value.to_string()),
                set_calls: RefCell::new(Vec::new()),
            }
        }

        fn set_value(&self, value: &str) {
            *self.value.borrow_mut() = value.to_string();
        }

        fn current_value(&self) -> String {
            self.value.borrow().clone()
        }

        fn set_calls(&self) -> Vec<SetCall> {
            self.set_calls.borrow().clone()
        }
    }

    impl GsettingsRunner for FakeGsettings {
        fn schema_exists(&self, _schema: &str) -> bool {
            self.schema_present
        }

        fn get(&self, _schema: &str, _key: &str) -> Result<String, String> {
            Ok(self.current_value())
        }

        fn set(&self, schema: &str, key: &str, value: &str) -> Result<(), String> {
            self.set_calls.borrow_mut().push((
                schema.to_string(),
                key.to_string(),
                value.to_string(),
            ));
            self.set_value(value);
            Ok(())
        }
    }

    struct TempDir(PathBuf);

    impl TempDir {
        fn new(case: &str) -> Self {
            let path = std::env::temp_dir().join(format!(
                "w11c-ibus-test-{}-{}",
                case,
                std::process::id()
            ));
            let _ = fs::remove_dir_all(&path);
            fs::create_dir_all(&path).expect("failed to create temp dir");
            Self(path)
        }

        fn path(&self) -> &Path {
            &self.0
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn original_path(state_dir: &Path) -> PathBuf {
        state_dir.join(ORIGINAL_FILE_NAME)
    }

    #[test]
    fn removes_only_period_and_keeps_other_entries() {
        let temp = TempDir::new("removes-only-period");
        let runner = FakeGsettings::new("['<Super>semicolon', '<Super>period']");

        let outcome = ensure_super_period_removed_with(&runner, temp.path()).unwrap();

        assert_eq!(
            outcome,
            Outcome::Removed {
                remaining: vec!["<Super>semicolon".to_string()]
            }
        );
        assert_eq!(
            runner.set_calls(),
            vec![(
                SCHEMA.to_string(),
                KEY.to_string(),
                "['<Super>semicolon']".to_string()
            )]
        );
        assert_eq!(runner.current_value(), "['<Super>semicolon']");
    }

    #[test]
    fn saves_original_value_before_first_change() {
        let temp = TempDir::new("saves-original");
        let original = "['<Super>semicolon', '<Super>period']";
        let runner = FakeGsettings::new(original);

        ensure_super_period_removed_with(&runner, temp.path()).unwrap();

        let saved = fs::read_to_string(original_path(temp.path())).unwrap();
        assert_eq!(saved, format!("{original}\n"));
    }

    #[test]
    fn second_run_keeps_original_file() {
        let temp = TempDir::new("second-run");
        let original = "['<Super>semicolon', '<Super>period']";
        let runner = FakeGsettings::new(original);

        ensure_super_period_removed_with(&runner, temp.path()).unwrap();
        // Simulate IBus being reset externally; the period binding reappears.
        runner.set_value(original);

        let outcome = ensure_super_period_removed_with(&runner, temp.path()).unwrap();

        assert_eq!(
            outcome,
            Outcome::Removed {
                remaining: vec!["<Super>semicolon".to_string()]
            }
        );
        assert_eq!(
            fs::read_to_string(original_path(temp.path())).unwrap(),
            format!("{original}\n")
        );
        assert_eq!(runner.set_calls().len(), 2);
    }

    #[test]
    fn schema_missing_is_a_noop() {
        let temp = TempDir::new("schema-missing");
        let runner = FakeGsettings {
            schema_present: false,
            ..FakeGsettings::new("['<Super>period']")
        };

        let outcome = ensure_super_period_removed_with(&runner, temp.path()).unwrap();

        assert_eq!(outcome, Outcome::NoSchema);
        assert!(runner.set_calls().is_empty());
        assert!(!original_path(temp.path()).exists());
    }

    #[test]
    fn period_absent_is_a_noop() {
        let temp = TempDir::new("period-absent");
        let value = "['<Super>semicolon']";
        let runner = FakeGsettings::new(value);

        let outcome = ensure_super_period_removed_with(&runner, temp.path()).unwrap();

        assert_eq!(outcome, Outcome::NoPeriod);
        assert!(runner.set_calls().is_empty());
        assert_eq!(runner.current_value(), value);
        assert!(!original_path(temp.path()).exists());
    }

    #[test]
    fn existing_original_file_is_not_overwritten() {
        let temp = TempDir::new("existing-original");
        let already_saved = "PRE-EXISTING VALUE\n";
        fs::write(original_path(temp.path()), already_saved).unwrap();
        let runner = FakeGsettings::new("['<Super>period']");

        let outcome = ensure_super_period_removed_with(&runner, temp.path()).unwrap();

        assert_eq!(
            outcome,
            Outcome::Removed {
                remaining: Vec::new()
            }
        );
        assert_eq!(
            fs::read_to_string(original_path(temp.path())).unwrap(),
            already_saved
        );
        assert_eq!(
            runner.set_calls(),
            vec![(SCHEMA.to_string(), KEY.to_string(), "[]".to_string())]
        );
    }

    #[test]
    fn original_save_failure_does_not_change_setting() {
        let temp = TempDir::new("save-failure");
        let blocker = temp.path().join("state-is-a-file");
        fs::write(&blocker, "not a directory").unwrap();
        let runner = FakeGsettings::new("['<Super>period']");

        let result = ensure_super_period_removed_with(&runner, &blocker);

        assert!(result.is_err());
        assert!(runner.set_calls().is_empty());
        assert_eq!(runner.current_value(), "['<Super>period']");
    }

    #[test]
    fn parses_and_serializes_gvariant_lists() {
        assert_eq!(
            parse_variant_list("['<Super>semicolon', '<Super>period']").unwrap(),
            vec!["<Super>semicolon", "<Super>period"]
        );
        assert_eq!(parse_variant_list("[]").unwrap(), Vec::<String>::new());
        assert_eq!(parse_variant_list("@as []").unwrap(), Vec::<String>::new());
        assert_eq!(
            serialize_variant_list(&["a'".to_string(), "b\\c".to_string()]),
            "['a\\'', 'b\\\\c']"
        );
        assert!(parse_variant_list("not a list").is_err());
    }
}
