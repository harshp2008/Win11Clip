#!/bin/bash
# test-install-restart-needed.sh - sandbox test for the RESTART_NEEDED guard in install.sh
#
# Bug this covers: check_if_restart_required() only ever asserts RESTART_NEEDED=1. On the
# success path (all three GNOME Shell extensions already ACTIVE) it returns without assigning
# the variable, so main()'s `[ "$RESTART_NEEDED" -eq 1 ]` evaluated an empty string and printed
# `[: : integer expected`. The fix initializes RESTART_NEEDED=0 in main(), next to
# EXTENSIONS_MODIFIED=0.
#
# Runs the REAL check_if_restart_required() extracted from scripts/install.sh against a fake
# `gnome-extensions` in a throwaway /tmp sandbox. install.sh itself is never executed and no real
# gnome-extensions/gsettings is called.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
INSTALL_SH="$REPO_ROOT/scripts/install.sh"

PASS=0
FAIL=0
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

check_contains() {
    case "$2" in
        *"$3"*) pass "$1" ;;
        *) fail "$1 (expected to contain [$3], got [$2])" ;;
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

is_inside_sandbox() {
    local real sb
    real=$(realpath -m -- "$1")
    sb=$(realpath -m -- "$SANDBOX")
    case "$real" in
        "$sb"|"$sb"/*) return 0 ;;
        *) return 1 ;;
    esac
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

# --- sandbox with a fake gnome-extensions ----------------------------------------------------
SANDBOX=$(mktemp -d /tmp/w11c-sandbox.XXXXXX)
BIN_DIR="$SANDBOX/bin"
mkdir -p "$BIN_DIR"
export PATH="$BIN_DIR:$PATH"
export XDG_CURRENT_DESKTOP=GNOME

cat > "$BIN_DIR/gnome-extensions" <<'FAKE_GNOME_EXTENSIONS'
#!/bin/bash
# Fake gnome-extensions: every command succeeds. `list --enabled` lists the three extensions
# install.sh enables; `info` reports ACTIVE unless FAKE_GNOME_EXT_INACTIVE names the extension
# that must look broken (State: OUT OF DATE), which is the real failure mode this check catches.
set -euo pipefail
cmd="${1:-}"
shift || true
case "$cmd" in
    enable)
        exit 0 ;;
    list)
        printf '%s\n' \
            'win11-clipboard-bridge@harshp2008.github.com' \
            'window-calls@domandoman.xyz' \
            'spawn-at@harsh.local'
        ;;
    info)
        ext="${1:-}"
        if [ "${FAKE_GNOME_EXT_INACTIVE:-}" = "$ext" ]; then
            echo "State: OUT OF DATE"
        else
            echo "  State: ACTIVE"
        fi
        ;;
    *)
        exit 0 ;;
esac
FAKE_GNOME_EXTENSIONS
chmod +x "$BIN_DIR/gnome-extensions"

# The extracted function reads these globals; stubs stand in for the installer's own helpers.
WARNINGS=()
log() { :; }
warn() { WARNINGS+=("$1"); }
success() { :; }
error() { printf 'FAIL: installer error() called: %s\n' "$1" >&2; exit 1; }

extract_function() {
    local file="$1" name="$2"
    sed -n "/^${name}()/,/^}/p" "$file"
}

CHECK_FN=$(extract_function "$INSTALL_SH" check_if_restart_required)
if [ -z "$CHECK_FN" ]; then
    printf 'FAIL: check_if_restart_required() not found in %s\n' "$INSTALL_SH" >&2
    exit 1
fi
eval "$CHECK_FN"

# The initialization lines at the top of main() (the fix). Evaluated exactly as main() would.
MAIN_INIT=$(sed -n '/^main() {/,/^    echo ""/p' "$INSTALL_SH" \
    | grep -E '^[[:space:]]+(EXTENSIONS_MODIFIED|RESTART_NEEDED)=0$' || true)

# Exactly the line main() runs after check_if_restart_required(): the guard that used to print
# `[: : integer expected` when RESTART_NEEDED was unset.
restart_branch() {
    if [ "$RESTART_NEEDED" -eq 1 ]; then
        echo restart
    else
        echo no-restart
    fi
}

# --- tests -----------------------------------------------------------------------------------
printf '== install.sh RESTART_NEEDED guard: shell sandbox tests ==\n'

printf '\n-- Test 1: main() initializes both flags to 0\n'
check_contains "main() initializes EXTENSIONS_MODIFIED=0" "$MAIN_INIT" "EXTENSIONS_MODIFIED=0"
check_contains "main() initializes RESTART_NEEDED=0" "$MAIN_INIT" "RESTART_NEEDED=0"
RESTART_NEEDED=""
EXTENSIONS_MODIFIED=""
eval "$MAIN_INIT"
check_eq "RESTART_NEEDED starts at 0" "$RESTART_NEEDED" "0"
check_eq "EXTENSIONS_MODIFIED starts at 0" "$EXTENSIONS_MODIFIED" "0"

printf '\n-- Test 2: all extensions ACTIVE -> no restart, guard is clean\n'
RESTART_NEEDED=0
EXTENSIONS_MODIFIED=0
check_if_restart_required
check_eq "all-active success path keeps RESTART_NEEDED=0" "$RESTART_NEEDED" "0"
CHECK_STDERR="$SANDBOX/guard.err"
GUARD_OUT=$(restart_branch 2>"$CHECK_STDERR")
check_eq "integer guard takes the no-restart branch" "$GUARD_OUT" "no-restart"
check_eq "integer guard prints no diagnostic" "$(cat "$CHECK_STDERR")" ""

printf '\n-- Test 3: one extension OUT OF DATE -> restart, guard is clean\n'
RESTART_NEEDED=0
EXTENSIONS_MODIFIED=0
export FAKE_GNOME_EXT_INACTIVE="spawn-at@harsh.local"
check_if_restart_required
unset FAKE_GNOME_EXT_INACTIVE
check_eq "inactive extension asserts RESTART_NEEDED=1" "$RESTART_NEEDED" "1"
GUARD_OUT=$(restart_branch 2>"$CHECK_STDERR")
check_eq "integer guard takes the restart branch" "$GUARD_OUT" "restart"
check_eq "integer guard prints no diagnostic here either" "$(cat "$CHECK_STDERR")" ""

printf '\n-- Test 4: without the init the old bug reproduces (regression anchor)\n'
# Not a wanted behaviour: it proves the guard really was broken on an unset variable, so Test 2
# would fail if the main() initialization were removed.
REPRO_ERR=$(set +u; unset RESTART_NEEDED; restart_branch 2>&1 >/dev/null || true)
check_contains "uninitialized RESTART_NEEDED produces the integer diagnostic" "$REPRO_ERR" "integer"

# --- results ---------------------------------------------------------------------------------
printf '\n== Results: %d passed, %d failed ==\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then
    exit 1
fi
printf 'All installer RESTART_NEEDED shell tests passed.\n'
