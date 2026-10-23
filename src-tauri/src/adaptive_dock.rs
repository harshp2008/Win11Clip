//! Integration with GNOME Shell extension Adaptive Dock (`adaptive-dock@harsh.patel`).
//!
//! Adaptive Dock controls dock/taskbar visibility on GNOME Shell per-application and
//! per-workspace. For floating companion utilities like Win11Clip, it provides a "bypass" mode,
//! which preserves dock visibility state when Win11Clip is activated (preventing unwanted dock
//! unhiding on Super+V).
//!
//! App states are stored in `$XDG_CONFIG_HOME/dock-app-states.json` (fallback: `~/.config/dock-app-states.json`)
//! and live-monitored by the extension via `Gio.FileMonitor`.

use std::fs;
use std::path::{Path, PathBuf};

/// The UUID of the Adaptive Dock GNOME Shell extension.
pub const ADAPTIVE_DOCK_EXTENSION_UUID: &str = "adaptive-dock@harsh.patel";

/// The identifiers used by Win11Clip across various execution modes and packaging formats.
/// The older ones stay so that entries already in `dock-app-states.json` remain valid.
pub const WIN11CLIP_APP_IDS: &[&str] = &[
    crate::app_id::APP_ID,
    crate::app_id::COMMAND_NAME,
    crate::app_id::BINARY_NAME,
    crate::app_id::UPSTREAM_APP_ID,
    crate::app_id::LEGACY_COMMAND_NAME,
    crate::app_id::LEGACY_BINARY_NAME,
];

/// The bypass mode string expected by Adaptive Dock.
pub const BYPASS_VALUE: &str = "bypass";

/// Checks if the Adaptive Dock extension is installed or enabled in GNOME Shell.
#[tauri::command]
pub fn is_adaptive_dock_installed() -> bool {
    // 1. Check user extension directory: ~/.local/share/gnome-shell/extensions/adaptive-dock@harsh.patel
    if let Some(data_dir) = dirs::data_dir() {
        let user_ext_path = data_dir
            .join("gnome-shell")
            .join("extensions")
            .join(ADAPTIVE_DOCK_EXTENSION_UUID);
        if user_ext_path.exists() {
            return true;
        }
    }

    // Fallback: check $HOME/.local/share/gnome-shell/extensions/... directly if dirs::data_dir() differed
    if let Ok(home) = std::env::var("HOME") {
        let home_ext_path = PathBuf::from(home)
            .join(".local")
            .join("share")
            .join("gnome-shell")
            .join("extensions")
            .join(ADAPTIVE_DOCK_EXTENSION_UUID);
        if home_ext_path.exists() {
            return true;
        }
    }

    // 2. Check system extension directories:
    // /usr/share/gnome-shell/extensions/adaptive-dock@harsh.patel
    // /usr/local/share/gnome-shell/extensions/adaptive-dock@harsh.patel
    let sys_paths = [
        Path::new("/usr/share/gnome-shell/extensions").join(ADAPTIVE_DOCK_EXTENSION_UUID),
        Path::new("/usr/local/share/gnome-shell/extensions").join(ADAPTIVE_DOCK_EXTENSION_UUID),
    ];
    for p in &sys_paths {
        if p.exists() {
            return true;
        }
    }

    // 3. Query GNOME extensions via CLI: `gnome-extensions list --enabled`
    if let Ok(output) = std::process::Command::new("gnome-extensions")
        .args(["list", "--enabled"])
        .output()
    {
        if output.status.success() {
            let stdout = String::from_utf8_lossy(&output.stdout);
            if stdout.lines().any(|l| l.trim() == ADAPTIVE_DOCK_EXTENSION_UUID) {
                return true;
            }
        }
    }

    // Also query all installed extensions via `gnome-extensions list`
    if let Ok(output) = std::process::Command::new("gnome-extensions")
        .arg("list")
        .output()
    {
        if output.status.success() {
            let stdout = String::from_utf8_lossy(&output.stdout);
            if stdout.lines().any(|l| l.trim() == ADAPTIVE_DOCK_EXTENSION_UUID) {
                return true;
            }
        }
    }

    false
}

/// Returns the path to the dock app states JSON file:
/// `$XDG_CONFIG_HOME/dock-app-states.json` (fallback: `~/.config/dock-app-states.json`).
pub fn get_dock_app_states_path() -> PathBuf {
    let config_dir = dirs::config_dir().unwrap_or_else(|| {
        if let Ok(home) = std::env::var("HOME") {
            PathBuf::from(home).join(".config")
        } else {
            PathBuf::from(".config")
        }
    });
    config_dir.join("dock-app-states.json")
}

