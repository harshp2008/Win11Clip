//! Focus Manager Module
//! Tracks and restores window focus for proper paste injection on X11.
//! Also provides X11 window activation using EWMH protocols.

use std::sync::atomic::{AtomicU32, Ordering};
use std::thread;
use std::time::{Duration, Instant};
use x11rb::connection::Connection;
use x11rb::protocol::xproto::{AtomEnum, ClientMessageEvent, ConnectionExt, EventMask, InputFocus};

/// Failure ceiling for focus restoration. Fast systems return after two
/// confirmed samples; constrained systems are allowed more time without
/// imposing that time on every paste.
const FOCUS_RESTORE_TIMEOUT: Duration = Duration::from_millis(750);

/// Stores the ID of the window that had focus before we opened
static LAST_FOCUSED_WINDOW: AtomicU32 = AtomicU32::new(0);

pub fn save_focused_window() {
    if !crate::session::is_x11() {
        return;
    }

    // Never reuse a target captured for an older popup invocation if this
    // query fails. Pasting nowhere is safer than redirecting input to a stale
    // application window.
    LAST_FOCUSED_WINDOW.store(0, Ordering::SeqCst);

    match crate::paste_sync::focused_window() {
        Some(window_id) => {
            LAST_FOCUSED_WINDOW.store(window_id, Ordering::SeqCst);
            eprintln!("[FocusManager] Saved focused window: {}", window_id);
        }
        None => eprintln!("[FocusManager] Failed to query the focused X11 window"),
    }
}

pub fn restore_focused_window() -> Result<bool, String> {
    let window_id = LAST_FOCUSED_WINDOW.load(Ordering::SeqCst);

    if window_id == 0 {
        return Err("No previous window saved".to_string());
    }

    eprintln!("[FocusManager] Restoring focus to window: {}", window_id);

    crate::paste_sync::restore_and_settle_focus(window_id, FOCUS_RESTORE_TIMEOUT)
}

pub fn get_focused_window() -> Option<u32> {
    crate::paste_sync::focused_window()
}

// =============================================================================
// X11 Window Activation (EWMH compliant)
// =============================================================================

/// Maximum time to wait for window to be mapped
const WINDOW_MAP_TIMEOUT: Duration = Duration::from_millis(500);

/// Polling interval when waiting for window
const WINDOW_MAP_POLL_INTERVAL: Duration = Duration::from_millis(10);

/// Activates an X11 window using the EWMH _NET_ACTIVE_WINDOW protocol.
/// This is the proper way to request focus and is respected by window managers
/// even with Focus Stealing Prevention enabled.
///
/// # Arguments
/// * `window_id` - The X11 window ID to activate
///
/// # Returns
/// * `Ok(())` if the activation message was sent successfully
/// * `Err(String)` if there was an error
pub fn x11_activate_window_by_id(window_id: u32) -> Result<(), String> {
    let (conn, screen_num) =
        x11rb::connect(None).map_err(|e| format!("X11 connect failed: {}", e))?;

    let screen = conn
        .setup()
        .roots
        .get(screen_num)
        .ok_or("Failed to get screen")?;
    let root = screen.root;

    // Get _NET_ACTIVE_WINDOW atom
    let net_active_window = conn
        .intern_atom(false, b"_NET_ACTIVE_WINDOW")
        .map_err(|e| format!("Failed to intern atom: {}", e))?
        .reply()
        .map_err(|e| format!("Failed to get atom reply: {}", e))?
        .atom;

    // Create the client message event
    // Data format for _NET_ACTIVE_WINDOW:
    // data[0] = source indication (1 = from application, 2 = from pager)
    // data[1] = timestamp (0 = current time)
    // data[2] = requestor's currently active window (0 if none)
    let event = ClientMessageEvent {
        response_type: 33, // ClientMessage
        format: 32,
        sequence: 0,
        window: window_id,
        type_: net_active_window,
        data: [1, 0, 0, 0, 0].into(), // source=1 (application request)
    };

    // Send to root window with SubstructureRedirect | SubstructureNotify
    conn.send_event(
        false,
        root,
        EventMask::SUBSTRUCTURE_REDIRECT | EventMask::SUBSTRUCTURE_NOTIFY,
        event,
    )
    .map_err(|e| format!("Failed to send event: {}", e))?;

    conn.flush()
        .map_err(|e| format!("Failed to flush: {}", e))?;

    eprintln!(
        "[FocusManager] Sent _NET_ACTIVE_WINDOW for window {}",
        window_id
    );
    Ok(())
}

