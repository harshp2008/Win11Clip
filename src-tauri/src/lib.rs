//! Windows 11 Clipboard History For Linux Library
//! This module re-exports the core functionality for use as a library

pub mod adaptive_dock;
pub mod app_id;
pub mod autostart_manager;
pub mod clipboard_manager;
pub mod config_manager;
pub mod emoji_manager;
pub mod focus_manager;
pub mod gif_manager;
pub mod ibus_hotkey;
pub mod input_simulator;
pub mod paste_sync;
pub mod permission_checker;
pub mod rendering_env;
pub mod session;
pub mod shortcut_manager;
pub mod show_debug;
pub mod spawn_at_path;
pub mod theme_manager;
pub mod user_settings;

pub use clipboard_manager::{ClipboardContent, ClipboardItem, ClipboardManager};
pub use config_manager::ConfigManager;
pub use emoji_manager::{EmojiManager, EmojiUsage};
pub use focus_manager::{restore_focused_window, save_focused_window};

pub use focus_manager::{x11_activate_window_by_title, x11_robust_activate};
pub use gif_manager::{paste_gif_to_clipboard, paste_gif_to_clipboard_with_uri};
pub use permission_checker::{
    check_permissions, fix_permissions_now, is_first_run, mark_first_run_complete, reset_first_run,
    PermissionStatus,
};
pub use rendering_env::{get_rendering_env, get_rendering_environment, RenderingEnv};
pub use session::{get_session_type, is_wayland, is_x11, SessionType};
pub use shortcut_manager::{
    auto_resolve_conflicts, check_shortcut_tools, detect_conflicts, detect_shortcut_conflicts,
    get_desktop_environment, register_de_shortcut, register_global_shortcut, resolve_conflicts,
    unregister_global_shortcut, ConflictDetectionResult, ShortcutConflict, ShortcutToolsStatus,
};
pub use theme_manager::{
    clear_theme_cache, get_system_color_scheme, is_event_listener_running, start_theme_listener,
    ColorScheme, ThemeInfo,
};
pub use user_settings::{UserSettings, UserSettingsManager};
