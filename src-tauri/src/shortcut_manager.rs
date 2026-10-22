//! Linux Desktop Environment Shortcut Manager & Setup
//!
//! Consolidates all shortcut-related functionality into a single module:
//! - Shortcut definitions with modern `spawn-at` positioning
//! - Desktop Environment handlers (GNOME, KDE Plasma, XFCE, Cinnamon, MATE, COSMIC, LXQt, LXDE, i3, Sway, Hyprland)
//! - Global shortcut registration and unregistration
//! - Conflict detection and automatic resolution
//! - Manual setup instructions for all supported desktop environments
//! - Tauri IPC commands for onboarding wizard and settings app

use percent_encoding::{utf8_percent_encode, AsciiSet, CONTROLS};
use std::env;
use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};
use uuid::Uuid;

// Characters that need encoding in INI section names: / \ [ ] = ; # and control chars
const INI_SECTION_ENCODE: &AsciiSet = &CONTROLS
    .add(b'/')
    .add(b'\\')
    .add(b'[')
    .add(b']')
    .add(b'=')
    .add(b';')
    .add(b'#')
    .add(b' ');

/// Escape special XML characters to prevent XML injection
fn escape_xml(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}

// =============================================================================
// Configuration
// =============================================================================

#[derive(Debug, Clone)]
pub struct ShortcutConfig {
    pub id: &'static str,
    pub name: &'static str,
    pub command: &'static str,
    pub args: &'static str, // Command line arguments (e.g., "--emoji")
    pub gnome_binding: &'static str,
    pub kde_binding: &'static str,
    pub xfce_binding: &'static str,
    pub cosmic_mods: &'static str,
    pub cosmic_key: &'static str,
    // Tiling WM bindings
    pub i3_binding: &'static str,
    pub sway_binding: &'static str,
    pub hyprland_binding: &'static str,
    pub lxde_binding: &'static str,
}

impl ShortcutConfig {
    /// Returns the full command string including any arguments
    pub fn full_command(&self) -> String {
        if self.args.is_empty() {
            self.command.to_string()
        } else {
            format!("{} {}", self.command, self.args)
        }
    }
}

fn get_command_path() -> &'static str {
    // First, check if binary is in PATH (production install)
    if Utils::command_exists("win11-clipboard-history") {
        return "win11-clipboard-history";
    }

    // Try to find the current executable path (for development)
    if let Ok(exe_path) = env::current_exe() {
        let path_str = exe_path.to_string_lossy().to_string();
        // Leak the string to get a 'static lifetime
        // This is acceptable since this is called once at startup
        return Box::leak(path_str.into_boxed_str());
    }

    // Fallback to just the name
    "win11-clipboard-history"
}

/// The command string a shortcut runs: `template` (which starts with the bare `spawn-at`) with the
/// app executable substituted and the spawn-at command decided by `spawn_at_path` (full path of
/// `~/.local/bin/spawn-at` when present, as scripts/install.sh does).
fn build_shortcut_command(template: &str, app_path: &str, spawn_at: &str) -> String {
    let replaced = template.replace("win11-clipboard-history", app_path);
    match replaced.strip_prefix(crate::spawn_at_path::SPAWN_AT_NAME) {
        Some(rest) if rest.starts_with(' ') => format!("{spawn_at}{rest}"),
        _ => replaced,
    }
}

const SHORTCUTS: &[ShortcutConfig] = &[
    ShortcutConfig {
        id: "win11-clipboard-history",
        name: "Clipboard History",
        command: "spawn-at spawn --anchor cursor -o -15 -15 -m 10 win11-clipboard-history",
        args: "--clipboard",
        gnome_binding: "<Super>v",
        kde_binding: "Meta+V",
        xfce_binding: "<Super>v",
        cosmic_mods: "Super",
        cosmic_key: "v",
        i3_binding: "$mod+v",
        sway_binding: "$mod+v",
        hyprland_binding: "SUPER, V",
        lxde_binding: "W-v",
    },
    ShortcutConfig {
        id: "win11-clipboard-history-alt",
        name: "Clipboard History (Alt)",
        command: "spawn-at spawn --anchor cursor -o -15 -15 -m 10 win11-clipboard-history",
        args: "--clipboard",
        gnome_binding: "<Ctrl><Alt>v",
        kde_binding: "Ctrl+Alt+V",
        xfce_binding: "<Primary><Alt>v",
        cosmic_mods: "Ctrl, Alt",
        cosmic_key: "v",
        i3_binding: "Ctrl+Mod1+v",
        sway_binding: "Ctrl+Mod1+v",
        hyprland_binding: "CTRL ALT, V",
        lxde_binding: "C-A-v",
    },
    ShortcutConfig {
        id: "win11-clipboard-history-emoji",
        name: "Emoji Picker",
        command: "spawn-at spawn --anchor cursor -o -15 -15 -m 10 win11-clipboard-history",
        args: "--emoji",
        gnome_binding: "<Super>period",
        kde_binding: "Meta+.",
        xfce_binding: "<Super>period",
        cosmic_mods: "Super",
        cosmic_key: "period",
        i3_binding: "$mod+period",
        sway_binding: "$mod+period",
        hyprland_binding: "SUPER, period",
        lxde_binding: "W-period",
    },
];

// =============================================================================
// Error Handling
// =============================================================================

#[derive(Debug)]
pub enum ShortcutError {
    Io(io::Error),
    CommandFailed(String),
    DependencyMissing(String),
    UnsupportedEnvironment(String),
    ParseError(String),
}

impl From<io::Error> for ShortcutError {
    fn from(err: io::Error) -> Self {
        ShortcutError::Io(err)
    }
}

impl std::fmt::Display for ShortcutError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ShortcutError::Io(e) => write!(f, "I/O error: {}", e),
            ShortcutError::CommandFailed(msg) => write!(f, "Command failed: {}", msg),
            ShortcutError::DependencyMissing(dep) => write!(f, "Required tool missing: {}", dep),
            ShortcutError::UnsupportedEnvironment(env) => {
                write!(f, "Unsupported environment: {}", env)
            }
            ShortcutError::ParseError(msg) => write!(f, "Parse error: {}", msg),
        }
    }
}

impl std::error::Error for ShortcutError {}

type Result<T> = std::result::Result<T, ShortcutError>;

// =============================================================================
// Public Registration API
// =============================================================================

pub fn register_global_shortcut() {
    let handler = detect_handler();
    println!("[ShortcutManager] Detected Environment: {}", handler.name());

    let command_path = get_command_path();
    let spawn_at = crate::spawn_at_path::shell_command();
    println!("[ShortcutManager] Using command path: {} (spawn-at: {})", command_path, spawn_at);

    for shortcut in SHORTCUTS {
        // Create a new config with the correct command path
        let mut config = shortcut.clone();
        // Overwrite the base executable name but keep the spawn-at wrapper
        let replaced_cmd = build_shortcut_command(config.command, command_path, &spawn_at);
        config.command = Box::leak(replaced_cmd.into_boxed_str());

        match handler.register(&config) {
            Ok(_) => {
                println!("[ShortcutManager] \u{2713} Registered '{}'", config.name);

                // IBus binds <Super>period to its own emoji picker by default,
                // which would shadow ours; drop that entry after registering.
                if config.id == "win11-clipboard-history-emoji" {
                    crate::ibus_hotkey::ensure_super_period_removed_for_current_user();
                }
            }
            Err(e) => eprintln!("[ShortcutManager] \u{2717} Failed '{}': {}", config.name, e),
        }

        // Add a delay to prevent gsettings async race conditions where reading the
        // custom-keybindings array too quickly returns stale data, overwriting previous additions.
        if handler.name().contains("GNOME") || handler.name().contains("Cinnamon") {
            std::thread::sleep(std::time::Duration::from_millis(500));
        }
    }
}

pub fn unregister_global_shortcut() {
    let handler = detect_handler();
    println!("[ShortcutManager] Environment: {}", handler.name());

    let command_path = get_command_path();
    let spawn_at = crate::spawn_at_path::shell_command();

    for shortcut in SHORTCUTS {
        // Create a new config with the correct command path
        let mut config = shortcut.clone();
        let replaced_cmd = build_shortcut_command(config.command, command_path, &spawn_at);
        config.command = Box::leak(replaced_cmd.into_boxed_str());

        match handler.unregister(&config) {
            Ok(_) => println!("[ShortcutManager] \u{2713} Unregistered '{}'", config.name),
            Err(e) => eprintln!("[ShortcutManager] \u{2717} Failed '{}': {}", config.name, e),
        }

        // Add a delay to prevent gsettings async race conditions where reading the
        // custom-keybindings array too quickly returns stale data, overwriting previous removals.
        if handler.name().contains("GNOME") || handler.name().contains("Cinnamon") {
            std::thread::sleep(std::time::Duration::from_millis(500));
        }
    }
}

// =============================================================================
// Traits & Abstractions
// =============================================================================

trait ShortcutHandler {
    fn name(&self) -> &str;
    fn register(&self, shortcut: &ShortcutConfig) -> Result<()>;
    fn unregister(&self, shortcut: &ShortcutConfig) -> Result<()>;
}

fn detect_handler() -> Box<dyn ShortcutHandler> {
    let xdg_current = env_var("XDG_CURRENT_DESKTOP").to_lowercase();
    let xdg_session = env_var("XDG_SESSION_DESKTOP").to_lowercase();
    let combined = format!("{} {}", xdg_current, xdg_session);

    if combined.contains("gnome") || combined.contains("unity") || combined.contains("pantheon") {
        return Box::new(GnomeHandler);
    }
    if combined.contains("cinnamon") {
        return Box::new(CinnamonHandler);
    }
    // KDE Plasma 5 or 6
    if combined.contains("kde") || combined.contains("plasma") {
        return Box::new(KdeHandler);
    }
    if combined.contains("xfce") {
        return Box::new(XfceHandler);
    }
    if combined.contains("mate") {
        return Box::new(MateHandler);
    }
    if combined.contains("cosmic") {
        return Box::new(CosmicHandler);
    }
    if combined.contains("lxqt") {
        return Box::new(LxqtHandler);
    }
    if combined.contains("lxde") {
        return Box::new(LxdeHandler);
    }
    if combined.contains("budgie") {
        return Box::new(GnomeHandler); // Budgie uses gsettings like GNOME
    }
    if combined.contains("deepin") {
        return Box::new(GnomeHandler); // Deepin uses gsettings like GNOME
    }
    // Tiling Window Managers
    if combined.contains("i3") {
        return Box::new(I3Handler);
    }
    if combined.contains("sway") {
        return Box::new(SwayHandler);
    }
    if combined.contains("hyprland") {
        return Box::new(HyprlandHandler);
    }

    // Heuristic Fallback - check running processes for tiling WMs
    if is_process_running("i3") {
        return Box::new(I3Handler);
    }
    if is_process_running("sway") {
        return Box::new(SwayHandler);
    }
    if is_process_running("hyprland") || is_process_running("Hyprland") {
        return Box::new(HyprlandHandler);
    }

    // Heuristic Fallback for traditional DEs
    if Utils::command_exists("kwriteconfig5") || Utils::command_exists("kwriteconfig6") {
        return Box::new(KdeHandler);
    }
    if Utils::command_exists("xfconf-query") {
        return Box::new(XfceHandler);
    }

    // Default fallback
    Box::new(GnomeHandler)
}