/// Waits for a window with the given title to appear and be mapped.
/// Uses polling with timeout instead of a fixed sleep.
///
/// # Arguments
/// * `title` - The window title to search for (substring match)
/// * `timeout` - Maximum time to wait
///
/// # Returns
/// * `Some(window_id)` if found within timeout
/// * `None` if timeout exceeded
pub fn wait_for_window_by_title(title: &str, timeout: Duration) -> Option<u32> {
    let start = Instant::now();

    while start.elapsed() < timeout {
        if let Some(window_id) = find_window_by_title(title) {
            eprintln!(
                "[FocusManager] Found window '{}' with ID {} after {:?}",
                title,
                window_id,
                start.elapsed()
            );
            return Some(window_id);
        }
        thread::sleep(WINDOW_MAP_POLL_INTERVAL);
    }

    eprintln!("[FocusManager] Timeout waiting for window '{}'", title);
    None
}

/// Finds a window by its title using X11 primitives.
/// This is more reliable than xdotool as it directly queries the X server.
fn find_window_by_title(title: &str) -> Option<u32> {
    let (conn, screen_num) = x11rb::connect(None).ok()?;
    let screen = conn.setup().roots.get(screen_num)?;
    let root = screen.root;

    // Get atoms we need
    let net_client_list = conn
        .intern_atom(false, b"_NET_CLIENT_LIST")
        .ok()?
        .reply()
        .ok()?
        .atom;

    let net_wm_name = conn
        .intern_atom(false, b"_NET_WM_NAME")
        .ok()?
        .reply()
        .ok()?
        .atom;

    let utf8_string = conn
        .intern_atom(false, b"UTF8_STRING")
        .ok()?
        .reply()
        .ok()?
        .atom;

    // Get list of all client windows
    let client_list = conn
        .get_property(false, root, net_client_list, AtomEnum::WINDOW, 0, 1024)
        .ok()?
        .reply()
        .ok()?;

    let windows: Vec<u32> = client_list
        .value32()
        .map(|iter| iter.collect())
        .unwrap_or_default();

    // Search each window for matching title
    for window in windows {
        // Try _NET_WM_NAME first (UTF-8)
        if let Ok(cookie) = conn.get_property(false, window, net_wm_name, utf8_string, 0, 256) {
            if let Ok(reply) = cookie.reply() {
                if let Ok(name) = String::from_utf8(reply.value) {
                    if name.contains(title) {
                        return Some(window);
                    }
                }
            }
        }

        // Fall back to WM_NAME (legacy)
        if let Ok(cookie) =
            conn.get_property(false, window, AtomEnum::WM_NAME, AtomEnum::STRING, 0, 256)
        {
            if let Ok(reply) = cookie.reply() {
                if let Ok(name) = String::from_utf8(reply.value) {
                    if name.contains(title) {
                        return Some(window);
                    }
                }
            }
        }
    }

    None
}

/// High-level function to activate a window by title.
/// Waits for the window to appear, then activates it using EWMH.
///
/// # Arguments
/// * `title` - The window title to search for
///
/// # Returns
/// * `Ok(())` if activation was successful
/// * `Err(String)` if window not found or activation failed
pub fn x11_activate_window_by_title(title: &str) -> Result<(), String> {
    let window_id = wait_for_window_by_title(title, WINDOW_MAP_TIMEOUT)
        .ok_or_else(|| format!("Window '{}' not found within timeout", title))?;

    x11_activate_window_by_id(window_id)?;

    // Small delay to let the WM process the activation
    thread::sleep(Duration::from_millis(20));

    Ok(())
}

/// Alternative activation that sets input focus directly.
/// Use this as a fallback if _NET_ACTIVE_WINDOW doesn't work.
pub fn x11_force_input_focus(window_id: u32) -> Result<(), String> {
    let (conn, _) = x11rb::connect(None).map_err(|e| format!("X11 connect failed: {}", e))?;

    // Set input focus with PointerRoot revert mode
    conn.set_input_focus(InputFocus::POINTER_ROOT, window_id, x11rb::CURRENT_TIME)
        .map_err(|e| format!("set_input_focus failed: {}", e))?;

    conn.flush().map_err(|e| format!("Flush failed: {}", e))?;

    eprintln!("[FocusManager] Forced input focus to window {}", window_id);
    Ok(())
}

