#!/bin/bash
# test-ibus-hotkey.sh - sandbox tests for the IBus emoji hotkey handling in install.sh/uninstall.sh
#
# Runs the REAL remove_ibus_emoji_hotkey() and restore_ibus_emoji_hotkey() functions (extracted
# from the installer scripts) against a fake `gsettings` whose state lives in a throwaway
# /tmp sandbox. Nothing outside the sandbox is touched: no real gsettings/dconf is called and
# neither install.sh nor uninstall.sh is ever executed.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
INSTALL_SH="$REPO_ROOT/scripts/install.sh"
UNINSTALL_SH="$REPO_ROOT/scripts/uninstall.sh"

PASS=0
FAIL=0
RUN_RC=0
WARNINGS=()

pass() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; }

check_eq() {
    if [ "$2" = "$3" ]; then
        pass "$1"
    else
        fail "$1 (expected [$3], got [$2])"
    fi
}

check_exists() {
    if [ -e "$2" ]; then pass "$1"; else fail "$1 (missing: $2)"; fi
}

check_not_exists() {
    if [ ! -e "$2" ]; then pass "$1"; else fail "$1 (still exists: $2)"; fi
}

check_contains() {
    case "$2" in
        *"$3"*) pass "$1" ;;
        *) fail "$1 (expected to contain [$3], got [$2])" ;;
    esac
}

check_not_contains() {
    case "$2" in
        *"$3"*) fail "$1 (expected NOT to contain [$3], got [$2])" ;;
        *) pass "$1" ;;
    esac
}