fn is_process_running(name: &str) -> bool {
    Command::new("pgrep")
        .arg("-x")
        .arg(name)
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

fn env_var(key: &str) -> String {
    env::var(key).unwrap_or_default()
}

/// Check if a line contains a $mod+v or mod4+v binding with proper word boundaries.
/// This ensures we match "bindsym $mod+v" even at end of line or followed by comments.
fn has_mod_v_binding(trimmed_line: &str) -> bool {
    for pattern in &["$mod+v", "mod4+v"] {
        if let Some(idx) = trimmed_line.find(pattern) {
            // Check what follows the pattern
            let after = trimmed_line[idx + pattern.len()..].chars().next();
            // Valid word boundaries: end of string, space, tab, comment, semicolon
            if matches!(after, None | Some(' ') | Some('\t') | Some('#') | Some(';')) {
                return true;
            }
        }
    }
    false
}

// =============================================================================
// Utilities
// =============================================================================

struct Utils;

impl Utils {
    fn command_exists(cmd: &str) -> bool {
        Command::new("which")
            .arg(cmd)
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false)
    }

    fn run(cmd: &str, args: &[&str]) -> Result<String> {
        let output = Command::new(cmd).args(args).output()?;
        if output.status.success() {
            Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
        } else {
            Err(ShortcutError::CommandFailed(
                String::from_utf8_lossy(&output.stderr).to_string(),
            ))
        }
    }

    /// Atomically modifies a file using a temporary file and rename.
    ///
    /// Preserves file permissions and creates a backup of the original file.
    /// Returns `Ok(true)` if the file was modified, `Ok(false)` if no changes were needed,
    /// or an error if the operation failed.
    fn modify_file_atomic<F>(path: &Path, modify_fn: F) -> Result<bool>
    where
        F: FnOnce(&str) -> Result<Option<String>>,
    {
        // 1. Ensure parent directory exists
        if let Some(parent) = path.parent() {
            if !parent.exists() {
                fs::create_dir_all(parent)?;
            }
        }

        // 2. Read existing content or default to empty
        let (content, original_permissions) = if path.exists() {
            let content = fs::read_to_string(path)?;
            let perms = fs::metadata(path).ok().map(|m| m.permissions());
            (content, perms)
        } else {
            (String::new(), None)
        };

        // 3. Apply modification
        let new_content = match modify_fn(&content)? {
            Some(c) => c,
            None => return Ok(false), // No changes needed
        };

        // Don't write if content hasn't changed
        if new_content == content {
            return Ok(false);
        }

        let parent = path.parent().unwrap_or_else(|| Path::new("."));

        // 4. Create backup of existing file
        if path.exists() {
            let timestamp = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|d| d.as_secs())
                .unwrap_or(0);
            let backup_path = parent.join(format!(
                ".{}.backup.{}",
                path.file_name().unwrap_or_default().to_string_lossy(),
                timestamp
            ));
            // Best-effort backup - don't fail if we can't create it, but log warning
            if let Err(e) = fs::copy(path, &backup_path) {
                eprintln!(
                    "[ShortcutManager] Warning: Failed to create backup: {}",
                    e
                );
            }
        }

        // 5. Write to temporary file in the same directory (required for atomic rename)
        let temp_file_name = format!(
            ".{}.tmp.{}",
            path.file_name().unwrap_or_default().to_string_lossy(),
            Uuid::new_v4()
        );
        let temp_path = parent.join(&temp_file_name);

        // Write content and ensure it's flushed to disk
        {
            let mut file = fs::File::create(&temp_path)?;
            file.write_all(new_content.as_bytes())?;
            file.sync_all()?;
        }

        // 6. Restore original permissions if they existed, or set safe defaults (0644)
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            if let Some(perms) = original_permissions {
                let _ = fs::set_permissions(&temp_path, perms);
            } else {
                // Default to user read/write, group/others read (0644)
                let _ = fs::set_permissions(&temp_path, fs::Permissions::from_mode(0o644));
            }
        }

        // 7. Atomic rename
        if let Err(e) = fs::rename(&temp_path, path) {
            // Clean up temp file on failure
            let _ = fs::remove_file(&temp_path);
            return Err(ShortcutError::Io(e));
        }

        Ok(true)
    }
}

// =============================================================================
// GSettings Implementation (GNOME, Budgie, Deepin, Cinnamon)
// =============================================================================

struct GSettings {
    schema: &'static str,
    list_key: &'static str,
    path_prefix: &'static str,
    binding_schema: &'static str,
}

impl GSettings {
    fn new_gnome() -> Self {
        Self {
            schema: "org.gnome.settings-daemon.plugins.media-keys",
            list_key: "custom-keybindings",
            path_prefix: "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings",
            binding_schema: "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding",
        }
    }

    fn new_cinnamon() -> Self {
        Self {
            schema: "org.cinnamon.desktop.keybindings",
            list_key: "custom-list",
            path_prefix: "/org/cinnamon/desktop/keybindings/custom-keybindings",
            binding_schema: "org.cinnamon.desktop.keybindings.custom-keybinding",
        }
    }

    fn get_list(&self) -> Result<Vec<String>> {
        let output = Utils::run("gsettings", &["get", self.schema, self.list_key])?;
        let trimmed = output.trim();
        if trimmed == "@as []" || trimmed == "[]" {
            return Ok(Vec::new());
        }

        // Clean formatting: remove brackets and single quotes
        let clean = trimmed.trim_start_matches('[').trim_end_matches(']');
        let items: Vec<String> = clean
            .split(',')
            .map(|s| s.trim().trim_matches('\'').to_string())
            .filter(|s| !s.is_empty())
            .collect();

        Ok(items)
    }

    fn set_list(&self, list: &[String]) -> Result<()> {
        let formatted_items: Vec<String> = list.iter().map(|s| format!("'{}'", s)).collect();
        let formatted_list = format!("[{}]", formatted_items.join(", "));

        Utils::run(
            "gsettings",
            &["set", self.schema, self.list_key, &formatted_list],
        )
        .map(|_| ())
    }

    fn register(&self, shortcut: &ShortcutConfig, use_array_for_binding: bool) -> Result<()> {
        if !Utils::command_exists("gsettings") {
            return Err(ShortcutError::DependencyMissing("gsettings".into()));
        }

        let mut list = self.get_list()?;

        let expected_path = format!("{}/{}/", self.path_prefix, shortcut.id);
        let schema_path = format!("{}:{}", self.binding_schema, expected_path);

        let full_cmd = shortcut.full_command();
        let full_cmd_val = format!("'{}'", full_cmd);
        let name_val = format!("'{}'", shortcut.name);

        Utils::run("gsettings", &["set", &schema_path, "name", &name_val])?;
        Utils::run("gsettings", &["set", &schema_path, "command", &full_cmd_val])?;

        let binding_val = if use_array_for_binding {
            format!("['{}']", shortcut.gnome_binding)
        } else {
            format!("'{}'", shortcut.gnome_binding)
        };
        Utils::run("gsettings", &["set", &schema_path, "binding", &binding_val])?;

        let entry_check = if self.path_prefix.contains("cinnamon") {
            expected_path.split('/').filter(|s| !s.is_empty()).last().unwrap_or("").to_string()
        } else {
            expected_path.clone()
        };

        if !list.contains(&entry_check) {
            list.push(entry_check);
            self.set_list(&list)?;
        }

        Ok(())
    }

    fn unregister(&self, shortcut: &ShortcutConfig) -> Result<()> {
        if !Utils::command_exists("gsettings") {
            return Ok(());
        }

        let path = format!("{}/{}/", self.path_prefix, shortcut.id);
        let schema_path = format!("{}:{}", self.binding_schema, path);

        let _ = Utils::run("gsettings", &["reset", &schema_path, "name"]);
        let _ = Utils::run("gsettings", &["reset", &schema_path, "command"]);
        let _ = Utils::run("gsettings", &["reset", &schema_path, "binding"]);

        let mut list = self.get_list()?;
        let initial_len = list.len();
        let entry_check = if self.path_prefix.contains("cinnamon") {
            shortcut.id
        } else {
            &path
        };

        list.retain(|x| !x.contains(entry_check));

        if list.len() != initial_len {
            self.set_list(&list)?;
        }
        Ok(())
    }
}

// Wrappers
struct GnomeHandler;
impl ShortcutHandler for GnomeHandler {
    fn name(&self) -> &str {
        "GNOME/Unity"
    }
    fn register(&self, s: &ShortcutConfig) -> Result<()> {
        GSettings::new_gnome().register(s, false)
    }
    fn unregister(&self, s: &ShortcutConfig) -> Result<()> {
        GSettings::new_gnome().unregister(s)
    }
}

struct CinnamonHandler;
impl ShortcutHandler for CinnamonHandler {
    fn name(&self) -> &str {
        "Cinnamon"
    }
    fn register(&self, s: &ShortcutConfig) -> Result<()> {
        GSettings::new_cinnamon().register(s, true)
    }
    fn unregister(&self, s: &ShortcutConfig) -> Result<()> {
        GSettings::new_cinnamon().unregister(s)
    }
}

// --- KDE Plasma Logic ---

struct KdeHandler;
impl KdeHandler {
    fn get_config_path() -> Result<PathBuf> {
        let home = env::var("HOME")
            .map_err(|_| ShortcutError::UnsupportedEnvironment("HOME not set".into()))?;
        Ok(PathBuf::from(home).join(".config/khotkeysrc"))
    }

    fn reload_kde() {
        // Try both Plasma 5 and modern methods
        let _ = Utils::run(
            "qdbus",
            &[
                "org.kde.kglobalaccel",
                "/kglobalaccel",
                "org.kde.KGlobalAccel.reloadConfig",
            ],
        );
    }
}

impl ShortcutHandler for KdeHandler {
    fn name(&self) -> &str {
        "KDE Plasma"
    }

