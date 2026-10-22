//! Opt-in timing logs for the deferred "apply the tab, then show the window" flow.
//!
//! Everything here is a no-op unless `W11C_SHOW_DEBUG=1` is set in the
//! environment when the app starts, so the default behaviour and output are
//! unchanged. When enabled, each event prints one line to stderr with the
//! monotonic milliseconds elapsed since the gate was armed, for example:
//!
//! ```text
//! [W11C_SHOW_DEBUG] +0 ms gate armed: tab=emoji visible=false
//! [W11C_SHOW_DEBUG] +1 ms event emitted: switch-tab emoji
//! [W11C_SHOW_DEBUG] +4 ms frontend handler received: switch-tab emoji
//! [W11C_SHOW_DEBUG] +9 ms confirmation received
//! [W11C_SHOW_DEBUG] +12 ms window.show() called
//! ```

use std::sync::{Mutex, OnceLock};
use std::time::Instant;

static ENABLED: OnceLock<bool> = OnceLock::new();
static ORIGIN: Mutex<Option<Instant>> = Mutex::new(None);

/// True only when `W11C_SHOW_DEBUG=1` is present in the environment.
pub fn enabled() -> bool {
    *ENABLED.get_or_init(|| {
        std::env::var("W11C_SHOW_DEBUG")
            .map(|v| v == "1")
            .unwrap_or(false)
    })
}

/// Starts a new timing window for a deferred show and logs that the gate was armed.
///
/// `detail` is free-form and should name the requested tab and whether the window
/// was visible (`tab=emoji visible=false`).
pub fn arm(detail: &str) {
    if !enabled() {
        return;
    }
    *ORIGIN.lock().unwrap() = Some(Instant::now());
    log("gate armed", detail);
}

/// Ends the current timing window. A later, unrelated show starts from a fresh log.
pub fn clear() {
    if !enabled() {
        return;
    }
    *ORIGIN.lock().unwrap() = None;
}

/// Milliseconds elapsed since [`arm`], or `None` when no gate is timing.
pub fn elapsed_ms() -> Option<u128> {
    let origin = *ORIGIN.lock().unwrap();
    origin.map(|origin| elapsed_ms_between(origin, Instant::now()))
}

/// Prints one event line when debug logging is enabled; does nothing otherwise.
pub fn log(event: &str, detail: &str) {
    if !enabled() {
        return;
    }
    eprintln!("{}", format_line(elapsed_ms().unwrap_or(0), event, detail));
}

/// Formats one event line. Kept pure so the timing/text format is unit tested.
pub fn format_line(elapsed_ms: u128, event: &str, detail: &str) -> String {
    if detail.is_empty() {
        format!("[W11C_SHOW_DEBUG] +{elapsed_ms} ms {event}")
    } else {
        format!("[W11C_SHOW_DEBUG] +{elapsed_ms} ms {event}: {detail}")
    }
}

/// Elapsed milliseconds between two monotonic instants (the first must be earlier).
fn elapsed_ms_between(origin: Instant, now: Instant) -> u128 {
    now.duration_since(origin).as_millis()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};

    #[test]
    fn formats_events_with_monotonic_milliseconds() {
        assert_eq!(
            format_line(0, "gate armed", "tab=emoji visible=false"),
            "[W11C_SHOW_DEBUG] +0 ms gate armed: tab=emoji visible=false"
        );
        assert_eq!(
            format_line(305, "timeout fired", ""),
            "[W11C_SHOW_DEBUG] +305 ms timeout fired"
        );
        assert_eq!(
            format_line(12, "window.show() called", "deferred"),
            "[W11C_SHOW_DEBUG] +12 ms window.show() called: deferred"
        );
    }

    #[test]
    fn elapsed_is_measured_between_the_armed_instant_and_now() {
        let armed = Instant::now();
        assert_eq!(elapsed_ms_between(armed, armed), 0);
        assert_eq!(
            elapsed_ms_between(armed, armed + Duration::from_millis(123)),
            123
        );
        assert_eq!(
            elapsed_ms_between(armed, armed + Duration::from_millis(300)),
            300
        );
    }
}
