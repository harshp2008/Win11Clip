//! User Settings Module
//! Handles persistence of user preferences (theme mode, background opacity) in a separate JSON file.

use serde::{Deserialize, Serialize};
use std::fs;
use std::path::PathBuf;

const USER_SETTINGS_FILE: &str = "user_settings.json";

/// User-configurable settings for the application
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UserSettings {
    /// Theme mode: "system", "dark", or "light"
    pub theme_mode: String,
    /// Background opacity for dark mode (0.0 to 1.0)
    pub dark_background_opacity: f32,
    /// Background opacity for light mode (0.0 to 1.0)
    pub light_background_opacity: f32,

    // --- Feature Flags ---
    /// Enable Dynamic Tray Icon (changes color based on system theme)
    /// Only relevant for GNOME/Pop!_OS where it defaults to true
    #[serde(default = "default_true")]
    pub enable_dynamic_tray_icon: bool,

    /// Enable Smart Actions (URL, Color, Email detection)
    #[serde(default = "default_true")]
    pub enable_smart_actions: bool,

    /// Enable UI Polish (Compact Mode capability)
    #[serde(default = "default_true")]
    pub enable_ui_polish: bool,

    // --- History Settings ---
    /// Maximum number of clipboard history items to keep (1 to 100000)
    #[serde(default = "default_max_history_size")]
    pub max_history_size: usize,

    /// Auto-delete interval value (0 means disabled)
    #[serde(default = "default_zero")]
    pub auto_delete_interval: u64,

    /// Auto-delete interval unit ("minutes", "hours", "days", "weeks")
    #[serde(default = "default_unit")]
    pub auto_delete_unit: String,

    // --- Custom Data ---
    /// User-defined Kaomojis
    #[serde(default)]
    pub custom_kaomojis: Vec<CustomKaomoji>,

    // --- UI Scale ---
    /// UI scale factor for the clipboard window (0.5 to 2.0, default 1.0)
    #[serde(default = "default_ui_scale")]
    pub ui_scale: f32,

    // --- Behaviour ---
    /// When true (default), the clipboard window floats above other windows
    /// while it is open. Disable to let it blend in as a normal window layer.
    #[serde(default = "default_true")]
    pub always_on_top: bool,

    /// When true (default), the window is hidden when the user types in another
    /// application while the clipboard panel is visible but unfocused.
    #[serde(default = "default_true")]
    pub close_on_typing_when_unfocused: bool,

    /// The remembered "Start at login" choice: `None` when the user never chose, otherwise
    /// `Some(true)` (on) or `Some(false)` (off). Never chosen counts as on; see
    /// `start_at_login_wanted`. Only `set_start_at_login` writes it.
    #[serde(default)]
    pub start_at_login: Option<bool>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct CustomKaomoji {
    pub text: String,
    pub category: String, // Default "Custom"
    #[serde(default)]
    pub keywords: Vec<String>,
}

fn default_true() -> bool {
    true
}

fn default_max_history_size() -> usize {
    crate::clipboard_manager::DEFAULT_MAX_HISTORY_SIZE
}

fn default_ui_scale() -> f32 {
    1.0
}

fn default_zero() -> u64 {
    0
}

fn default_unit() -> String {
    "hours".to_string()
}

impl Default for UserSettings {
    fn default() -> Self {
        Self {
            theme_mode: "system".to_string(),
            dark_background_opacity: 0.70,
            light_background_opacity: 0.70,
            enable_dynamic_tray_icon: true,
            enable_smart_actions: true,
            enable_ui_polish: true,
            max_history_size: default_max_history_size(),
            auto_delete_interval: 0,
            auto_delete_unit: "hours".to_string(),
            custom_kaomojis: Vec::new(),
            ui_scale: default_ui_scale(),
            always_on_top: true,
            close_on_typing_when_unfocused: true,
            start_at_login: None,
        }
    }
}

impl UserSettings {
    /// Whether the app should have an autostart entry: on unless the user switched it off.
    pub fn start_at_login_wanted(&self) -> bool {
        self.start_at_login != Some(false)
    }

    pub fn auto_delete_interval_in_minutes(&self) -> u64 {
        if self.auto_delete_interval == 0 {
            return 0;
        }

        let base = self.auto_delete_interval;

        match self.auto_delete_unit.as_str() {
            "minutes" => base,
            "hours" => base.saturating_mul(60),
            "days" => base.saturating_mul(60).saturating_mul(24),
            "weeks" => base.saturating_mul(60).saturating_mul(24).saturating_mul(7),
            _ => unreachable!("invalid auto_delete_unit: {}", self.auto_delete_unit),
        }
    }

    /// Validates and clamps opacity values to the valid range [0.0, 1.0]
    pub fn validate(&mut self) {
        self.dark_background_opacity = self.dark_background_opacity.clamp(0.0, 1.0);
        self.light_background_opacity = self.light_background_opacity.clamp(0.0, 1.0);

        // Validate theme_mode
        if !["system", "dark", "light"].contains(&self.theme_mode.as_str()) {
            self.theme_mode = "system".to_string();
        }

        // Validate max_history_size (1 to 100000)
        self.max_history_size = self.max_history_size.clamp(1, 100_000);

        // Validate ui_scale (0.5 to 2.0)
        self.ui_scale = self.ui_scale.clamp(0.5, 2.0);

        // Validate auto_delete_unit
        if !["minutes", "hours", "days", "weeks"].contains(&self.auto_delete_unit.as_str()) {
            self.auto_delete_unit = "hours".to_string();
        }
    }
}

/// Manages loading and saving of user settings
pub struct UserSettingsManager {
    config_dir: PathBuf,
}

impl UserSettingsManager {
    /// Creates a new UserSettingsManager
    /// Uses the OS-appropriate config directory (e.g., ~/.config/win11clip/)
    pub fn new() -> Self {
        let config_dir = dirs::config_dir()
            .unwrap_or_else(|| PathBuf::from("."))
            .join(crate::app_id::DATA_DIR_NAME);

        Self { config_dir }
    }

    /// Gets the path to the settings file
    fn settings_path(&self) -> PathBuf {
        self.config_dir.join(USER_SETTINGS_FILE)
    }

    /// Loads user settings from the config file
    /// Returns default settings if the file doesn't exist or is invalid
    pub fn load(&self) -> UserSettings {
        let path = self.settings_path();

        if !path.exists() {
            return UserSettings::default();
        }

        match fs::read_to_string(&path) {
            Ok(content) => match serde_json::from_str::<UserSettings>(&content) {
                Ok(mut settings) => {
                    settings.validate();
                    settings
                }
                Err(e) => {
                    eprintln!(
                        "[UserSettings] Failed to parse settings file: {}. Using defaults.",
                        e
                    );
                    UserSettings::default()
                }
            },
            Err(e) => {
                eprintln!(
                    "[UserSettings] Failed to read settings file: {}. Using defaults.",
                    e
                );
                UserSettings::default()
            }
        }
    }

    /// Saves user settings to the config file
    pub fn save(&self, settings: &UserSettings) -> Result<(), String> {
        // Ensure the config directory exists
        if !self.config_dir.exists() {
            fs::create_dir_all(&self.config_dir)
                .map_err(|e| format!("Failed to create config directory: {}", e))?;
        }

        // Validate settings before saving
        let mut validated_settings = settings.clone();
        validated_settings.validate();

        let content = serde_json::to_string_pretty(&validated_settings)
            .map_err(|e| format!("Failed to serialize settings: {}", e))?;

        fs::write(self.settings_path(), content)
            .map_err(|e| format!("Failed to write settings file: {}", e))?;

        Ok(())
    }
}

impl Default for UserSettingsManager {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default_settings() {
        let settings = UserSettings::default();
        assert_eq!(settings.theme_mode, "system");
        assert!((settings.dark_background_opacity - 0.70).abs() < f32::EPSILON);
        assert!((settings.light_background_opacity - 0.70).abs() < f32::EPSILON);
    }

    #[test]
    fn test_validate_clamps_values() {
        let mut settings = UserSettings {
            theme_mode: "invalid".to_string(),
            dark_background_opacity: 1.5,
            light_background_opacity: -0.5,
            ..Default::default()
        };
        settings.validate();

        assert_eq!(settings.theme_mode, "system");
        assert!((settings.dark_background_opacity - 1.0).abs() < f32::EPSILON);
        assert!(settings.light_background_opacity.abs() < f32::EPSILON);
    }

    struct TempDir(PathBuf);

    impl TempDir {
        fn new() -> Self {
            let path =
                std::env::temp_dir().join(format!("test_user_settings_{}", uuid::Uuid::new_v4()));
            fs::create_dir_all(&path).unwrap();
            Self(path)
        }

        fn manager(&self) -> UserSettingsManager {
            UserSettingsManager {
                config_dir: self.0.clone(),
            }
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn start_at_login_has_three_states_and_never_chosen_counts_as_on() {
        let mut settings = UserSettings::default();
        assert_eq!(settings.start_at_login, None);
        assert!(settings.start_at_login_wanted());
        settings.start_at_login = Some(true);
        assert!(settings.start_at_login_wanted());
        settings.start_at_login = Some(false);
        assert!(!settings.start_at_login_wanted());
    }

    #[test]
    fn an_old_settings_file_without_the_field_loads_as_never_chosen() {
        let tmp = TempDir::new();
        fs::write(
            tmp.0.join(USER_SETTINGS_FILE),
            r#"{"theme_mode":"dark","dark_background_opacity":0.5,"light_background_opacity":0.6}"#,
        )
        .unwrap();

        let settings = tmp.manager().load();
        assert_eq!(settings.theme_mode, "dark");
        assert_eq!(settings.start_at_login, None);
        assert!(settings.start_at_login_wanted());
    }

    #[test]
    fn the_start_at_login_choice_survives_a_save_and_load() {
        let tmp = TempDir::new();
        let manager = tmp.manager();
        for choice in [Some(true), Some(false), None] {
            let settings = UserSettings {
                start_at_login: choice,
                ..Default::default()
            };
            manager.save(&settings).unwrap();
            assert_eq!(manager.load().start_at_login, choice);
        }
    }
}