    fn register(&self, s: &ShortcutConfig) -> Result<()> {
        let path = Self::get_config_path()?;
        let section_name = format!("Data_{}", s.id.replace('-', "_"));

        Utils::modify_file_atomic(&path, |content| {
            let full_cmd = s.full_command();
            if content.contains(&format!("[{}]", section_name)) {
                let action_header = format!("[{}/Actions/Action0]", section_name);
                if content.contains(&action_header) {
                    let mut lines: Vec<String> = content.lines().map(String::from).collect();
                    let mut in_action = false;
                    let mut updated = false;
                    for line in lines.iter_mut() {
                        if line.trim() == action_header {
                            in_action = true;
                        } else if line.starts_with('[') && in_action {
                            in_action = false;
                        } else if in_action && line.starts_with("CommandURL=") {
                            let expected = format!("CommandURL={}", full_cmd);
                            if line != &expected {
                                *line = expected;
                                updated = true;
                            }
                            break;
                        }
                    }
                    if updated {
                        return Ok(Some(lines.join("\n")));
                    }
                }
                return Ok(None); // Already exists
            }

            let mut lines: Vec<String> = content.lines().map(String::from).collect();
            let mut data_count_idx = None;
            let mut data_count = 0;

            let mut in_data_group = false;

            for (i, line) in lines.iter().enumerate() {
                if line.trim() == "[Data]" {
                    in_data_group = true;
                } else if line.starts_with('[') && in_data_group {
                    in_data_group = false;
                }

                if in_data_group && line.starts_with("DataCount=") {
                    data_count_idx = Some(i);
                    if let Ok(c) = line.split('=').nth(1).unwrap_or("0").trim().parse::<u32>() {
                        data_count = c;
                    }
                    break;
                }
            }

            // Update Count
            if let Some(idx) = data_count_idx {
                lines[idx] = format!("DataCount={}", data_count + 1);
            } else {
                lines.push("[Data]".to_string());
                lines.push("DataCount=1".to_string());
            }

            // Append New Entry
            // Generate deterministic UUID v5 based on shortcut ID to ensure uniqueness per shortcut
            // but consistency across runs (idempotency)
            let namespace = Uuid::NAMESPACE_DNS;
            let uuid = Uuid::new_v5(&namespace, s.id.as_bytes()).to_string();
            let full_cmd = s.full_command();

            let entry = format!(
                "\n[{0}]\nComment={1}\nEnabled=true\nName={1}\nType=SIMPLE_ACTION_DATA\n\n[{0}/Actions]\nActionsCount=1\n\n[{0}/Actions/Action0]\nCommandURL={2}\nType=COMMAND_URL\n\n[{0}/Conditions]\nComment=\nConditionsCount=0\n\n[{0}/Triggers]\nTriggersCount=1\n\n[{0}/Triggers/Trigger0]\nKey={3}\nType=SHORTCUT\nUuid={{{4}}}\n",
                section_name, s.name, full_cmd, s.kde_binding, uuid
            );

            lines.push(entry);
            Ok(Some(lines.join("\n")))
        })?;

        Self::reload_kde();
        Ok(())
    }

    fn unregister(&self, s: &ShortcutConfig) -> Result<()> {
        let path = Self::get_config_path()?;
        let section_name = format!("Data_{}", s.id.replace('-', "_"));

        Utils::modify_file_atomic(&path, |content| {
            if !content.contains(&section_name) {
                return Ok(None);
            }

            let lines: Vec<&str> = content.lines().collect();
            let mut new_lines = Vec::new();
            let mut skip_block = false;

            for line in lines {
                if line.starts_with(&format!("[{}]", section_name)) {
                    skip_block = true;
                } else if line.starts_with('[') && skip_block {
                    // Check if it's a child subsection (start with same prefix) or new section
                    if !line.starts_with(&format!("[{}/", section_name)) {
                        skip_block = false;
                    }
                }

                if !skip_block {
                    new_lines.push(line.to_string());
                }
            }
            Ok(Some(new_lines.join("\n")))
        })?;

        Self::reload_kde();
        Ok(())
    }
}

// --- XFCE ---

struct XfceHandler;
impl ShortcutHandler for XfceHandler {
    fn name(&self) -> &str {
        "XFCE"
    }

    fn register(&self, s: &ShortcutConfig) -> Result<()> {
        if !Utils::command_exists("xfconf-query") {
            return Err(ShortcutError::DependencyMissing("xfconf-query".into()));
        }
        let property = format!("/commands/custom/{}", s.xfce_binding);

        // Check if exists to avoid error spam
        let exists = Command::new("xfconf-query")
            .args(["-c", "xfce4-keyboard-shortcuts", "-p", &property])
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false);

        if !exists {
            Utils::run(
                "xfconf-query",
                &[
                    "-c",
                    "xfce4-keyboard-shortcuts",
                    "-p",
                    &property,
                    "-n",
                    "-t",
                    "string",
                    "-s",
                    &s.full_command(),
                ],
            )?;
        } else {
            Utils::run(
                "xfconf-query",
                &[
                    "-c",
                    "xfce4-keyboard-shortcuts",
                    "-p",
                    &property,
                    "-s",
                    &s.full_command(),
                ],
            )?;
        }
        Ok(())
    }

    fn unregister(&self, s: &ShortcutConfig) -> Result<()> {
        if !Utils::command_exists("xfconf-query") {
            return Ok(());
        }
        let property = format!("/commands/custom/{}", s.xfce_binding);
        // Ignore error on unregister if it doesn't exist
        let _ = Utils::run(
            "xfconf-query",
            &["-c", "xfce4-keyboard-shortcuts", "-p", &property, "-r"],
        );
        Ok(())
    }
}

// --- MATE ---

struct MateHandler;
impl ShortcutHandler for MateHandler {
    fn name(&self) -> &str {
        "MATE"
    }
    fn register(&self, s: &ShortcutConfig) -> Result<()> {
        if !Utils::command_exists("gsettings") {
            return Err(ShortcutError::DependencyMissing("gsettings".into()));
        }

        let full_cmd = s.full_command();

        for i in 1..=12 {
            let cmd_key = format!("command-{}", i);
            let current = Utils::run(
                "gsettings",
                &["get", "org.mate.Marco.keybinding-commands", &cmd_key],
            )?;
            let current = current.trim_matches('\'');

            if current == full_cmd {
                return Ok(());
            } // Already done

            if current.contains("win11-clipboard-history") || current.is_empty() {
                let binding_key = format!("run-command-{}", i);
                let quoted_cmd = format!("'{}'", full_cmd);
                let quoted_binding = format!("'{}'", s.gnome_binding);
                Utils::run(
                    "gsettings",
                    &[
                        "set",
                        "org.mate.Marco.keybinding-commands",
                        &cmd_key,
                        &quoted_cmd,
                    ],
                )?;
                Utils::run(
                    "gsettings",
                    &[
                        "set",
                        "org.mate.Marco.global-keybindings",
                        &binding_key,
                        &quoted_binding,
                    ],
                )?;
                return Ok(());
            }
        }
        Err(ShortcutError::Io(io::Error::other(
            "MATE keybinding slots full",
        )))
    }

    fn unregister(&self, s: &ShortcutConfig) -> Result<()> {
        if !Utils::command_exists("gsettings") {
            return Ok(());
        }
        let full_cmd = s.full_command();
        for i in 1..=12 {
            let cmd_key = format!("command-{}", i);
            let current = Utils::run(
                "gsettings",
                &["get", "org.mate.Marco.keybinding-commands", &cmd_key],
            )?;

            if current.contains(&full_cmd) {
                Utils::run(
                    "gsettings",
                    &["reset", "org.mate.Marco.keybinding-commands", &cmd_key],
                )?;
                Utils::run(
                    "gsettings",
                    &[
                        "reset",
                        "org.mate.Marco.global-keybindings",
                        &format!("run-command-{}", i),
                    ],
                )?;
            }
        }
        Ok(())
    }
}

// --- COSMIC (Epoch 1.0+) ---

// Indentation constants for COSMIC RON format
const COSMIC_ENTRY_INDENT: &str = "    ";
const COSMIC_FIELD_INDENT: &str = "        ";
const COSMIC_MODIFIER_INDENT: &str = "            ";

struct CosmicHandler;
impl CosmicHandler {
    /// Escape special characters for RON string format
    fn escape_ron_string(s: &str) -> String {
        s.replace('\\', "\\\\")
            .replace('"', "\\\"")
            .replace('\n', "\\n")
            .replace('\r', "\\r")
            .replace('\t', "\\t")
    }

    /// Format modifiers for COSMIC RON format - each on its own line
    /// Input: "Super" or "Ctrl, Alt" -> properly formatted RON array entries
    fn format_modifiers(mods: &str) -> String {
        let formatted: Vec<String> = mods
            .split(',')
            .map(|m| m.trim())
            .filter(|m| !m.is_empty())
            .map(|m| {
                // Normalize modifier names to COSMIC's expected format
                let normalized: String = match m.to_lowercase().as_str() {
                    "ctrl" | "control" => "Ctrl".to_string(),
                    "alt" => "Alt".to_string(),
                    "super" | "meta" => "Super".to_string(),
                    "shift" => "Shift".to_string(),
                    _ => {
                        let mut chars = m.chars();
                        match chars.next() {
                            Some(first) => {
                                let mut result = first.to_uppercase().to_string();
                                result.push_str(&chars.as_str().to_lowercase());
                                result
                            }
                            None => String::new(),
                        }
                    }
                };
                format!("{}{},", COSMIC_MODIFIER_INDENT, normalized)
            })
            .collect();
        formatted.join("\n")
    }

    /// Build a COSMIC shortcut entry in proper RON format
    fn build_entry(s: &ShortcutConfig) -> String {
        let mods_formatted = Self::format_modifiers(s.cosmic_mods);
        let full_cmd = Self::escape_ron_string(&s.full_command());
        let name = Self::escape_ron_string(s.name);
        let key = Self::escape_ron_string(s.cosmic_key);

        format!(
            r#"{}(
{}modifiers: [
{}
{}],
{}key: "{}",
{}description: Some("{}"),
{}): Spawn("{}"),"#,
            COSMIC_ENTRY_INDENT,
            COSMIC_FIELD_INDENT,
            mods_formatted,
            COSMIC_FIELD_INDENT,
            COSMIC_FIELD_INDENT,
            key,
            COSMIC_FIELD_INDENT,
            name,
            COSMIC_ENTRY_INDENT,
            full_cmd
        )
    }
}

impl ShortcutHandler for CosmicHandler {
    fn name(&self) -> &str {
        "COSMIC (Epoch)"
    }

