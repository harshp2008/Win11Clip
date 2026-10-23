#!/bin/bash
# test-shortcut-app-id.sh - sandbox test for the spawn-at shortcut commands that install.sh writes
# and that uninstall.sh removes.
#
# Bug this covers: the popup's window class changed, spawn-at stopped recognising the window and the
# popup was no longer placed at the cursor. Every shortcut now passes the app's class explicitly
# (`-c io.github.harshp2008.win11clip`) and runs the command `win11clip`. Shortcuts written by earlier
# releases (the old command win11-clipboard-history with no -c, with the upstream class, or with the
# app's own class) must be rewritten in place, never duplicated, and still be removed by uninstall.sh.
#
# Runs the REAL configure_gnome_shortcuts() extracted from scripts/install.sh, and the REAL python
# block of scripts/uninstall.sh, against a fake `gsettings` in a throwaway /tmp sandbox. Nothing here
# calls the real gsettings or touches ~/.config.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
INSTALL_SH="${INSTALL_SH:-$REPO_ROOT/scripts/install.sh}"
UNINSTALL_SH="${UNINSTALL_SH:-$REPO_ROOT/scripts/uninstall.sh}"
APP_ID_RS="$REPO_ROOT/src-tauri/src/app_id.rs"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; }

check_eq() {
    if [ "$2" = "$3" ]; then
        pass "$1"
    else
        fail "$1 (expected [$3], got [$2])"
    fi
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
    probe="$real"
    while [ ! -e "$probe" ] && [ "$probe" != "/" ]; do
        probe=$(dirname -- "$probe")
    done
    mnt=$(findmnt -n -o TARGET --target "$probe" 2>/dev/null) || return 1
    case "$mnt" in
        /tmp|/tmp/*) return 0 ;;
        /) return 0 ;;
        *) return 1 ;;
    esac
}

cleanup() {
    local rc=$?
    trap - EXIT INT TERM
    if [ -n "$SANDBOX" ] && [ -d "$SANDBOX" ]; then
        printf '\nSandbox size: %s\n' "$(du -sh "$SANDBOX" 2>/dev/null | cut -f1)"
        if is_under_tmp "$SANDBOX" && [[ "$(realpath -m -- "$SANDBOX")" == /tmp/w11c-sandbox.* ]]; then
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

SANDBOX=$(mktemp -d /tmp/w11c-sandbox.XXXXXX)
BIN_DIR="$SANDBOX/bin"
export FAKE_GSETTINGS_STATE="$SANDBOX/gsettings-state"
mkdir -p "$BIN_DIR" "$FAKE_GSETTINGS_STATE"
export PATH="$BIN_DIR:$PATH"

# --- fake gsettings: a flat key/value store, enough for the calls install.sh and uninstall.sh make ---
cat > "$BIN_DIR/gsettings" <<'FAKE_GSETTINGS'
#!/bin/bash
set -euo pipefail
STATE="${FAKE_GSETTINGS_STATE:?}"
slot() { printf '%s/%s' "$STATE" "$(printf '%s' "$1|$2" | tr '/:' '__')"; }
case "${1:-}" in
    list-schemas)
        echo org.gnome.settings-daemon.plugins.media-keys
        echo org.gnome.settings-daemon.plugins.media-keys.custom-keybinding
        ;;
    get)
        f=$(slot "$2" "$3")
        if [ -f "$f" ]; then
            cat "$f"
        elif [ "$3" = custom-keybindings ]; then
            echo "@as []"
        else
            echo "''"
        fi
        ;;
    set)
        printf '%s\n' "$4" > "$(slot "$2" "$3")"
        ;;
    reset)
        rm -f "$(slot "$2" "$3")"
        ;;
    reset-recursively)
        prefix=$(printf '%s' "$2|" | tr '/:' '__')
        for f in "$STATE/$prefix"*; do [ -e "$f" ] && rm -f "$f"; done
        ;;
    *)
        exit 0 ;;
esac
FAKE_GSETTINGS
chmod +x "$BIN_DIR/gsettings"

SCHEMA=org.gnome.settings-daemon.plugins.media-keys
BSCHEMA="$SCHEMA.custom-keybinding"
PATH_PREFIX=/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings

gs_get() { gsettings get "$@"; }
entry_cmd() { gs_get "$BSCHEMA:$PATH_PREFIX/$1/" command; }
entry_bind() { gs_get "$BSCHEMA:$PATH_PREFIX/$1/" binding; }
list_value() { gs_get "$SCHEMA" custom-keybindings; }
list_count() { list_value | grep -o "'[^']*'" | wc -l; }

seed_entry() { # path-leaf name command binding
    gsettings set "$BSCHEMA:$PATH_PREFIX/$1/" name "'$2'"
    gsettings set "$BSCHEMA:$PATH_PREFIX/$1/" command "'$3'"
    gsettings set "$BSCHEMA:$PATH_PREFIX/$1/" binding "'$4'"
}

seed_old_forms() {
    rm -rf "$FAKE_GSETTINGS_STATE"; mkdir -p "$FAKE_GSETTINGS_STATE"
    # v0.7.5: bare spawn-at, no -c, the old command
    seed_entry custom0 'Clipboard History' 'spawn-at spawn --anchor cursor -o -15 -15 -m 10 win11-clipboard-history --clipboard' '<Super>v'
    # unreleased 8fb0073 era: the upstream class passed with -c
    seed_entry custom1 'Emoji Picker' '/home/u/.local/bin/spawn-at spawn --anchor cursor -o -15 -15 -m 10 -c dev.gustavosett.clipboard-history win11-clipboard-history --emoji' '<Super>period'
    # the build before the rename: the app's own class but still the old command
    seed_entry custom3 'Clipboard History (Alt)' "/home/u/.local/bin/spawn-at spawn --anchor cursor -o -15 -15 -m 10 -c $APP_ID win11-clipboard-history --clipboard" '<Ctrl><Alt>v'
    # someone else's shortcut, which must never be touched
    seed_entry custom2 'Terminal' 'gnome-terminal' '<Super>t'
    gsettings set "$SCHEMA" custom-keybindings "['$PATH_PREFIX/custom0/', '$PATH_PREFIX/custom1/', '$PATH_PREFIX/custom3/', '$PATH_PREFIX/custom2/']"
}

# --- load the real functions ---------------------------------------------------------------------
log() { :; }
warn() { :; }
success() { :; }
error() { printf 'FAIL: installer error() called: %s\n' "$1" >&2; exit 1; }
remove_ibus_emoji_hotkey() { :; }   # touches the IBus schema; not under test here

extract_function() {
    sed -n "/^${2}()/,/^}/p" "$1"
}
for fn in run_user_gsettings spawn_at_shortcut_exe configure_gnome_shortcuts; do
    body=$(extract_function "$INSTALL_SH" "$fn")
    if [ -z "$body" ]; then
        printf 'FAIL: %s() not found in %s\n' "$fn" "$INSTALL_SH" >&2
        exit 1
    fi
    eval "$body"
done
# The name variables the extracted functions use, read from install.sh itself.
for v in APP_ID APP_DISPLAY_NAME APP_CMD APP_BIN PKG_NAME UNINSTALL_CMD OLD_CMD OLD_BIN OLD_PKG_NAME OLD_UNINSTALL_CMD; do
    eval "$v=\$(sed -n 's/^$v=\"\\(.*\\)\"\$/\\1/p' \"\$INSTALL_SH\" | head -n1)"
done
SUDO_USER=""
printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/spawn-at"
chmod +x "$SANDBOX/spawn-at"
SPAWN_AT_USER_BIN="$SANDBOX/spawn-at"
SPAWN_AT_SYSTEM_BIN="$SANDBOX/no-such-spawn-at"

# --- tests ---------------------------------------------------------------------------------------
printf '== shortcut commands: install.sh / uninstall.sh sandbox tests ==\n'

printf '\n-- Test 1: APP_ID in install.sh is the one in src-tauri/src/app_id.rs\n'
RS_ID=$(grep -o '"io\.github\.[^"]*"' "$APP_ID_RS" | head -n1 | tr -d '"')
check_eq "install.sh APP_ID matches app_id.rs" "$APP_ID" "$RS_ID"
check_eq "APP_ID is the new identity" "$APP_ID" "io.github.harshp2008.win11clip"

printf '\n-- Test 2: old-form shortcuts are rewritten in place for win11clip with -c, not duplicated\n'
seed_old_forms
configure_gnome_shortcuts
WANT_FLAG="-c $APP_ID win11clip"
check_contains "old bare Super+V command gets -c and the new command" "$(entry_cmd custom0)" "spawn --anchor cursor -o -15 -15 -m 10 $WANT_FLAG --clipboard"
check_not_contains "the old command is gone from Super+V" "$(entry_cmd custom0)" "win11-clipboard-history"
check_contains "old-class emoji command is rewritten to the new class and command" "$(entry_cmd custom1)" "-m 10 $WANT_FLAG --emoji"
check_not_contains "the upstream class is gone from the emoji command" "$(entry_cmd custom1)" "dev.gustavosett"
check_contains "own-class old-command Alt shortcut gets the new command" "$(entry_cmd custom3)" "-m 10 $WANT_FLAG --clipboard"
check_not_contains "the old command is gone from the Alt shortcut" "$(entry_cmd custom3)" "win11-clipboard-history"
check_eq "Super+V is shown as Win11Clip" "$(gs_get "$BSCHEMA:$PATH_PREFIX/custom0/" name)" "'Win11Clip'"
check_eq "Super+. is shown as Win11Clip Emoji Picker" "$(gs_get "$BSCHEMA:$PATH_PREFIX/custom1/" name)" "'Win11Clip Emoji Picker'"
check_eq "Ctrl+Alt+V is shown as Win11Clip (Alt)" "$(gs_get "$BSCHEMA:$PATH_PREFIX/custom3/" name)" "'Win11Clip (Alt)'"
check_eq "the user's own shortcut is untouched" "$(entry_cmd custom2)" "'gnome-terminal'"
check_eq "the user's own binding is untouched" "$(entry_bind custom2)" "'<Super>t'"
check_eq "Super+V binding is kept" "$(entry_bind custom0)" "'<Super>v'"
check_eq "Super+. binding is kept" "$(entry_bind custom1)" "'<Super>period'"
check_contains "full spawn-at path is used" "$(entry_cmd custom0)" "$SPAWN_AT_USER_BIN spawn"
check_eq "3 Win11Clip entries + the user's = 4, none duplicated" "$(list_count)" "4"

printf '\n-- Test 3: running it again changes nothing (idempotent)\n'
BEFORE_LIST=$(list_value); BEFORE_CB=$(entry_cmd custom0); BEFORE_EM=$(entry_cmd custom1)
configure_gnome_shortcuts
check_eq "list is unchanged" "$(list_value)" "$BEFORE_LIST"
check_eq "Super+V command is unchanged" "$(entry_cmd custom0)" "$BEFORE_CB"
check_eq "emoji command is unchanged" "$(entry_cmd custom1)" "$BEFORE_EM"

printf '\n-- Test 4: every command written carries -c <app id>\n'
ALL_OK=yes
for leaf in custom0 custom1 custom3; do
    case "$(entry_cmd "$leaf")" in
        *"-c $APP_ID "*) ;;
        *) ALL_OK=no ;;
    esac
done
check_eq "all three Win11Clip commands contain -c $APP_ID" "$ALL_OK" "yes"

printf '\n-- Test 4b: a fresh install writes the new command at the three canonical keys\n'
rm -rf "$FAKE_GSETTINGS_STATE"; mkdir -p "$FAKE_GSETTINGS_STATE"
configure_gnome_shortcuts
for leaf in win11-clipboard-history win11-clipboard-history-alt win11-clipboard-history-emoji; do
    check_contains "fresh $leaf runs win11clip with the class" "$(entry_cmd "$leaf")" "-m 10 -c $APP_ID win11clip --"
done
check_eq "a fresh install makes exactly 3 entries" "$(list_count)" "3"

printf '\n-- Test 5: install.sh writes the new StartupWMClass into the AppImage desktop entry\n'
check_contains "AppImage .desktop heredoc uses \$APP_ID" "$(grep -n 'StartupWMClass=' "$INSTALL_SH")" 'StartupWMClass=$APP_ID'
check_not_contains "no upstream class is left in install.sh's .desktop text" "$(grep -n 'StartupWMClass=' "$INSTALL_SH")" "dev.gustavosett"

printf '\n-- Test 6: uninstall.sh removes old-form and new-form shortcuts, and only those\n'
UNINSTALL_PY=$(sed -n "/python3 -c '/,/^'\$/p" "$UNINSTALL_SH" | sed '1d;$d')
if [ -z "$UNINSTALL_PY" ]; then
    fail "python block not found in uninstall.sh"
else
    # one old-form entry that only the command tells apart (custom path, generic name) next to the others
    seed_old_forms
    seed_entry custom4 'Something' "spawn-at spawn --anchor cursor -o -15 -15 -m 10 -c $APP_ID win11clip --clipboard" '<Ctrl><Alt>v'
    seed_entry custom5 'Else' 'spawn-at spawn --anchor cursor -o -15 -15 -m 10 -c dev.gustavosett.clipboard-history win11-clipboard-history --emoji' '<Super>e'
    gsettings set "$SCHEMA" custom-keybindings "['$PATH_PREFIX/custom0/', '$PATH_PREFIX/custom1/', '$PATH_PREFIX/custom2/', '$PATH_PREFIX/custom3/', '$PATH_PREFIX/custom4/', '$PATH_PREFIX/custom5/']"
    python3 -c "$UNINSTALL_PY" >/dev/null
    REMAINING=$(list_value)
    check_eq "only the user's own shortcut is left in the list" "$REMAINING" "['$PATH_PREFIX/custom2/']"
    check_eq "the user's shortcut keeps its command" "$(entry_cmd custom2)" "'gnome-terminal'"
    check_eq "old-form command entry was reset" "$(entry_cmd custom0)" "''"
    check_eq "own-class old-command entry was reset" "$(entry_cmd custom3)" "''"
    check_eq "new-form command entry was reset" "$(entry_cmd custom4)" "''"
    check_eq "upstream-class entry was reset" "$(entry_cmd custom5)" "''"
fi

# --- results -------------------------------------------------------------------------------------
printf '\n== Results: %d passed, %d failed ==\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then
    exit 1
fi
printf 'All shortcut app-id shell tests passed.\n'