/// Combined activation strategy that tries multiple methods.
/// This is the most robust approach for X11 focus acquisition.
pub fn x11_robust_activate(title: &str) -> Result<(), String> {
    // Step 1: Wait for window to appear in _NET_CLIENT_LIST
    let window_id = wait_for_window_by_title(title, WINDOW_MAP_TIMEOUT)
        .ok_or_else(|| format!("Window '{}' not found", title))?;

    // Step 2: Try EWMH _NET_ACTIVE_WINDOW (preferred, WM-friendly)
    if let Err(e) = x11_activate_window_by_id(window_id) {
        eprintln!(
            "[FocusManager] EWMH activation failed: {}, trying fallback",
            e
        );
    }

    // Step 3: Small delay for WM to process
    thread::sleep(Duration::from_millis(30));

    // Step 4: Verify focus was acquired, force if not
    match get_focused_window() {
        Some(current_focus) => {
            if current_focus != window_id {
                eprintln!("[FocusManager] Focus not acquired, forcing input focus");
                x11_force_input_focus(window_id)?;
            }
        }
        None => {
            eprintln!(
                "[FocusManager] Could not determine focused window after EWMH activation; forcing input focus as fallback"
            );
            x11_force_input_focus(window_id)?;
        }
    }

    Ok(())
}

// =============================================================================
// GNOME Wayland — focus / window-layer management via window-calls D-Bus
// =============================================================================
//
// `org.gnome.Shell.Eval` is disabled on this system (returns `(false, '')`).
// Instead we use the `window-calls` GNOME Shell extension which exposes a fully
// functional D-Bus API:
//
//   Destination  : org.gnome.Shell
//   Object path  : /org/gnome/Shell/Extensions/Windows
//   Interface    : org.gnome.Shell.Extensions.Windows
//   Methods used : List, Activate, MakeAbove, UnmakeAbove
//
// Window IDs are u32 values in the D-Bus interface signature (GLib uint).

const WC_DEST: &str = "org.gnome.Shell";
const WC_PATH: &str = "/org/gnome/Shell/Extensions/Windows";
const WC_IFACE: &str = "org.gnome.Shell.Extensions.Windows";
const WC_CLIPBOARD_WM_CLASS: &str = "win11-clipboard-history";

/// Minimal window descriptor parsed from the JSON returned by
/// `org.gnome.Shell.Extensions.Windows.List`.
#[derive(serde::Deserialize, Debug)]
struct WcWindow {
    id: u64,
    #[serde(default)]
    pid: u32,
    #[serde(default)]
    wm_class: String,
    #[serde(default)]
    title: String,
    #[serde(default)]
    focus: bool,
}

use parking_lot::Mutex;
use std::collections::VecDeque;

/// Mutex-guarded 2-window focus history stack (stores last 2 non-clipboard active window IDs and their wm_class).
static FOCUS_HISTORY: Mutex<VecDeque<(u64, String)>> = Mutex::new(VecDeque::new());