    fn register(&self, s: &ShortcutConfig) -> Result<()> {
        let home = env::var("HOME")
            .map_err(|_| ShortcutError::UnsupportedEnvironment("HOME not set".into()))?;
        let path = PathBuf::from(home)
            .join(".config/cosmic/com.system76.CosmicSettings.Shortcuts/v1/custom");

        let full_cmd = s.full_command();
        let entry = Self::build_entry(s);

        Utils::modify_file_atomic(&path, |content| {
            if content.contains(&format!("Spawn(\"{}\")", full_cmd)) {
                return Ok(None);
            }

            let trimmed = content.trim();

            if trimmed.is_empty() {
                return Ok(Some(format!("{{\n{}\n}}", entry)));
            }

            if !trimmed.starts_with('{') {
                return Err(ShortcutError::ParseError(
                    "Invalid COSMIC config format - expected RON map starting with '{'".into(),
                ));
            }

            if let Some(pos) = content.rfind('}') {
                let mut new_content = content.to_string();
                new_content.insert_str(pos, &format!("{}\n", entry));
                return Ok(Some(new_content));
            }

            Err(ShortcutError::ParseError(
                "Invalid COSMIC config format - missing closing brace".into(),
            ))
        })?;
        Ok(())
    }

    fn unregister(&self, s: &ShortcutConfig) -> Result<()> {
        let home = env::var("HOME").unwrap_or_default();
        let path = PathBuf::from(home)
            .join(".config/cosmic/com.system76.CosmicSettings.Shortcuts/v1/custom");

        if !path.exists() {
            return Ok(());
        }

        let full_cmd = s.full_command();
        let spawn_pattern = format!("Spawn(\"{}\")", full_cmd);

        Utils::modify_file_atomic(&path, |content| {
            if !content.contains(&spawn_pattern) {
                return Ok(None);
            }

            let mut result = String::new();
            let mut depth = 0;
            let mut in_entry = false;
            let mut entry_start = 0;
            let mut prev_depth: i32;

            for c in content.chars() {
                prev_depth = depth;

                if c == '{' || c == '(' {
                    depth += 1;
                } else if c == '}' || c == ')' {
                    depth -= 1;
                }

                if c == '(' && prev_depth == 1 && depth == 2 {
                    entry_start = result.len();
                    in_entry = true;
                }

                result.push(c);

                if in_entry && depth == 1 && c == ',' {
                    let entry_content = &result[entry_start..];
                    if entry_content.contains(&spawn_pattern) {
                        let trim_start = result[..entry_start].trim_end().len();
                        result.truncate(trim_start);
                        result.push('\n');
                    }
                    in_entry = false;
                }
            }

            let mut cleaned = String::with_capacity(result.len());
            let mut newline_count = 0;
            for ch in result.chars() {
                if ch == '\n' {
                    if newline_count < 2 {
                        cleaned.push('\n');
                    }
                    newline_count += 1;
                } else {
                    newline_count = 0;
                    cleaned.push(ch);
                }
            }

            Ok(Some(cleaned))
        })?;
        Ok(())
    }
}

// --- LXQt ---

struct LxqtHandler;
impl ShortcutHandler for LxqtHandler {
    fn name(&self) -> &str {
        "LXQt"
    }

    fn register(&self, s: &ShortcutConfig) -> Result<()> {
        let home = env::var("HOME")
            .map_err(|_| ShortcutError::UnsupportedEnvironment("HOME not set".into()))?;
        let path = PathBuf::from(home).join(".config/lxqt/globalkeyshortcuts.conf");

        let full_cmd = s.full_command();
        let encoded_binding = utf8_percent_encode(s.kde_binding, INI_SECTION_ENCODE).to_string();
        let section = format!("{}/{}", encoded_binding, s.id);
        let entry = format!(
            "\n[{}]\nComment={}\nEnabled=true\nExec={}",
            section, s.name, full_cmd
        );

        Utils::modify_file_atomic(&path, |content| {
            if content.contains(&format!("[{}]", section)) {
                let mut lines: Vec<String> = content.lines().map(String::from).collect();
                let mut in_section = false;
                let mut updated = false;
                for line in lines.iter_mut() {
                    if line.trim() == format!("[{}]", section) {
                        in_section = true;
                    } else if line.starts_with('[') && in_section {
                        in_section = false;
                    } else if in_section && line.starts_with("Exec=") {
                        let expected = format!("Exec={}", full_cmd);
                        if line != &expected {
                            *line = expected;
                            updated = true;
                        }
                        break;
                    }
                }
                if updated {
                    return Ok(Some(lines.join("\n")));
                }
                return Ok(None); // Already exists
            }

            let mut new_content = content.to_string();
            new_content.push_str(&entry);
            Ok(Some(new_content))
        })?;
        Ok(())
    }

    fn unregister(&self, s: &ShortcutConfig) -> Result<()> {
        let home = env::var("HOME")
            .map_err(|_| ShortcutError::UnsupportedEnvironment("HOME not set".into()))?;
        let path = PathBuf::from(home).join(".config/lxqt/globalkeyshortcuts.conf");

        if !path.exists() {
            return Ok(());
        }

        let encoded_binding = utf8_percent_encode(s.kde_binding, INI_SECTION_ENCODE).to_string();
        let section = format!("{}/{}", encoded_binding, s.id);

        Utils::modify_file_atomic(&path, |content| {
            if !content.contains(&format!("[{}]", section)) {
                return Ok(None);
            }

            let lines: Vec<&str> = content.lines().collect();
            let mut new_lines = Vec::new();
            let mut skip_block = false;

            for line in lines {
                if line.trim() == format!("[{}]", section) {
                    skip_block = true;
                    continue;
                }
                if line.starts_with('[') && skip_block {
                    skip_block = false;
                }
                if !skip_block {
                    new_lines.push(line.to_string());
                }
            }
            Ok(Some(new_lines.join("\n")))
        })?;
        Ok(())
    }
}

// --- LXDE (Openbox) ---

struct LxdeHandler;
impl ShortcutHandler for LxdeHandler {
    fn name(&self) -> &str {
        "LXDE/Openbox"
    }

    fn register(&self, s: &ShortcutConfig) -> Result<()> {
        let home = env::var("HOME")
            .map_err(|_| ShortcutError::UnsupportedEnvironment("HOME not set".into()))?;

        let path = PathBuf::from(&home).join(".config/openbox/lxde-rc.xml");
        let path = if path.exists() {
            path
        } else {
            PathBuf::from(&home).join(".config/openbox/rc.xml")
        };

        if !path.exists() {
            return Err(ShortcutError::Io(io::Error::new(
                io::ErrorKind::NotFound,
                "Openbox config not found",
            )));
        }

        let full_cmd = s.full_command();
        let escaped_binding = escape_xml(s.lxde_binding);
        let escaped_cmd = escape_xml(&full_cmd);
        let keybind = format!(
            r#"    <keybind key="{}">
      <action name="Execute">
        <command>{}</command>
      </action>
    </keybind>"#,
            escaped_binding, escaped_cmd
        );

        Utils::modify_file_atomic(&path, |content| {
            if content.contains(&format!("<command>{}</command>", escaped_cmd)) {
                return Ok(None); // Already exists
            }

            if let Some(pos) = content.find("</keyboard>") {
                let mut new_content = content.to_string();
                new_content.insert_str(pos, &format!("{}\n  ", keybind));
                let _ = Utils::run("openbox", &["--reconfigure"]);
                return Ok(Some(new_content));
            }

            Err(ShortcutError::ParseError(
                "Could not find </keyboard> in Openbox config".into(),
            ))
        })?;
        Ok(())
    }

    fn unregister(&self, s: &ShortcutConfig) -> Result<()> {
        let home = env::var("HOME")
            .map_err(|_| ShortcutError::UnsupportedEnvironment("HOME not set".into()))?;

        let path = PathBuf::from(&home).join(".config/openbox/lxde-rc.xml");
        let path = if path.exists() {
            path
        } else {
            PathBuf::from(&home).join(".config/openbox/rc.xml")
        };

        if !path.exists() {
            return Ok(());
        }

        let full_cmd = s.full_command();
        let escaped_binding = escape_xml(s.lxde_binding);
        let escaped_cmd = escape_xml(&full_cmd);

        Utils::modify_file_atomic(&path, |content| {
            if !content.contains(&format!("<command>{}</command>", escaped_cmd)) {
                return Ok(None);
            }

            let pattern = format!(
                r#"    <keybind key="{}">
      <action name="Execute">
        <command>{}</command>
      </action>
    </keybind>"#,
                escaped_binding, escaped_cmd
            );

            let new_content = content.replace(&pattern, "");
            let _ = Utils::run("openbox", &["--reconfigure"]);
            Ok(Some(new_content))
        })?;
        Ok(())
    }
}

// --- i3 Window Manager ---

struct I3Handler;
impl I3Handler {
    fn get_config_path() -> Result<PathBuf> {
        let home = env::var("HOME")
            .map_err(|_| ShortcutError::UnsupportedEnvironment("HOME not set".into()))?;

        let paths = vec![
            PathBuf::from(&home).join(".config/i3/config"),
            PathBuf::from(&home).join(".i3/config"),
        ];

        for path in paths {
            if path.exists() {
                return Ok(path);
            }
        }

        Ok(PathBuf::from(&home).join(".config/i3/config"))
    }

    fn reload_i3() {
        let _ = Utils::run("i3-msg", &["reload"]);
    }
}

impl ShortcutHandler for I3Handler {
    fn name(&self) -> &str {
        "i3"
    }

    fn register(&self, s: &ShortcutConfig) -> Result<()> {
        let path = Self::get_config_path()?;

        let full_cmd = s.full_command();
        let binding_line = format!("bindsym {} exec {}", s.i3_binding, full_cmd);

        let modified = Utils::modify_file_atomic(&path, |content| {
            if content.contains(&full_cmd) {
                return Ok(None);
            }

            let mut lines: Vec<String> = content.lines().map(String::from).collect();
            let mut updated_existing = false;

            for line in lines.iter_mut() {
                if line.contains("win11-clipboard-history")
                    && line.contains("bindsym")
                    && line.contains(s.i3_binding)
                {
                    *line = binding_line.clone();
                    updated_existing = true;
                    break;
                }
            }

            if updated_existing {
                return Ok(Some(lines.join("\n")));
            }

            let mut had_existing = false;

            for line in lines.iter_mut() {
                let trimmed = line.trim().to_lowercase();
                if trimmed.starts_with('#') {
                    continue;
                }
                if trimmed.starts_with("bindsym") && has_mod_v_binding(&trimmed) {
                    *line = format!("# {} # Commented by win11-clipboard-history", line);
                    had_existing = true;
                }
            }

            lines.push("\n# Clipboard History (added by win11-clipboard-history)".to_string());
            lines.push(binding_line.clone());

            if had_existing {
                println!("[i3Handler] Commented out existing $mod+v binding(s)");
            }

            Ok(Some(lines.join("\n")))
        })?;

        if modified {
            Self::reload_i3();
        }
        Ok(())
    }