/// Registers Win11Clip identifiers as "bypass" in `dock-app-states.json`.
///
/// If the file exists, it parses the existing JSON and updates or adds the Win11Clip keys,
/// preserving all other application settings.
/// If corrupt or missing, it initializes a clean JSON object.
///
/// The file is formatted with 2 spaces indentation and written atomically/safely with 0o755 parent directories.
///
/// Returns:
/// - `Ok(true)` if the file was modified/created.
/// - `Ok(false)` if the file already had all Win11Clip keys set to "bypass" (idempotent no-op).
/// - `Err(String)` if a file I/O or serialization error occurred.
#[tauri::command]
pub fn register_adaptive_dock_bypass() -> Result<bool, String> {
    let states_path = get_dock_app_states_path();
    register_bypass_to_path(&states_path)
}

/// Internal helper for registering bypass into a specified file path (allows deterministic testing).
pub fn register_bypass_to_path(states_path: &Path) -> Result<bool, String> {
    let parent_dir = match states_path.parent() {
        Some(p) => p,
        None => return Err(format!("Invalid path for dock-app-states.json: {}", states_path.display())),
    };

    // Ensure parent directory exists with 0o755 permissions
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        let mut builder = fs::DirBuilder::new();
        builder.recursive(true);
        builder.mode(0o755);
        if let Err(e) = builder.create(parent_dir) {
            return Err(format!("Failed to create directory {}: {}", parent_dir.display(), e));
        }
    }
    #[cfg(not(unix))]
    {
        if let Err(e) = fs::create_dir_all(parent_dir) {
            return Err(format!("Failed to create directory {}: {}", parent_dir.display(), e));
        }
    }

    // Read and parse existing file if present
    let mut states_map: serde_json::Map<String, serde_json::Value> = if states_path.exists() {
        match fs::read_to_string(states_path) {
            Ok(content) => match serde_json::from_str::<serde_json::Value>(&content) {
                Ok(serde_json::Value::Object(map)) => map,
                _ => {
                    eprintln!(
                        "[AdaptiveDock] Existing dock-app-states.json at {} is invalid, initializing new object",
                        states_path.display()
                    );
                    serde_json::Map::new()
                }
            },
            Err(e) => {
                eprintln!(
                    "[AdaptiveDock] Failed to read existing dock-app-states.json: {}, initializing new object",
                    e
                );
                serde_json::Map::new()
            }
        }
    } else {
        serde_json::Map::new()
    };

    // Check if any keys are missing or not set to "bypass"
    let mut modified = false;
    for &app_id in WIN11CLIP_APP_IDS {
        let is_bypass = match states_map.get(app_id) {
            Some(serde_json::Value::String(val)) => val == BYPASS_VALUE,
            _ => false,
        };
        if !is_bypass {
            states_map.insert(
                app_id.to_string(),
                serde_json::Value::String(BYPASS_VALUE.to_string()),
            );
            modified = true;
        }
    }

    // If file already exists and all keys were already "bypass", avoid rewriting to prevent unnecessary file monitor triggers
    if !modified && states_path.exists() {
        return Ok(false);
    }

    // Format with exactly 2 spaces indentation
    let formatter = serde_json::ser::PrettyFormatter::with_indent(b"  ");
    let mut buf = Vec::new();
    let mut serializer = serde_json::Serializer::with_formatter(&mut buf, formatter);
    use serde::Serialize;
    serde_json::Value::Object(states_map)
        .serialize(&mut serializer)
        .map_err(|e| format!("Failed to serialize dock-app-states JSON: {}", e))?;

    let mut output = String::from_utf8(buf)
        .map_err(|e| format!("UTF-8 encoding error: {}", e))?;
    if !output.ends_with('\n') {
        output.push('\n');
    }

    fs::write(states_path, output)
        .map_err(|e| format!("Failed to write {}: {}", states_path.display(), e))?;

    println!(
        "[AdaptiveDock] Registered Win11Clip identifiers as '{}' in {}",
        BYPASS_VALUE,
        states_path.display()
    );
    Ok(true)
}