/// Push a non-clipboard window ID and its class to the 2-window focus history stack.
pub fn wayland_push_focus_history(winid: u64, wm_class: String) {
    if winid == 0 {
        return;
    }
    let mut history = FOCUS_HISTORY.lock();
    if history.front().map(|(id, _)| *id) == Some(winid) {
        return;
    }
    history.push_front((winid, wm_class));
    while history.len() > 2 {
        history.pop_back();
    }
    eprintln!("[FocusManager] Focus history stack: {:?}", *history);
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Call a `window-calls` method that takes no arguments (e.g. `List`).
fn wc_call_list() -> Result<Vec<WcWindow>, String> {
    let output = std::process::Command::new("gdbus")
        .args([
            "call",
            "--session",
            "--dest",
            WC_DEST,
            "--object-path",
            WC_PATH,
            "--method",
            &format!("{}.List", WC_IFACE),
        ])
        .output()
        .map_err(|e| format!("gdbus List failed to start: {}", e))?;

    if !output.status.success() {
        return Err(format!(
            "gdbus List exited with error: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }

    // The response is a GLib variant: ('[{"id":123,...}]',)\n
    // Extract the JSON array between the first '[' and the last ']'.
    let raw = String::from_utf8_lossy(&output.stdout);
    let start = raw.find('[').ok_or("No '[' in List response")?;
    let end = raw.rfind(']').ok_or("No ']' in List response")?;
    let json = &raw[start..=end];

    serde_json::from_str::<Vec<WcWindow>>(json)
        .map_err(|e| format!("JSON parse error: {} — raw: {}", e, json))
}

/// Call a `window-calls` method that takes a single u32 window-ID argument.
/// Covers `Activate`, `MakeAbove`, `UnmakeAbove`, `Minimize`, etc.
fn wc_call_winid(method: &str, winid: u64) -> Result<(), String> {
    if winid == 0 {
        return Err(format!("{}: window ID is 0", method));
    }

    let full_method = format!("{}.{}", WC_IFACE, method);
    let id_str = format!("uint32 {}", winid);

    let output = std::process::Command::new("gdbus")
        .args([
            "call",
            "--session",
            "--dest",
            WC_DEST,
            "--object-path",
            WC_PATH,
            "--method",
            &full_method,
            &id_str,
        ])
        .output()
        .map_err(|e| format!("gdbus {} failed to start: {}", method, e))?;

    if !output.status.success() {
        return Err(format!(
            "gdbus {} exited with error: {}",
            method,
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }

    eprintln!("[FocusManager] window-calls {} winid={}", method, winid);
    Ok(())
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Queries the window-calls extension for the currently focused window and
/// pushes its ID to the 2-window focus stack. Call this just *before* showing
/// the clipboard window so we capture the correct target application.
///
/// Windows owned by `win11-clipboard-history` are excluded.
pub fn wayland_save_focused_window_id() {
    match wc_call_list() {
        Ok(windows) => {
            // If clipboard history window itself currently has focus, NEVER push or overwrite.
            if windows.iter().any(|w| w.focus && w.wm_class == WC_CLIPBOARD_WM_CLASS) {
                eprintln!(
                    "[FocusManager] Clipboard history already has focus, preserving focus history: {:?}",
                    *FOCUS_HISTORY.lock()
                );
                return;
            }

            // Prefer the window that currently has focus.
            let target = windows
                .iter()
                .find(|w| w.focus && w.wm_class != WC_CLIPBOARD_WM_CLASS);

            if let Some(win) = target {
                wayland_push_focus_history(win.id, win.wm_class.clone());
                eprintln!(
                    "[FocusManager] Saved target window id={} class='{}' pid={}",
                    win.id, win.wm_class, win.pid
                );
            } else {
                // If no window reports focus=true (rare), fallback only if stack is empty.
                let existing = wayland_get_saved_window_id();
                if existing == 0 {
                    if let Some(win) = windows.iter().find(|w| w.wm_class != WC_CLIPBOARD_WM_CLASS) {
                        wayland_push_focus_history(win.id, win.wm_class.clone());
                        eprintln!(
                            "[FocusManager] Fallback saved target window id={} class='{}'",
                            win.id, win.wm_class
                        );
                    } else {
                        eprintln!("[FocusManager] No suitable target window found in List");
                    }
                } else {
                    eprintln!(
                        "[FocusManager] No focused non-clipboard window found; preserving existing target id={}",
                        existing
                    );
                }
            }
        }
        Err(e) => eprintln!("[FocusManager] wayland_save_focused_window_id: {}", e),
    }
}

/// Clears the saved target window focus history.
pub fn wayland_clear_saved_window_id() {
    let mut history = FOCUS_HISTORY.lock();
    history.clear();
    eprintln!("[FocusManager] Cleared focus history stack");
}

/// Returns the window ID at the top of the 2-window focus stack.
/// Returns 0 if no target has been saved.
pub fn wayland_get_saved_window_id() -> u64 {
    let history = FOCUS_HISTORY.lock();
    history.front().map(|(id, _)| *id).unwrap_or(0)
}

/// Returns the wm_class of the window at the top of the 2-window focus stack.
pub fn wayland_get_saved_window_class() -> String {
    let history = FOCUS_HISTORY.lock();
    history.front().map(|(_, class)| class.clone()).unwrap_or_default()
}

/// Activate (focus) a window by its `window-calls` integer ID.
pub fn wayland_activate_window_id(winid: u64) -> Result<(), String> {
    wc_call_winid("Activate", winid)
}

/// Set or clear the "keep above all other windows" layer for a window.
/// Uses the custom GNOME Shell extension bridge, and falls back to `MakeAbove`
/// from the window-calls extension which maps directly to Mutter's `meta_window_make_above()`.
pub fn wayland_set_keep_above(winid: u64, above: bool) -> Result<(), String> {
    // Attempt our custom bridge first
    let _ = gnome_extension_set_keep_above(winid, above);

    let method = if above { "MakeAbove" } else { "UnmakeAbove" };
    wc_call_winid(method, winid)
}

/// Invokes the custom GNOME Shell extension's SetAlwaysOnTop method.
pub fn gnome_extension_set_keep_above(_winid: u64, above: bool) -> Result<(), String> {
    let method = "org.gnome.Shell.Extensions.Windows11ClipboardBridge.SetAlwaysOnTop";
    
    let output = std::process::Command::new("gdbus")
        .args([
            "call",
            "--session",
            "--dest",
            "org.gnome.Shell",
            "--object-path",
            "/org/gnome/Shell/Extensions/Windows11ClipboardBridge",
            "--method",
            method,
            &format!("uint32 {}", std::process::id()),
            if above { "true" } else { "false" },
        ])
        .output()
        .map_err(|e| format!("gdbus SetAlwaysOnTop failed to start: {}", e))?;

    if !output.status.success() {
        return Err(format!(
            "gdbus SetAlwaysOnTop exited with error: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }

    eprintln!("[FocusManager] GNOME extension SetAlwaysOnTop above={}", above);
    Ok(())
}

/// Invokes the custom GNOME Shell extension's ForcePin method.
pub fn gnome_extension_force_pin() -> Result<(), String> {
    let method = "org.gnome.Shell.Extensions.Windows11ClipboardBridge.ForcePin";
    
    let output = std::process::Command::new("gdbus")
        .args([
            "call",
            "--session",
            "--dest",
            "org.gnome.Shell",
            "--object-path",
            "/org/gnome/Shell/Extensions/Windows11ClipboardBridge",
            "--method",
            method,
            &format!("uint32 {}", std::process::id()),
        ])
        .output()
        .map_err(|e| format!("gdbus ForcePin failed to start: {}", e))?;

    if !output.status.success() {
        return Err(format!(
            "gdbus ForcePin exited with error: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }

    eprintln!("[FocusManager] GNOME extension ForcePin called");
    Ok(())
}

/// Looks up the clipboard window ID from the live window list.
/// Matches the first window with `wm_class == "win11-clipboard-history"`
/// whose title does NOT contain "Settings".
pub fn wayland_get_clipboard_window_id() -> Result<u64, String> {
    let windows = wc_call_list()?;
    windows
        .iter()
        .find(|w| {
            w.wm_class == WC_CLIPBOARD_WM_CLASS && !w.title.to_lowercase().contains("settings")
        })
        .map(|w| {
            eprintln!("[FocusManager] Clipboard window id={}", w.id);
            w.id
        })
        .ok_or_else(|| "Clipboard main window not found in List".to_string())
}

/// Snaps the specified Wayland window to the current cursor position via D-Bus extension.
pub fn wayland_snap_to_cursor(cb_id: u64) {
    if let Ok(output) = std::process::Command::new("gdbus")
        .args([
            "call",
            "--session",
            "--dest",
            "org.gnome.Shell",
            "--object-path",
            "/org/gnome/Shell/Extensions/Windows",
            "--method",
            "org.gnome.Shell.Extensions.Windows.GetCoordinates",
        ])
        .output()
    {
        let raw_coords = String::from_utf8_lossy(&output.stdout);
        let parts: Vec<&str> = raw_coords.split(',').collect();
        if parts.len() >= 2 {
            let x = parts[0]
                .split_whitespace()
                .last()
                .and_then(|p| p.trim_matches(|c: char| !c.is_numeric()).parse::<i32>().ok());
            let y = parts[1]
                .split_whitespace()
                .last()
                .and_then(|p| p.trim_matches(|c: char| !c.is_numeric()).parse::<i32>().ok());

            if let (Some(x_val), Some(y_val)) = (x, y) {
                let _ = std::process::Command::new("gdbus")
                    .args([
                        "call",
                        "--session",
                        "--dest",
                        "org.gnome.Shell",
                        "--object-path",
                        "/org/gnome/Shell/Extensions/Windows",
                        "--method",
                        "org.gnome.Shell.Extensions.Windows.Move",
                        &format!("uint32 {}", cb_id),
                        &format!("int32 {}", x_val - 15),
                        &format!("int32 {}", y_val - 15),
                    ])
                    .output();
            }
        }
    }
}