    fn unregister(&self, s: &ShortcutConfig) -> Result<()> {
        let path = Self::get_config_path()?;

        if !path.exists() {
            return Ok(());
        }

        let full_cmd = s.full_command();
        let modified = Utils::modify_file_atomic(&path, |content| {
            if !content.contains(&full_cmd) {
                return Ok(None);
            }

            let lines: Vec<&str> = content.lines().collect();
            let mut new_lines: Vec<String> = Vec::new();
            let mut skip_comment = false;

            for line in lines {
                if line.contains("# Clipboard History (added by win11-clipboard-history)") {
                    skip_comment = true;
                    continue;
                }
                if skip_comment && line.contains(&full_cmd) {
                    skip_comment = false;
                    continue;
                }
                skip_comment = false;

                if line.contains("# Commented by win11-clipboard-history") {
                    let restored = line
                        .replace("# ", "")
                        .replace(" # Commented by win11-clipboard-history", "");
                    new_lines.push(restored);
                } else {
                    new_lines.push(line.to_string());
                }
            }

            Ok(Some(new_lines.join("\n")))
        })?;

        if modified {
            Self::reload_i3();
        }
        Ok(())
    }
}

// --- Sway ---

struct SwayHandler;
impl SwayHandler {
    fn get_config_path() -> Result<PathBuf> {
        let home = env::var("HOME")
            .map_err(|_| ShortcutError::UnsupportedEnvironment("HOME not set".into()))?;

        let paths = vec![
            PathBuf::from(&home).join(".config/sway/config"),
            PathBuf::from(&home).join(".sway/config"),
        ];

        for path in paths {
            if path.exists() {
                return Ok(path);
            }
        }

        Ok(PathBuf::from(&home).join(".config/sway/config"))
    }

    fn reload_sway() {
        let _ = Utils::run("swaymsg", &["reload"]);
    }
}

impl ShortcutHandler for SwayHandler {
    fn name(&self) -> &str {
        "Sway"
    }

    fn register(&self, s: &ShortcutConfig) -> Result<()> {
        let path = Self::get_config_path()?;

        let full_cmd = s.full_command();
        let binding_line = format!("bindsym {} exec {}", s.sway_binding, full_cmd);

        let modified = Utils::modify_file_atomic(&path, |content| {
            if content.contains(&full_cmd) {
                return Ok(None);
            }

            let mut lines: Vec<String> = content.lines().map(String::from).collect();
            let mut updated_existing = false;

            for line in lines.iter_mut() {
                if line.contains("win11-clipboard-history")
                    && line.contains("bindsym")
                    && line.contains(s.sway_binding)
                {
                    *line = binding_line.clone();
                    updated_existing = true;
                    break;
                }
            }

            if updated_existing {
                return Ok(Some(lines.join("\n")));
            }

            let mut had_existing = false;

            for line in lines.iter_mut() {
                let trimmed = line.trim().to_lowercase();
                if trimmed.starts_with('#') {
                    continue;
                }
                if trimmed.starts_with("bindsym") && has_mod_v_binding(&trimmed) {
                    *line = format!("# {} # Commented by win11-clipboard-history", line);
                    had_existing = true;
                }
            }

            lines.push("\n# Clipboard History (added by win11-clipboard-history)".to_string());
            lines.push(binding_line.clone());

            if had_existing {
                println!("[SwayHandler] Commented out existing $mod+v binding(s)");
            }

            Ok(Some(lines.join("\n")))
        })?;

        if modified {
            Self::reload_sway();
        }
        Ok(())
    }

    fn unregister(&self, s: &ShortcutConfig) -> Result<()> {
        let path = Self::get_config_path()?;

        if !path.exists() {
            return Ok(());
        }

        let full_cmd = s.full_command();
        let modified = Utils::modify_file_atomic(&path, |content| {
            if !content.contains(&full_cmd) {
                return Ok(None);
            }

            let lines: Vec<&str> = content.lines().collect();
            let mut new_lines: Vec<String> = Vec::new();
            let mut skip_comment = false;

            for line in lines {
                if line.contains("# Clipboard History (added by win11-clipboard-history)") {
                    skip_comment = true;
                    continue;
                }
                if skip_comment && line.contains(&full_cmd) {
                    skip_comment = false;
                    continue;
                }
                skip_comment = false;

                if line.contains("# Commented by win11-clipboard-history") {
                    let restored = line
                        .replace("# ", "")
                        .replace(" # Commented by win11-clipboard-history", "");
                    new_lines.push(restored);
                } else {
                    new_lines.push(line.to_string());
                }
            }

            Ok(Some(new_lines.join("\n")))
        })?;

        if modified {
            Self::reload_sway();
        }
        Ok(())
    }
}

// --- Hyprland ---

struct HyprlandHandler;
impl HyprlandHandler {
    fn get_config_path() -> Result<PathBuf> {
        let home = env::var("HOME")
            .map_err(|_| ShortcutError::UnsupportedEnvironment("HOME not set".into()))?;

        let xdg_config =
            env::var("XDG_CONFIG_HOME").unwrap_or_else(|_| format!("{}/.config", home));

        let path = PathBuf::from(&xdg_config).join("hypr/hyprland.conf");
        Ok(path)
    }
}

impl ShortcutHandler for HyprlandHandler {
    fn name(&self) -> &str {
        "Hyprland"
    }

    fn register(&self, s: &ShortcutConfig) -> Result<()> {
        let path = Self::get_config_path()?;

        let full_cmd = s.full_command();
        let binding_line = format!("bind = {}, exec, {}", s.hyprland_binding, full_cmd);

        Utils::modify_file_atomic(&path, |content| {
            if content.contains(&full_cmd) {
                return Ok(None);
            }

            let mut lines: Vec<String> = content.lines().map(String::from).collect();
            let mut updated_existing = false;

            for line in lines.iter_mut() {
                if line.contains("win11-clipboard-history")
                    && line.contains("bind")
                    && line.contains(&s.hyprland_binding)
                {
                    *line = binding_line.clone();
                    updated_existing = true;
                    break;
                }
            }

            if updated_existing {
                return Ok(Some(lines.join("\n")));
            }

            let mut modified = false;

            for line in lines.iter_mut() {
                let trimmed = line.trim().to_lowercase();
                if trimmed.starts_with('#') {
                    continue;
                }
                if trimmed.starts_with("bind")
                    && trimmed.contains("super")
                    && (trimmed.contains(", v,") || trimmed.contains(",v,"))
                {
                    *line = format!("# {} # Commented by win11-clipboard-history", line);
                    modified = true;
                }
            }

            lines.push("\n# Clipboard History (added by win11-clipboard-history)".to_string());
            lines.push(binding_line.clone());

            if modified {
                println!("[HyprlandHandler] Commented out existing SUPER+V binding(s)");
            }

            Ok(Some(lines.join("\n")))
        })?;
        Ok(())
    }

    fn unregister(&self, s: &ShortcutConfig) -> Result<()> {
        let path = Self::get_config_path()?;

        if !path.exists() {
            return Ok(());
        }

        let full_cmd = s.full_command();
        Utils::modify_file_atomic(&path, |content| {
            if !content.contains(&full_cmd) {
                return Ok(None);
            }

            let lines: Vec<&str> = content.lines().collect();
            let mut new_lines: Vec<String> = Vec::new();
            let mut skip_comment = false;

            for line in lines {
                if line.contains("# Clipboard History (added by win11-clipboard-history)") {
                    skip_comment = true;
                    continue;
                }
                if skip_comment && line.contains(&full_cmd) {
                    skip_comment = false;
                    continue;
                }
                skip_comment = false;

                if line.contains("# Commented by win11-clipboard-history") {
                    let restored = line
                        .replace("# ", "")
                        .replace(" # Commented by win11-clipboard-history", "");
                    new_lines.push(restored);
                } else {
                    new_lines.push(line.to_string());
                }
            }

            Ok(Some(new_lines.join("\n")))
        })?;
        Ok(())
    }
}

// =============================================================================
// Conflict Detection & Resolution
// =============================================================================

/// Represents a detected shortcut conflict
#[derive(Debug, Clone, serde::Serialize)]
pub struct ShortcutConflict {
    /// The shortcut binding that conflicts (e.g., "Super+V")
    pub binding: String,
    /// What the shortcut currently does
    pub current_action: String,
    /// The desktop environment or application that owns this shortcut
    pub owner: String,
    /// Command or instructions to resolve the conflict
    pub resolution_command: Option<String>,
    /// Human-readable resolution steps
    pub resolution_steps: String,
}

/// Result of conflict detection for all shortcuts
#[derive(Debug, Clone, serde::Serialize)]
pub struct ConflictDetectionResult {
    /// Desktop environment detected
    pub desktop_environment: String,
    /// List of detected conflicts
    pub conflicts: Vec<ShortcutConflict>,
    /// Whether automatic resolution is possible
    pub can_auto_resolve: bool,
    /// General message about conflicts
    pub message: String,
}

/// Main entry point for conflict detection
pub fn detect_shortcut_conflicts() -> ConflictDetectionResult {
    let de = get_desktop_environment();
    let conflicts = match de.as_str() {
        "GNOME" => detect_gnome_conflicts(),
        "Pop" | "Pop!_OS" => detect_pop_shell_conflicts(),
        "COSMIC" => detect_cosmic_conflicts(),
        "KDE Plasma" => detect_kde_conflicts(),
        "i3" | "i3wm" => detect_i3_conflicts(),
        "Sway" => detect_sway_conflicts(),
        "Hyprland" => detect_hyprland_conflicts(),
        "Cinnamon" => detect_cinnamon_conflicts(),
        "XFCE" => detect_xfce_conflicts(),
        _ => Vec::new(),
    };

    let can_auto_resolve =
        !conflicts.is_empty() && conflicts.iter().all(|c| c.resolution_command.is_some());
    let message = if conflicts.is_empty() {
        "No shortcut conflicts detected.".to_string()
    } else {
        format!(
            "{} shortcut conflict(s) detected that may prevent Super+V from working.",
            conflicts.len()
        )
    };

    ConflictDetectionResult {
        desktop_environment: de,
        conflicts,
        can_auto_resolve,
        message,
    }
}