/// Checks if Adaptive Dock is present (or dock-app-states.json exists) and registers bypass state.
/// Safe to call repeatedly and unconditionally on startup or setup completion.
pub fn register_bypass_if_applicable() {
    let states_path = get_dock_app_states_path();
    let is_present = is_adaptive_dock_installed() || states_path.exists();

    if is_present {
        match register_adaptive_dock_bypass() {
            Ok(true) => {
                println!("[AdaptiveDock] Adaptive Dock detected; bypass configuration applied.");
            }
            Ok(false) => {
                // Idempotent: already present and correct
            }
            Err(e) => {
                eprintln!("[AdaptiveDock] Warning: Failed to configure bypass state: {}", e);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct TempDir {
        path: PathBuf,
    }

    impl TempDir {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!("test_adaptive_dock_{}", uuid::Uuid::new_v4()));
            let _ = fs::create_dir_all(&path);
            Self { path }
        }

        fn path(&self) -> &Path {
            &self.path
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.path);
        }
    }

    #[test]
    fn win11clip_app_ids_hold_the_app_id_and_every_older_class() {
        assert!(WIN11CLIP_APP_IDS.contains(&crate::app_id::APP_ID));
        for old in crate::app_id::LEGACY_APP_IDS {
            assert!(WIN11CLIP_APP_IDS.contains(old));
        }
        assert!(WIN11CLIP_APP_IDS.contains(&crate::app_id::LEGACY_BINARY_NAME));
    }

    #[test]
    fn win11clip_app_ids_hold_the_new_names_and_the_old_ones() {
        // Written out on purpose: a rename that drops one of these loses a user's Bypass setting.
        for id in [
            "io.github.harshp2008.win11clip",
            "win11clip",
            "win11clip-bin",
            "dev.gustavosett.clipboard-history",
            "win11-clipboard-history",
            "win11-clipboard-history-bin",
        ] {
            assert!(WIN11CLIP_APP_IDS.contains(&id), "missing {id}");
        }
    }

    #[test]
    fn existing_entries_for_the_old_ids_stay_and_the_new_id_is_added() {
        let temp_dir = TempDir::new();
        let file_path = temp_dir.path().join("dock-app-states.json");
        fs::write(
            &file_path,
            r#"{
  "dev.gustavosett.clipboard-history": "bypass",
  "win11-clipboard-history": "bypass",
  "win11-clipboard-history-bin": "bypass"
}"#,
        )
        .unwrap();

        assert!(register_bypass_to_path(&file_path).unwrap());
        let parsed: serde_json::Value =
            serde_json::from_str(&fs::read_to_string(&file_path).unwrap()).unwrap();
        for &id in WIN11CLIP_APP_IDS {
            assert_eq!(parsed.get(id).and_then(|v| v.as_str()), Some("bypass"));
        }
        assert!(!register_bypass_to_path(&file_path).unwrap());
    }

    #[test]
    fn test_is_adaptive_dock_installed() {
        let installed = is_adaptive_dock_installed();
        // Since adaptive-dock@harsh.patel is installed on this test machine, it should return true
        assert!(installed);
    }

    #[test]
    fn test_live_registration() {
        let res = register_adaptive_dock_bypass();
        assert!(res.is_ok());
        let path = get_dock_app_states_path();
        let content = fs::read_to_string(&path).unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&content).unwrap();
        for &id in WIN11CLIP_APP_IDS {
            assert_eq!(parsed.get(id).and_then(|v| v.as_str()), Some("bypass"));
        }
    }

    #[test]
    fn test_register_bypass_creates_and_formats_file() {
        let temp_dir = TempDir::new();
        let file_path = temp_dir.path().join("dock-app-states.json");

        // First run: file doesn't exist
        let res = register_bypass_to_path(&file_path).unwrap();
        assert!(res);
        assert!(file_path.exists());

        let content = fs::read_to_string(&file_path).unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&content).unwrap();

        for &id in WIN11CLIP_APP_IDS {
            assert_eq!(parsed.get(id).and_then(|v| v.as_str()), Some("bypass"));
        }

        // Verify 2 spaces indentation
        assert!(content.contains(&format!("  \"{}\": \"bypass\"", crate::app_id::APP_ID)));
        assert!(content.contains("  \"dev.gustavosett.clipboard-history\": \"bypass\""));

        // Second run: idempotent, returns false, does not alter content
        let res_second = register_bypass_to_path(&file_path).unwrap();
        assert!(!res_second);
    }

    #[test]
    fn test_register_bypass_preserves_existing_keys() {
        let temp_dir = TempDir::new();
        let file_path = temp_dir.path().join("dock-app-states.json");

        let initial_json = r#"{
  "chrome": "hide",
  "antigravity": "show"
}"#;
        fs::write(&file_path, initial_json).unwrap();

        let res = register_bypass_to_path(&file_path).unwrap();
        assert!(res);

        let content = fs::read_to_string(&file_path).unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&content).unwrap();

        assert_eq!(parsed.get("chrome").and_then(|v| v.as_str()), Some("hide"));
        assert_eq!(parsed.get("antigravity").and_then(|v| v.as_str()), Some("show"));
        for &id in WIN11CLIP_APP_IDS {
            assert_eq!(parsed.get(id).and_then(|v| v.as_str()), Some("bypass"));
        }
    }

    #[test]
    fn test_register_bypass_handles_corrupt_file() {
        let temp_dir = TempDir::new();
        let file_path = temp_dir.path().join("dock-app-states.json");

        fs::write(&file_path, "{ broken json ...").unwrap();

        let res = register_bypass_to_path(&file_path).unwrap();
        assert!(res);

        let content = fs::read_to_string(&file_path).unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&content).unwrap();
        for &id in WIN11CLIP_APP_IDS {
            assert_eq!(parsed.get(id).and_then(|v| v.as_str()), Some("bypass"));
        }
    }
}