# True only for a path that really resolves inside /tmp (findmnt catches a /tmp symlink or bind
# mount that points somewhere else). Everything removed with rm -rf must pass this first.
SANDBOX=""
is_under_tmp() {
    local real mnt probe
    real=$(realpath -m -- "$1") || return 1
    case "$real" in
        /tmp/*) ;;
        *) return 1 ;;
    esac
    # findmnt needs a path that already exists, so walk up to the nearest existing ancestor.
    probe="$real"
    while [ ! -e "$probe" ] && [ "$probe" != "/" ]; do
        probe=$(dirname -- "$probe")
    done
    mnt=$(findmnt -n -o TARGET --target "$probe" 2>/dev/null) || return 1
    case "$mnt" in
        /tmp|/tmp/*) return 0 ;;
        /) return 0 ;;  # /tmp is part of the root filesystem on this machine
        *) return 1 ;;
    esac
}

is_inside_sandbox() {
    local real sb
    real=$(realpath -m -- "$1")
    sb=$(realpath -m -- "$SANDBOX")
    case "$real" in
        "$sb"|"$sb"/*) return 0 ;;
        *) return 1 ;;
    esac
}

safe_rm_rf() {
    local p
    for p in "$@"; do
        if ! is_under_tmp "$p" || ! is_inside_sandbox "$p"; then
            printf 'FAIL: refusing to rm -rf %s (not inside the /tmp sandbox)\n' "$p" >&2
            exit 1
        fi
    done
    rm -rf -- "$@"
}

cleanup() {
    local rc=$?
    trap - EXIT INT TERM
    if [ -n "$SANDBOX" ] && [ -d "$SANDBOX" ]; then
        printf '\nSandbox size: %s\n' "$(du -sh "$SANDBOX" 2>/dev/null | cut -f1)"
        if is_under_tmp "$SANDBOX" && is_inside_sandbox "$SANDBOX"; then
            rm -rf -- "$SANDBOX"
        else
            printf 'FAIL: refusing to remove sandbox %s (not under /tmp)\n' "$SANDBOX" >&2
            rc=1
        fi
        if [ -d "$SANDBOX" ]; then
            printf 'FAIL: sandbox was not removed: %s\n' "$SANDBOX" >&2
            rc=1
        else
            printf 'Sandbox cleanup: PASS (removed %s)\n' "$SANDBOX"
        fi
    fi
    exit "$rc"
}
trap cleanup EXIT INT TERM

# --- sandbox with a fake gsettings -----------------------------------------------------------
SANDBOX=$(mktemp -d /tmp/w11c-sandbox.XXXXXX)
BIN_DIR="$SANDBOX/bin"
GS_STORE="$SANDBOX/gsettings"
FAKE_HOME="$SANDBOX/home"
mkdir -p "$BIN_DIR" "$GS_STORE" "$FAKE_HOME"

export HOME="$FAKE_HOME"
export FAKE_GSETTINGS_STORE="$GS_STORE"
export PATH="$BIN_DIR:$PATH"

cat > "$BIN_DIR/gsettings" <<'FAKE_GSETTINGS'
#!/bin/bash
# Fake gsettings: implements list-schemas/get/set against files in $FAKE_GSETTINGS_STORE and
# ignores everything else, so the extracted installer functions can run with no real desktop.
set -euo pipefail
store="${FAKE_GSETTINGS_STORE:?}"
cmd="${1:-}"
shift || true
case "$cmd" in
    list-schemas)
        cat "$store/schemas" 2>/dev/null || true
        ;;
    get)
        file="$store/${1:?}.${2:?}"
        [ -f "$file" ] || exit 1
        cat "$file"
        ;;
    set)
        if [ "${FAKE_GSETTINGS_FAIL_SET:-}" = 1 ]; then exit 1; fi
        file="$store/${1:?}.${2:?}"
        printf '%s\n' "${3:?}" > "$file"
        ;;
    *)
        exit 0
        ;;
esac
FAKE_GSETTINGS
chmod +x "$BIN_DIR/gsettings"

# Never report a running Win11Clip instance: if the restore-only mode ever regressed into the
# normal uninstall path, nothing may be killed.
cat > "$BIN_DIR/pgrep" <<'FAKE_PGREP'
#!/bin/bash
exit 1
FAKE_PGREP
chmod +x "$BIN_DIR/pgrep"

# Any accidental escalation fails instead of running a real privileged command.
cat > "$BIN_DIR/sudo" <<'FAKE_SUDO'
#!/bin/bash
printf '%s\n' "$*" >> "${FAKE_SUDO_LOG:-/dev/null}"
exit 1
FAKE_SUDO
chmod +x "$BIN_DIR/sudo"

# The extracted functions read these as globals; point them into the sandbox, not the real $HOME.
STATE_DIR="$FAKE_HOME/.local/state/win11clip-installer"
IBUS_EMOJI_SCHEMA="org.freedesktop.ibus.panel.emoji"
IBUS_EMOJI_HOTKEY_SAVED="$STATE_DIR/ibus-emoji-hotkey.orig"

# Stubs for what the extracted functions expect from their own scripts.
log() { :; }
success() { :; }
warn() { WARNINGS+=("$1"); }
run_user_gsettings() { gsettings "$@"; }

extract_function() {
    local file="$1" name="$2"
    sed -n "/^${name}()/,/^}/p" "$file"
}

REMOVE_FN=$(extract_function "$INSTALL_SH" remove_ibus_emoji_hotkey)
RESTORE_FN=$(extract_function "$UNINSTALL_SH" restore_ibus_emoji_hotkey)
if [ -z "$REMOVE_FN" ]; then
    printf 'FAIL: remove_ibus_emoji_hotkey() not found in %s\n' "$INSTALL_SH" >&2
    exit 1
fi
if [ -z "$RESTORE_FN" ]; then
    printf 'FAIL: restore_ibus_emoji_hotkey() not found in %s\n' "$UNINSTALL_SH" >&2
    exit 1
fi
eval "$REMOVE_FN"
eval "$RESTORE_FN"

reset_state() {
    safe_rm_rf "$GS_STORE" "$STATE_DIR"
    mkdir -p "$GS_STORE"
    printf '%s\n' "$IBUS_EMOJI_SCHEMA" > "$GS_STORE/schemas"
    WARNINGS=()
}

write_hotkey() { printf '%s\n' "$1" > "$GS_STORE/$IBUS_EMOJI_SCHEMA.hotkey"; }
current_hotkey() { cat "$GS_STORE/$IBUS_EMOJI_SCHEMA.hotkey" 2>/dev/null || true; }
saved_hotkey() { cat "$IBUS_EMOJI_HOTKEY_SAVED" 2>/dev/null || true; }

# Run a function and record its status. The installer functions must never abort the installer,
# so any non-zero return is a test failure and not allowed to kill this harness on the spot.
run_fn() {
    RUN_RC=0
    "$@" || RUN_RC=$?
}

# Run the REAL uninstall.sh in its --restore-ibus-hotkey-only mode (the way `make uninstall`
# invokes it) with HOME/PATH already pointing into the sandbox, so its fake gsettings is used and
# none of the normal uninstall steps may run. env -u SUDO_USER keeps the plain-user path even
# when this harness itself was started from a sudo session; timeout bounds a prompt regression.
UNINSTALL_OUT=""
run_uninstall_restore_only() {
    RUN_RC=0
    UNINSTALL_OUT=$(env -u SUDO_USER timeout 30 bash "$UNINSTALL_SH" --restore-ibus-hotkey-only 2>&1) || RUN_RC=$?
}

# --- tests -----------------------------------------------------------------------------------
printf '== IBus emoji hotkey: shell sandbox tests ==\n'

printf '\n-- Test 1: remove drops only <Super>period and saves the original\n'
reset_state
write_hotkey "['<Super>period', '<Super>semicolon']"
run_fn remove_ibus_emoji_hotkey
check_eq "remove exits 0" "$RUN_RC" 0
check_eq "current IBus hotkey keeps <Super>semicolon only" "$(current_hotkey)" "['<Super>semicolon']"
check_eq "original raw value saved" "$(saved_hotkey)" "['<Super>period', '<Super>semicolon']"

printf '\n-- Test 2: a second run does not overwrite the first saved original\n'
write_hotkey "['<Super>period']"
run_fn remove_ibus_emoji_hotkey
check_eq "second remove exits 0" "$RUN_RC" 0
check_eq "saved original was not overwritten" "$(saved_hotkey)" "['<Super>period', '<Super>semicolon']"
check_eq "empty binding list written as []" "$(current_hotkey)" "[]"

printf '\n-- Test 3: uninstall restores the exact saved value and deletes the file\n'
run_fn restore_ibus_emoji_hotkey
check_eq "restore exits 0" "$RUN_RC" 0
check_eq "setting restored to the exact original" "$(current_hotkey)" "['<Super>period', '<Super>semicolon']"
check_not_exists "saved file deleted after restore" "$IBUS_EMOJI_HOTKEY_SAVED"

printf '\n-- Test 4: restore without a saved file leaves the setting alone\n'
reset_state
write_hotkey "['<Super>semicolon']"
run_fn restore_ibus_emoji_hotkey
check_eq "restore exits 0 without a saved file" "$RUN_RC" 0
check_eq "setting left untouched" "$(current_hotkey)" "['<Super>semicolon']"
check_not_exists "no saved file is created" "$IBUS_EMOJI_HOTKEY_SAVED"

printf '\n-- Test 5: no <Super>period -> no change and nothing saved\n'
reset_state
write_hotkey "['<Super>semicolon', '<Ctrl>space']"
run_fn remove_ibus_emoji_hotkey
check_eq "remove exits 0 when period is absent" "$RUN_RC" 0
check_eq "setting left untouched" "$(current_hotkey)" "['<Super>semicolon', '<Ctrl>space']"
check_not_exists "no original saved" "$IBUS_EMOJI_HOTKEY_SAVED"

printf '\n-- Test 6: no IBus emoji schema -> no change and nothing saved\n'
reset_state
printf 'org.gnome.desktop.interface\n' > "$GS_STORE/schemas"
write_hotkey "['<Super>period']"
run_fn remove_ibus_emoji_hotkey
check_eq "remove exits 0 without the schema" "$RUN_RC" 0
check_eq "setting left untouched" "$(current_hotkey)" "['<Super>period']"
check_not_exists "no original saved" "$IBUS_EMOJI_HOTKEY_SAVED"

printf '\n-- Test 7: failed restore warns and keeps the saved file\n'
reset_state
write_hotkey "[]"
mkdir -p "$STATE_DIR"
printf "['<Super>period']\n" > "$IBUS_EMOJI_HOTKEY_SAVED"
export FAKE_GSETTINGS_FAIL_SET=1
run_fn restore_ibus_emoji_hotkey
unset FAKE_GSETTINGS_FAIL_SET
check_eq "failed restore exits 0 (only warns)" "$RUN_RC" 0
check_eq "setting left as it was" "$(current_hotkey)" "[]"
check_exists "saved file kept for a later retry" "$IBUS_EMOJI_HOTKEY_SAVED"
check_contains "warning was printed" "${WARNINGS[*]:-}" "Could not restore the IBus emoji hotkey"

printf '\n-- Test 8: uninstall.sh --restore-ibus-hotkey-only restores the saved value end to end\n'
reset_state
write_hotkey "[]"
mkdir -p "$STATE_DIR"
printf "['<Super>period', '<Super>semicolon']\n" > "$IBUS_EMOJI_HOTKEY_SAVED"
run_uninstall_restore_only
check_eq "restore-only mode exits 0" "$RUN_RC" 0
check_eq "setting restored to the exact original" "$(current_hotkey)" "['<Super>period', '<Super>semicolon']"
check_not_exists "saved file deleted after restore" "$IBUS_EMOJI_HOTKEY_SAVED"
check_contains "script reports the restore" "$UNINSTALL_OUT" "Restored the IBus emoji hotkey"
check_not_contains "normal uninstall never started (no banner)" "$UNINSTALL_OUT" "Win11 Clipboard History - Uninstaller"

printf '\n-- Test 9: --restore-ibus-hotkey-only without a saved file leaves the setting alone\n'
reset_state
write_hotkey "['<Super>semicolon']"
run_uninstall_restore_only
check_eq "restore-only mode exits 0 without a saved file" "$RUN_RC" 0
check_eq "setting left untouched" "$(current_hotkey)" "['<Super>semicolon']"
check_not_exists "no saved file is created" "$IBUS_EMOJI_HOTKEY_SAVED"
check_not_contains "normal uninstall never started (no banner)" "$UNINSTALL_OUT" "Win11 Clipboard History - Uninstaller"

printf '\n-- Test 10: make uninstall restores the hotkey before removing files\n'
MAKEFILE="$REPO_ROOT/Makefile"
RESTORE_LINE=$(grep -nF 'uninstall.sh --restore-ibus-hotkey-only' "$MAKEFILE" | cut -d: -f1 || true)
FIRST_RM_LINE=$(grep -nF 'rm -f $(DESTDIR)$(BINDIR)/$(APP_NAME)' "$MAKEFILE" | cut -d: -f1 || true)
check_contains "Makefile uninstall calls the restore helper" "$(cat "$MAKEFILE")" "bash scripts/uninstall.sh --restore-ibus-hotkey-only 2>/dev/null || true"
if [ -n "$RESTORE_LINE" ] && [ -n "$FIRST_RM_LINE" ] && [ "$RESTORE_LINE" -lt "$FIRST_RM_LINE" ]; then
    pass "restore runs before the first file removal"
else
    fail "restore does not run before the first file removal (restore line [$RESTORE_LINE], first rm line [$FIRST_RM_LINE])"
fi
# `make -n` only prints recipes; it never runs the uninstaller.
MAKE_DRY=$(make -C "$REPO_ROOT" -n uninstall 2>&1 || true)
check_contains "make -n uninstall prints the restore invocation" "$MAKE_DRY" "bash scripts/uninstall.sh --restore-ibus-hotkey-only"

printf '\n-- Test 11: a non-root SUDO_USER is never escalated through sudo\n'
# `make uninstall` run by a plain user with SUDO_USER in the environment (e.g. started from a
# sudo shell) must call gsettings directly, not `sudo -u`. A fake sudo that fails makes any
# unwanted hop visible; the old code would have warned and kept the saved file.
if [ "$EUID" -eq 0 ]; then
    printf 'SKIP: running as root, the plain-user path cannot be exercised here\n'
else
    reset_state
    write_hotkey "[]"
    mkdir -p "$STATE_DIR"
    printf "['<Super>period']\n" > "$IBUS_EMOJI_HOTKEY_SAVED"
    SUDO_LOG="$SANDBOX/sudo.log"
    : > "$SUDO_LOG"
    cat > "$BIN_DIR/sudo" <<'FAKE_SUDO'
#!/bin/bash
printf '%s\n' "$*" >> "${FAKE_SUDO_LOG:-/dev/null}"
exit 1
FAKE_SUDO
    chmod +x "$BIN_DIR/sudo"
    RUN_RC=0
    UNINSTALL_OUT=$(SUDO_USER="$(id -un)" FAKE_SUDO_LOG="$SUDO_LOG" timeout 30 bash "$UNINSTALL_SH" --restore-ibus-hotkey-only 2>&1) || RUN_RC=$?
    rm -f "$BIN_DIR/sudo"
    check_eq "plain-user restore-only exits 0" "$RUN_RC" 0
    check_eq "hotkey restored without sudo" "$(current_hotkey)" "['<Super>period']"
    check_not_exists "saved file deleted without sudo" "$IBUS_EMOJI_HOTKEY_SAVED"
    check_eq "sudo was never invoked" "$(cat "$SUDO_LOG")" ""
fi

# --- results ---------------------------------------------------------------------------------
printf '\n== Results: %d passed, %d failed ==\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then
    exit 1
fi
printf 'All IBus emoji hotkey shell tests passed.\n'