/// Resolve all detected conflicts automatically where possible
pub fn auto_resolve_conflicts() -> std::result::Result<Vec<String>, String> {
    let result = detect_shortcut_conflicts();
    let mut resolved = Vec::new();

    for conflict in result.conflicts {
        if let Some(cmd) = conflict.resolution_command {
            match run_resolution_command(&cmd) {
                Ok(_) => resolved.push(format!(
                    "Resolved: {} ({})",
                    conflict.owner, conflict.binding
                )),
                Err(e) => return Err(format!("Failed to resolve {}: {}", conflict.owner, e)),
            }
        }
    }

    Ok(resolved)
}

fn run_resolution_command(cmd: &str) -> std::result::Result<(), String> {
    let output = Command::new("sh")
        .arg("-c")
        .arg(cmd)
        .output()
        .map_err(|e| e.to_string())?;

    if output.status.success() {
        Ok(())
    } else {
        Err(String::from_utf8_lossy(&output.stderr).to_string())
    }
}

fn gsettings_get(schema: &str, key: &str) -> Option<String> {
    if !Utils::command_exists("gsettings") {
        return None;
    }
    Command::new("gsettings")
        .args(["get", schema, key])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
}

// GNOME Conflicts
fn detect_gnome_conflicts() -> Vec<ShortcutConflict> {
    let mut conflicts = Vec::new();

    if let Some(binding) = gsettings_get("org.gnome.shell.keybindings", "toggle-message-tray") {
        let binding_lower = binding.to_lowercase();
        if binding_lower.contains("super") && binding_lower.contains("v") {
            conflicts.push(ShortcutConflict {
                binding: "<Super>v".to_string(),
                current_action: "Open Notification Center / Message Tray".to_string(),
                owner: "GNOME Shell".to_string(),
                resolution_command: Some(
                    "gsettings set org.gnome.shell.keybindings toggle-message-tray \"['<Super><Shift>v']\"".to_string()
                ),
                resolution_steps: r#"**To resolve manually:**
1. Open Settings → Keyboard → Keyboard Shortcuts
2. Search for "Notification" or "Message Tray"
3. Change Super+V to Super+Shift+V (or disable it)

**Or run this command:**
```
gsettings set org.gnome.shell.keybindings toggle-message-tray "['<Super><Shift>v']"
```"#.to_string(),
            });
        }
    }

    if let Some(binding) = gsettings_get("org.gnome.shell.keybindings", "toggle-quick-settings") {
        let binding_lower = binding.to_lowercase();
        if binding_lower.contains("super") && binding_lower.contains("v") {
            conflicts.push(ShortcutConflict {
                binding: "<Super>v".to_string(),
                current_action: "Toggle Quick Settings".to_string(),
                owner: "GNOME Shell".to_string(),
                resolution_command: Some(
                    "gsettings set org.gnome.shell.keybindings toggle-quick-settings \"[]\""
                        .to_string(),
                ),
                resolution_steps:
                    "Disable the Quick Settings shortcut in GNOME Settings → Keyboard → Shortcuts"
                        .to_string(),
            });
        }
    }

    conflicts
}

// Pop!_OS Conflicts
fn detect_pop_shell_conflicts() -> Vec<ShortcutConflict> {
    let mut conflicts = Vec::new();
    conflicts.extend(detect_gnome_conflicts());

    if let Some(binding) = gsettings_get("org.gnome.shell.extensions.pop-shell", "tile-enter") {
        let binding_lower = binding.to_lowercase();
        if binding_lower.contains("super") && binding_lower.contains("v") {
            conflicts.push(ShortcutConflict {
                binding: "<Super>v".to_string(),
                current_action: "Enter Tiling Mode".to_string(),
                owner: "Pop Shell".to_string(),
                resolution_command: Some(
                    "gsettings set org.gnome.shell.extensions.pop-shell tile-enter \"['<Super><Shift>v']\"".to_string()
                ),
                resolution_steps: r#"**To resolve manually:**
1. Open Pop!_OS Settings → Keyboard → Customize Shortcuts
2. Find "Pop Shell: Enter Tile Mode"
3. Change it to a different binding

**Or run:**
```
gsettings set org.gnome.shell.extensions.pop-shell tile-enter "['<Super><Shift>v']"
```"#.to_string(),
            });
        }
    }

    conflicts
}

// COSMIC Conflicts
fn detect_cosmic_conflicts() -> Vec<ShortcutConflict> {
    let mut conflicts = Vec::new();

    let home = match env::var("HOME") {
        Ok(h) => h,
        Err(_) => return conflicts,
    };

    let shortcuts_path =
        PathBuf::from(&home).join(".config/cosmic/com.system76.CosmicSettings.Shortcuts/v1/custom");

    if let Ok(content) = fs::read_to_string(&shortcuts_path) {
        if content.to_lowercase().contains("super")
            && content.to_lowercase().contains("\"v\"")
            && !content.contains("win11-clipboard-history")
        {
            conflicts.push(ShortcutConflict {
                binding: "Super+V".to_string(),
                current_action: "Unknown COSMIC shortcut".to_string(),
                owner: "COSMIC Desktop".to_string(),
                resolution_command: None,
                resolution_steps: r#"**To resolve manually:**
1. Open COSMIC Settings → Keyboard → Shortcuts
2. Find any shortcut using Super+V
3. Change it to a different binding or remove it"#
                    .to_string(),
            });
        }
    }

    let system_shortcuts = PathBuf::from(&home)
        .join(".config/cosmic/com.system76.CosmicSettings.Shortcuts/v1/system_actions");

    if let Ok(content) = fs::read_to_string(&system_shortcuts) {
        if content.to_lowercase().contains("super") && content.to_lowercase().contains("\"v\"") {
            conflicts.push(ShortcutConflict {
                binding: "Super+V".to_string(),
                current_action: "COSMIC System Action".to_string(),
                owner: "COSMIC Desktop".to_string(),
                resolution_command: None,
                resolution_steps: r#"**COSMIC System Shortcut Conflict:**
1. Open COSMIC Settings → Keyboard → Shortcuts → System
2. Find the Super+V binding
3. Change or disable it"#
                    .to_string(),
            });
        }
    }

    conflicts
}

// KDE Conflicts
fn detect_kde_conflicts() -> Vec<ShortcutConflict> {
    let mut conflicts = Vec::new();

    let home = match env::var("HOME") {
        Ok(h) => h,
        Err(_) => return conflicts,
    };

    let shortcuts_path = PathBuf::from(&home).join(".config/kglobalshortcutsrc");

    if let Ok(content) = fs::read_to_string(&shortcuts_path) {
        for line in content.lines() {
            if line.contains("Meta+V") || line.contains("Meta+v") {
                if let Some(action) = extract_kde_action(&content, line) {
                    if action.contains("clipboard-history") || action.contains("win11") {
                        continue;
                    }

                    conflicts.push(ShortcutConflict {
                        binding: "Meta+V".to_string(),
                        current_action: action.clone(),
                        owner: "KDE Plasma".to_string(),
                        resolution_command: None,
                        resolution_steps: format!(
                            r#"**To resolve manually:**
1. Open System Settings → Shortcuts → Global Shortcuts
2. Find "{}"
3. Change or clear the Meta+V binding

**Alternative:** Use the search function to find "Meta+V" bindings"#,
                            action
                        ),
                    });
                }
            }
        }
    }

    let klipper_path = PathBuf::from(&home).join(".config/klipperrc");
    if klipper_path.exists() {
        if let Ok(content) = fs::read_to_string(&klipper_path) {
            if content.contains("Meta+V") {
                conflicts.push(ShortcutConflict {
                    binding: "Meta+V".to_string(),
                    current_action: "Klipper Clipboard History".to_string(),
                    owner: "Klipper".to_string(),
                    resolution_command: None,
                    resolution_steps: r#"**Klipper Conflict:**
KDE's built-in clipboard manager (Klipper) may use Meta+V.

1. Right-click the Klipper icon in the system tray
2. Click "Configure Klipper"
3. Go to "Shortcuts" and change or disable the shortcut

**Alternatively:** Disable Klipper entirely if you prefer this app."#
                        .to_string(),
                });
            }
        }
    }

    conflicts
}

fn extract_kde_action(content: &str, target_line: &str) -> Option<String> {
    let lines: Vec<&str> = content.lines().collect();
    let mut current_section = String::new();

    for line in lines {
        if line.starts_with('[') && line.ends_with(']') {
            current_section = line[1..line.len() - 1].to_string();
        }
        if line == target_line {
            if let Some(eq_pos) = line.find('=') {
                let action_part = &line[..eq_pos];
                return Some(format!("{}: {}", current_section, action_part));
            }
            return Some(current_section);
        }
    }
    None
}

// i3 Conflicts
fn detect_i3_conflicts() -> Vec<ShortcutConflict> {
    let mut conflicts = Vec::new();
    let config_paths = get_i3_config_paths();

    for path in config_paths {
        if let Ok(content) = fs::read_to_string(&path) {
            for line in content.lines() {
                let line_lower = line.to_lowercase().trim().to_string();

                if line_lower.starts_with('#') {
                    continue;
                }

                if (line_lower.contains("bindsym") || line_lower.contains("bindcode"))
                    && (line_lower.contains("mod4+v") || line_lower.contains("$mod+v"))
                    && !line_lower.contains("clipboard-history")
                    && !line_lower.contains("win11")
                {
                    let action = line
                        .split_whitespace()
                        .skip(2)
                        .collect::<Vec<_>>()
                        .join(" ");

                    conflicts.push(ShortcutConflict {
                        binding: "$mod+v / Mod4+v".to_string(),
                        current_action: if action.is_empty() {
                            "Unknown action".to_string()
                        } else {
                            action
                        },
                        owner: "i3 config".to_string(),
                        resolution_command: None,
                        resolution_steps: format!(
                            r#"**i3 Config Conflict:**
Found in: {}

**To resolve:**
1. Edit your i3 config: `{}`
2. Find the line with `bindsym $mod+v` or `bindsym Mod4+v`
3. Change it to a different binding or comment it out

**Then add:**
```
bindsym $mod+v exec spawn-at spawn --anchor cursor -o -15 -15 -m 10 win11-clipboard-history --clipboard
```

4. Reload i3: Press $mod+Shift+r"#,
                            path.display(),
                            path.display()
                        ),
                    });
                }
            }
        }
    }

    conflicts
}

fn get_i3_config_paths() -> Vec<PathBuf> {
    let home = env::var("HOME").unwrap_or_default();
    vec![
        PathBuf::from(&home).join(".config/i3/config"),
        PathBuf::from(&home).join(".i3/config"),
        PathBuf::from("/etc/i3/config"),
    ]
}

// Sway Conflicts
fn detect_sway_conflicts() -> Vec<ShortcutConflict> {
    let mut conflicts = Vec::new();
    let config_paths = get_sway_config_paths();

    for path in config_paths {
        if let Ok(content) = fs::read_to_string(&path) {
            for line in content.lines() {
                let line_lower = line.to_lowercase().trim().to_string();

                if line_lower.starts_with('#') {
                    continue;
                }

                if (line_lower.contains("bindsym") || line_lower.contains("bindcode"))
                    && (line_lower.contains("mod4+v") || line_lower.contains("$mod+v"))
                    && !line_lower.contains("clipboard-history")
                    && !line_lower.contains("win11")
                {
                    let action = line
                        .split_whitespace()
                        .skip(2)
                        .collect::<Vec<_>>()
                        .join(" ");

                    conflicts.push(ShortcutConflict {
                        binding: "$mod+v / Mod4+v".to_string(),
                        current_action: if action.is_empty() {
                            "Unknown action".to_string()
                        } else {
                            action
                        },
                        owner: "Sway config".to_string(),
                        resolution_command: None,
                        resolution_steps: format!(
                            r#"**Sway Config Conflict:**
Found in: {}

**To resolve:**
1. Edit your Sway config: `{}`
2. Find the line with `bindsym $mod+v`
3. Change it to a different binding or comment it out

**Then add:**
```
bindsym $mod+v exec spawn-at spawn --anchor cursor -o -15 -15 -m 10 win11-clipboard-history --clipboard
```

4. Reload Sway: Press $mod+Shift+c"#,
                            path.display(),
                            path.display()
                        ),
                    });
                }
            }
        }
    }

    conflicts
}

fn get_sway_config_paths() -> Vec<PathBuf> {
    let home = env::var("HOME").unwrap_or_default();
    vec![
        PathBuf::from(&home).join(".config/sway/config"),
        PathBuf::from(&home).join(".sway/config"),
        PathBuf::from("/etc/sway/config"),
    ]
}

// Hyprland Conflicts
fn detect_hyprland_conflicts() -> Vec<ShortcutConflict> {
    let mut conflicts = Vec::new();
    let config_paths = get_hyprland_config_paths();

    for path in config_paths {
        if let Ok(content) = fs::read_to_string(&path) {
            for line in content.lines() {
                let line_lower = line.to_lowercase().trim().to_string();

                if line_lower.starts_with('#') {
                    continue;
                }

                if line_lower.starts_with("bind")
                    && line_lower.contains("super")
                    && (line_lower.contains(", v,") || line_lower.contains(",v,"))
                    && !line_lower.contains("clipboard-history")
                    && !line_lower.contains("win11")
                {
                    let parts: Vec<&str> = line.split(',').collect();
                    let action = if parts.len() >= 4 {
                        parts[3..].join(",").trim().to_string()
                    } else {
                        "Unknown action".to_string()
                    };

                    conflicts.push(ShortcutConflict {
                        binding: "SUPER, V".to_string(),
                        current_action: action,
                        owner: "Hyprland config".to_string(),
                        resolution_command: None,
                        resolution_steps: format!(
                            r#"**Hyprland Config Conflict:**
Found in: {}

**To resolve:**
1. Edit your Hyprland config: `{}`
2. Find the line with `bind = SUPER, V, ...`
3. Change it to a different binding or comment it out

**Then add:**
```
bind = SUPER, V, exec, spawn-at spawn --anchor cursor -o -15 -15 -m 10 win11-clipboard-history --clipboard
```

4. The config auto-reloads, or reload manually"#,
                            path.display(),
                            path.display()
                        ),
                    });
                }
            }
        }
    }

    conflicts
}

fn get_hyprland_config_paths() -> Vec<PathBuf> {
    let home = env::var("HOME").unwrap_or_default();
    let xdg_config = env::var("XDG_CONFIG_HOME").unwrap_or_else(|_| format!("{}/.config", home));

    vec![
        PathBuf::from(&xdg_config).join("hypr/hyprland.conf"),
        PathBuf::from(&home).join(".config/hypr/hyprland.conf"),
    ]
}

// Cinnamon Conflicts
fn detect_cinnamon_conflicts() -> Vec<ShortcutConflict> {
    let mut conflicts = Vec::new();

    if let Some(binding) = gsettings_get("org.cinnamon.desktop.keybindings", "show-desklets") {
        let binding_lower = binding.to_lowercase();
        if binding_lower.contains("super") && binding_lower.contains("v") {
            conflicts.push(ShortcutConflict {
                binding: "<Super>v".to_string(),
                current_action: "Show Desklets".to_string(),
                owner: "Cinnamon".to_string(),
                resolution_command: Some(
                    "gsettings set org.cinnamon.desktop.keybindings show-desklets \"['<Super><Shift>v']\"".to_string()
                ),
                resolution_steps: r#"**To resolve manually:**
1. Open System Settings → Keyboard → Shortcuts
2. Find "Show Desklets"
3. Change Super+V to Super+Shift+V"#.to_string(),
            });
        }
    }

    conflicts
}

// XFCE Conflicts
fn detect_xfce_conflicts() -> Vec<ShortcutConflict> {
    let mut conflicts = Vec::new();

    if !Utils::command_exists("xfconf-query") {
        return conflicts;
    }

    let output = Command::new("xfconf-query")
        .args(["-c", "xfce4-keyboard-shortcuts", "-l", "-v"])
        .output();

    if let Ok(output) = output {
        let content = String::from_utf8_lossy(&output.stdout);
        for line in content.lines() {
            let line_lower = line.to_lowercase();
            if line_lower.contains("<super>v")
                && !line_lower.contains("clipboard-history")
                && !line_lower.contains("win11")
            {
                conflicts.push(ShortcutConflict {
                    binding: "<Super>v".to_string(),
                    current_action: line.to_string(),
                    owner: "XFCE".to_string(),
                    resolution_command: None,
                    resolution_steps: r#"**To resolve manually:**
1. Open Settings → Keyboard → Application Shortcuts
2. Find the Super+V binding
3. Change or remove it"#
                        .to_string(),
                });
            }
        }
    }

    conflicts
}

// =============================================================================
// Manual Instructions & Setup Status
// =============================================================================

#[derive(serde::Serialize)]
pub struct ShortcutToolsStatus {
    pub desktop_environment: String,
    pub gsettings_available: bool,
    pub kde_tools_available: bool,
    pub xfce_tools_available: bool,
    pub can_register_automatically: bool,
    pub manual_instructions: String,
    pub has_conflicts: bool,
    pub conflict_count: usize,
    pub can_auto_resolve_conflicts: bool,
}

pub fn get_manual_instructions(de: &str) -> String {
    match de {
        "GNOME" => r#"**GNOME Settings:**
1. Open Settings → Keyboard → Keyboard Shortcuts → Custom Shortcuts
2. Click "+" to add a new shortcut
3. Name: "Clipboard History"
4. Command: `spawn-at spawn --anchor cursor -o -15 -15 -m 10 win11-clipboard-history --clipboard`
5. Shortcut: Press Super+V

**⚠️ Note:** GNOME uses Super+V for the Notification Center by default.
To free up Super+V, run:
```
gsettings set org.gnome.shell.keybindings toggle-message-tray "['<Super><Shift>v']"
```"#
            .to_string(),

        "Pop!_OS" => r#"**Pop!_OS / Pop Shell:**
1. Open Settings → Keyboard → Keyboard Shortcuts → Custom Shortcuts
2. Add a new shortcut with command: `spawn-at spawn --anchor cursor -o -15 -15 -m 10 win11-clipboard-history --clipboard`
3. Set the shortcut to Super+V

**⚠️ Note:** Pop!_OS inherits GNOME's Super+V for Notification Center.
To free up Super+V, run:
```
gsettings set org.gnome.shell.keybindings toggle-message-tray "['<Super><Shift>v']"
```

If Pop Shell uses Super+V for tiling, change it in:
Settings → Keyboard → Customize Shortcuts → Pop Shell"#
            .to_string(),

        "KDE Plasma" => r#"**KDE System Settings:**
1. Open System Settings → Shortcuts → Custom Shortcuts
2. Click "Edit" → "New" → "Global Shortcut" → "Command/URL"
3. Name: "Clipboard History"
4. Trigger: Click and press Meta+V
5. Action: `spawn-at spawn --anchor cursor -o -15 -15 -m 10 win11-clipboard-history --clipboard`

**⚠️ Note:** If Klipper (KDE's clipboard) uses Meta+V:
1. Right-click Klipper in system tray → Configure
2. Change or disable its shortcut"#
            .to_string(),

        "Cinnamon" => r#"**Cinnamon Settings:**
1. Open System Settings → Keyboard → Shortcuts → Custom Shortcuts
2. Click "Add custom shortcut"
3. Name: "Clipboard History"
4. Command: `spawn-at spawn --anchor cursor -o -15 -15 -m 10 win11-clipboard-history --clipboard`
5. Click on the shortcut area and press Super+V"#
            .to_string(),

        "XFCE" => r#"**XFCE Settings:**
1. Open Settings → Keyboard → Application Shortcuts
2. Click "Add"
3. Command: `spawn-at spawn --anchor cursor -o -15 -15 -m 10 win11-clipboard-history --clipboard`
4. Press Super+V when prompted"#
            .to_string(),

        "MATE" => r#"**MATE Control Center:**
1. Open Control Center → Keyboard Shortcuts
2. Click "Add"
3. Name: "Clipboard History"
4. Command: `spawn-at spawn --anchor cursor -o -15 -15 -m 10 win11-clipboard-history --clipboard`
5. Click on the shortcut and press Super+V"#
            .to_string(),

        "LXQt" => r#"**LXQt Configuration:**
1. Open LXQt Configuration → Shortcut Keys
2. Click "Add"
3. Description: "Clipboard History"
4. Command: `spawn-at spawn --anchor cursor -o -15 -15 -m 10 win11-clipboard-history --clipboard`
5. Set shortcut to Meta+V"#
            .to_string(),

        "LXDE" => r#"**LXDE/Openbox:**
1. Edit ~/.config/openbox/lxde-rc.xml
2. Add in <keyboard> section:

<keybind key="Super_L+v">
  <action name="Execute">
    <command>spawn-at spawn --anchor cursor -o -15 -15 -m 10 win11-clipboard-history --clipboard</command>
  </action>
</keybind>

3. Run: openbox --reconfigure"#
            .to_string(),

        "COSMIC" => r#"**COSMIC Settings:**
1. Open Settings → Keyboard → Custom Shortcuts
2. Add new shortcut
3. Command: `spawn-at spawn --anchor cursor -o -15 -15 -m 10 win11-clipboard-history --clipboard`
4. Binding: Super+V

**Note:** If there's a conflict, check System shortcuts for Super+V bindings."#
            .to_string(),

        "i3" => r#"**i3 Configuration:**
1. Edit your i3 config: `~/.config/i3/config`
2. Comment out or remove any existing `bindsym $mod+v` line
3. Add this line:
```
bindsym $mod+v exec spawn-at spawn --anchor cursor -o -15 -15 -m 10 win11-clipboard-history --clipboard
```
4. Reload i3: Press $mod+Shift+r

**Alternative shortcut:**
```
bindsym Ctrl+Mod1+v exec spawn-at spawn --anchor cursor -o -15 -15 -m 10 win11-clipboard-history --clipboard
```"#
            .to_string(),

        "Sway" => r#"**Sway Configuration:**
1. Edit your Sway config: `~/.config/sway/config`
2. Comment out or remove any existing `bindsym $mod+v` line
3. Add this line:
```
bindsym $mod+v exec spawn-at spawn --anchor cursor -o -15 -15 -m 10 win11-clipboard-history --clipboard
```
4. Reload Sway: Press $mod+Shift+c

**Alternative shortcut:**
```
bindsym Ctrl+Mod1+v exec spawn-at spawn --anchor cursor -o -15 -15 -m 10 win11-clipboard-history --clipboard
```"#
            .to_string(),

        "Hyprland" => r#"**Hyprland Configuration:**
1. Edit your Hyprland config: `~/.config/hypr/hyprland.conf`
2. Comment out or remove any existing `bind = SUPER, V, ...` line
3. Add this line:
```
bind = SUPER, V, exec, spawn-at spawn --anchor cursor -o -15 -15 -m 10 win11-clipboard-history --clipboard
```
4. Config auto-reloads (or press Super+M to reload manually)

**Alternative shortcut:**
```
bind = CTRL ALT, V, exec, spawn-at spawn --anchor cursor -o -15 -15 -m 10 win11-clipboard-history --clipboard
```"#
            .to_string(),

        _ => r#"**Generic Instructions:**
1. Open your desktop environment's keyboard shortcuts settings
2. Add a new custom shortcut
3. Command: `spawn-at spawn --anchor cursor -o -15 -15 -m 10 win11-clipboard-history --clipboard`
4. Shortcut: Super+V (or your preferred combination)

**Alternative:** Use Ctrl+Alt+V if Super+V conflicts with your DE."#
            .to_string(),
    }
}

// =============================================================================
// Tauri Commands (Frontend IPC Interface)
// =============================================================================

/// Get the current desktop environment name
#[tauri::command]
pub fn get_desktop_environment() -> String {
    let xdg_current = env::var("XDG_CURRENT_DESKTOP")
        .unwrap_or_default()
        .to_lowercase();
    let xdg_session = env::var("XDG_SESSION_DESKTOP")
        .unwrap_or_default()
        .to_lowercase();
    let combined = format!("{} {}", xdg_current, xdg_session);

    if combined.contains("pop") {
        return "Pop!_OS".to_string();
    }
    if combined.contains("gnome") || combined.contains("unity") || combined.contains("pantheon") {
        "GNOME".to_string()
    } else if combined.contains("cinnamon") {
        "Cinnamon".to_string()
    } else if combined.contains("kde") || combined.contains("plasma") {
        "KDE Plasma".to_string()
    } else if combined.contains("xfce") {
        "XFCE".to_string()
    } else if combined.contains("mate") {
        "MATE".to_string()
    } else if combined.contains("lxde") {
        "LXDE".to_string()
    } else if combined.contains("lxqt") {
        "LXQt".to_string()
    } else if combined.contains("cosmic") {
        "COSMIC".to_string()
    } else if combined.contains("budgie") {
        "Budgie".to_string()
    } else if combined.contains("deepin") {
        "Deepin".to_string()
    } else if combined.contains("i3") {
        "i3".to_string()
    } else if combined.contains("sway") {
        "Sway".to_string()
    } else if combined.contains("hyprland") {
        "Hyprland".to_string()
    } else if is_process_running("i3") {
        "i3".to_string()
    } else if is_process_running("sway") {
        "Sway".to_string()
    } else if is_process_running("hyprland") || is_process_running("Hyprland") {
        "Hyprland".to_string()
    } else {
        xdg_current.to_uppercase()
    }
}

/// Detect shortcut conflicts for Super+V
#[tauri::command]
pub fn detect_conflicts() -> ConflictDetectionResult {
    detect_shortcut_conflicts()
}

/// Automatically resolve detected conflicts
#[tauri::command]
pub fn resolve_conflicts() -> std::result::Result<Vec<String>, String> {
    auto_resolve_conflicts()
}

/// Register the global shortcuts with the desktop environment
/// Invoked by the onboarding Setup Wizard ("Register Automatically") and Settings app
#[tauri::command]
pub fn register_de_shortcut() -> std::result::Result<String, String> {
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        register_global_shortcut();
        let _ = tx.send(());
    });

    match rx.recv() {
        Ok(()) => {
            Ok("Shortcut registration completed. Check the app logs for details.".to_string())
        }
        Err(_) => Err("Shortcut registration thread failed unexpectedly.".to_string()),
    }
}

/// Check if the DE shortcut manager has the tools needed
#[tauri::command]
pub fn check_shortcut_tools() -> ShortcutToolsStatus {
    let gsettings = Utils::command_exists("gsettings");
    let kwriteconfig5 = Utils::command_exists("kwriteconfig5");
    let kwriteconfig6 = Utils::command_exists("kwriteconfig6");
    let xfconf_query = Utils::command_exists("xfconf-query");
    let dconf = Utils::command_exists("dconf");

    let de = get_desktop_environment();

    let can_register = match de.as_str() {
        "GNOME" | "Pop!_OS" | "Cinnamon" | "MATE" | "Budgie" | "Deepin" => gsettings || dconf,
        "KDE Plasma" => kwriteconfig5 || kwriteconfig6,
        "XFCE" => xfconf_query,
        "LXQt" => true,
        "LXDE" => true,
        "COSMIC" => true,
        "i3" => true,
        "Sway" => true,
        "Hyprland" => true,
        _ => gsettings,
    };

    let conflicts = detect_shortcut_conflicts();

    ShortcutToolsStatus {
        desktop_environment: de.clone(),
        gsettings_available: gsettings,
        kde_tools_available: kwriteconfig5 || kwriteconfig6,
        xfce_tools_available: xfconf_query,
        can_register_automatically: can_register,
        manual_instructions: get_manual_instructions(&de),
        has_conflicts: !conflicts.conflicts.is_empty(),
        conflict_count: conflicts.conflicts.len(),
        can_auto_resolve_conflicts: conflicts.can_auto_resolve,
    }
}

// =============================================================================
// Tests
// =============================================================================

#[cfg(test)]
mod tests {
    #[test]
    fn shortcut_command_uses_given_spawn_at_and_app_path() {
        let t = "spawn-at spawn --anchor cursor -o -15 -15 -m 10 win11-clipboard-history";
        assert_eq!(
            super::build_shortcut_command(t, "win11-clipboard-history", "spawn-at"),
            t
        );
        assert_eq!(
            super::build_shortcut_command(t, "/usr/bin/app", "/home/u/.local/bin/spawn-at"),
            "/home/u/.local/bin/spawn-at spawn --anchor cursor -o -15 -15 -m 10 /usr/bin/app"
        );
        assert_eq!(
            super::build_shortcut_command(t, "win11-clipboard-history", "\"/h/a b/spawn-at\""),
            "\"/h/a b/spawn-at\" spawn --anchor cursor -o -15 -15 -m 10 win11-clipboard-history"
        );
        // a template that does not start with spawn-at is left alone
        assert_eq!(super::build_shortcut_command("other x", "a", "/p/spawn-at"), "other x");
    }

    use super::*;

    #[test]
    fn test_escape_xml() {
        assert_eq!(escape_xml("test"), "test");
        assert_eq!(escape_xml("a & b"), "a &amp; b");
        assert_eq!(escape_xml("<tag>"), "&lt;tag&gt;");
        assert_eq!(escape_xml("\"quotes'"), "&quot;quotes&apos;");
    }

    #[test]
    fn test_cosmic_escape_ron_string() {
        assert_eq!(CosmicHandler::escape_ron_string("normal"), "normal");
        assert_eq!(
            CosmicHandler::escape_ron_string("with \"quotes\""),
            "with \\\"quotes\\\""
        );
        assert_eq!(
            CosmicHandler::escape_ron_string("with \\backslashes\\"),
            "with \\\\backslashes\\\\"
        );
    }

    #[test]
    fn test_cosmic_format_modifiers() {
        let single = CosmicHandler::format_modifiers("Super");
        assert!(single.contains("Super,"));

        let multi = CosmicHandler::format_modifiers("Ctrl, Alt");
        assert!(multi.contains("Ctrl,"));
        assert!(multi.contains("Alt,"));
    }

    #[test]
    fn test_cosmic_build_entry() {
        let shortcut = ShortcutConfig {
            id: "test",
            name: "Test App",
            command: "test-cmd",
            args: "",
            gnome_binding: "<Super>t",
            kde_binding: "Meta+T",
            xfce_binding: "<Super>t",
            cosmic_mods: "Super",
            cosmic_key: "t",
            i3_binding: "$mod+t",
            sway_binding: "$mod+t",
            hyprland_binding: "SUPER, T",
            lxde_binding: "W-t",
        };

        let entry = CosmicHandler::build_entry(&shortcut);
        assert!(entry.contains("modifiers: ["));
        assert!(entry.contains("Super,"));
        assert!(entry.contains("key: \"t\""));
        assert!(entry.contains("description: Some(\"Test App\")"));
        assert!(entry.contains("Spawn(\"test-cmd\")"));
    }

    #[test]
    fn test_has_mod_v_binding() {
        assert!(has_mod_v_binding("bindsym $mod+v exec something"));
        assert!(has_mod_v_binding("bindsym $mod+v"));
        assert!(has_mod_v_binding("bindsym $mod+v\t"));
        assert!(has_mod_v_binding("bindsym $mod+v# comment"));
        assert!(has_mod_v_binding("bindsym $mod+v; something"));
        assert!(has_mod_v_binding("bindsym mod4+v exec something"));

        assert!(!has_mod_v_binding("bindsym $mod+v_other exec something"));
        assert!(!has_mod_v_binding("bindsym $mod+volume_up exec something"));
        assert!(!has_mod_v_binding("bindsym $mod+v1 exec something"));
        assert!(!has_mod_v_binding("bindsym $mod+a exec something"));
    }

    #[test]
    fn test_detect_conflicts_runs() {
        let _result = detect_shortcut_conflicts();
    }
}
