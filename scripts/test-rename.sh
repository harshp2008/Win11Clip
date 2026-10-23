#!/bin/bash
# test-rename.sh - sandbox tests for the rename to Win11Clip: how install.sh treats an old-name
# package and old-name files, how uninstall.sh treats both name sets, and what `make
# remove-old-name` removes.
#
# Everything runs in a throwaway folder under /tmp with fake dpkg, apt, sudo, gsettings, pgrep and
# gnome-extensions in front of the real ones on PATH. The fake sudo refuses any path outside the
# sandbox, and the scripts' WIN11CLIP_SYSROOT hook points their /usr and /etc paths at the sandbox,
# so nothing here can touch the real system, ~/.config, ~/.local, packages or the GNOME session.
# The real install.sh is never run as a whole; its functions are extracted and run. uninstall.sh is run
# whole, without a terminal (so every prompt takes its default, No).

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
INSTALL_SH="${INSTALL_SH:-$REPO_ROOT/scripts/install.sh}"
UNINSTALL_SH="${UNINSTALL_SH:-$REPO_ROOT/scripts/uninstall.sh}"
MAKEFILE="${MAKEFILE:-$REPO_ROOT/Makefile}"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; }

check_eq() {
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected [$3], got [$2])"; fi
}
check_contains() {
    case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (expected to contain [$3], got [$2])" ;; esac
}
check_not_contains() {
    case "$2" in *"$3"*) fail "$1 (expected NOT to contain [$3], got [$2])" ;; *) pass "$1" ;; esac
}
check_exists() {
    if [ -e "$2" ] || [ -L "$2" ]; then pass "$1"; else fail "$1 (missing: $2)"; fi
}
check_missing() {
    if [ -e "$2" ] || [ -L "$2" ]; then fail "$1 (still there: $2)"; else pass "$1"; fi
}

# True only for a path that really resolves inside /tmp (findmnt catches a /tmp symlink or bind
# mount that points somewhere else). Everything removed with rm -rf must pass this first.
SANDBOX=""
is_under_tmp() {
    local real mnt probe
    real=$(realpath -m -- "$1") || return 1
    case "$real" in /tmp/*) ;; *) return 1 ;; esac
    probe="$real"
    while [ ! -e "$probe" ] && [ "$probe" != "/" ]; do probe=$(dirname -- "$probe"); done
    mnt=$(findmnt -n -o TARGET --target "$probe" 2>/dev/null) || return 1
    case "$mnt" in /tmp|/tmp/*|/) return 0 ;; *) return 1 ;; esac
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
export SANDBOX
BIN="$SANDBOX/bin"
PKGS="$SANDBOX/pkgs"          # the fake package database: one folder per installed package
mkdir -p "$BIN" "$PKGS"
export FAKE_GSETTINGS_STATE="$SANDBOX/gsettings-state"
mkdir -p "$FAKE_GSETTINGS_STATE"

# --- fakes ----------------------------------------------------------------------------------------
# sudo: runs the command only when every absolute path it names is inside the sandbox.
cat > "$BIN/sudo" <<'FAKE'
#!/bin/bash
for a in "$@"; do
    case "$a" in
        "$SANDBOX"/*|/dev/null) ;;
        /*) echo "BLOCKED: sudo $*" >> "$SANDBOX/blocked.log"; exit 1 ;;
    esac
done
echo "sudo $*" >> "$SANDBOX/sudo.log"
exec "$@"
FAKE
# dpkg family, driven by $PKGS/<name>/{version,maintainer,homepage,policy,files}
cat > "$BIN/dpkg" <<'FAKE'
#!/bin/bash
P="$SANDBOX/pkgs"
case "$1" in
    -s) [ -d "$P/$2" ] ;;
    -L) [ -f "$P/$2/files" ] && cat "$P/$2/files" ;;
    -S) found=1
        for d in "$P"/*/; do
            [ -f "$d/files" ] || continue
            if grep -qxF -- "$2" "$d/files"; then echo "$(basename "$d"): $2"; found=0; fi
        done
        exit $found ;;
    *) exit 0 ;;
esac
FAKE
cat > "$BIN/dpkg-query" <<'FAKE'
#!/bin/bash
# dpkg-query -W -f='${Field}' name
fmt=""; pkg=""
while [ $# -gt 0 ]; do
    case "$1" in -W) ;; -f=*) fmt="${1#-f=}" ;; *) pkg="$1" ;; esac
    shift
done
[ -d "$SANDBOX/pkgs/$pkg" ] || exit 1
case "$fmt" in
    *Version*)    cat "$SANDBOX/pkgs/$pkg/version" ;;
    *Maintainer*) cat "$SANDBOX/pkgs/$pkg/maintainer" 2>/dev/null || true ;;
    *Homepage*)   cat "$SANDBOX/pkgs/$pkg/homepage" 2>/dev/null || true ;;
esac
FAKE
cat > "$BIN/apt-cache" <<'FAKE'
#!/bin/bash
[ "$1" = policy ] && cat "$SANDBOX/pkgs/$2/policy" 2>/dev/null
exit 0
FAKE
cat > "$BIN/apt-get" <<'FAKE'
#!/bin/bash
echo "apt-get $*" >> "$SANDBOX/apt.log"
if [ "$1" = remove ]; then
    for a in "$@"; do [ -d "$SANDBOX/pkgs/$a" ] && mv "$SANDBOX/pkgs/$a" "$SANDBOX/removed-pkg-$a"; done
fi
exit 0
FAKE
for noop in pgrep update-desktop-database gtk-update-icon-cache gnome-extensions; do
    printf '#!/bin/sh\necho "%s $*" >> "$SANDBOX/noop.log"\nexit 0\n' "$noop" > "$BIN/$noop"
done
# gsettings: a flat key/value store, enough for the calls uninstall.sh makes
cat > "$BIN/gsettings" <<'FAKE'
#!/bin/bash
set -euo pipefail
STATE="${FAKE_GSETTINGS_STATE:?}"
slot() { printf '%s/%s' "$STATE" "$(printf '%s' "$1|$2" | tr '/:' '__')"; }
case "${1:-}" in
    list-schemas) echo org.gnome.settings-daemon.plugins.media-keys
                  echo org.gnome.settings-daemon.plugins.media-keys.custom-keybinding ;;
    get) f=$(slot "$2" "$3")
         if [ -f "$f" ]; then cat "$f"; elif [ "$3" = custom-keybindings ]; then echo "@as []"; else echo "''"; fi ;;
    set) printf '%s\n' "$4" > "$(slot "$2" "$3")" ;;
    reset) rm -f "$(slot "$2" "$3")" ;;
    reset-recursively) prefix=$(printf '%s' "$2|" | tr '/:' '__')
                       for f in "$STATE/$prefix"*; do [ -e "$f" ] && rm -f "$f"; done ;;
    *) exit 0 ;;
esac
FAKE
chmod +x "$BIN"/*
export PATH="$BIN:$PATH"

add_pkg() { # name version maintainer [homepage] [policy] [files...]
    local name="$1" version="$2" maint="$3" home="${4:-}" policy="${5:-}"
    shift 5 || shift $#
    mkdir -p "$PKGS/$name"
    printf '%s' "$version" > "$PKGS/$name/version"
    printf '%s' "$maint" > "$PKGS/$name/maintainer"
    printf '%s' "$home" > "$PKGS/$name/homepage"
    printf '%s\n' "$policy" > "$PKGS/$name/policy"
    : > "$PKGS/$name/files"
    local f
    for f in "$@"; do printf '%s\n' "$f" >> "$PKGS/$name/files"; done
}
clear_pkgs() { rm -rf "$PKGS"; mkdir -p "$PKGS"; rm -rf -- "${SANDBOX:?}"/removed-pkg-*; rm -f "$SANDBOX/apt.log" "$SANDBOX/sudo.log"; }
# Empties and recreates a folder, but only a folder inside the sandbox.
reset_dirs() {
    local d
    for d in "$@"; do
        case "$(realpath -m -- "$d")" in "$SANDBOX"/*) ;; *) printf 'FAIL: refusing to reset %s\n' "$d" >&2; exit 1 ;; esac
        rm -rf -- "$d"; mkdir -p "$d"
    done
}

# --- load the real functions from install.sh ------------------------------------------------------
extract_function() { sed -n "/^${2}()/,/^}/p" "$1"; }
log() { :; }
warn() { printf 'WARN: %s\n' "$1"; }
success() { :; }
error() { printf 'ERROR: %s\n' "$1"; exit 1; }
for fn in record_install import_old_manifest old_package_origin confirm_packaged_copy_removal \
          remove_packaged_copy owned_by_a_package remove_old_name_files; do
    body=$(extract_function "$INSTALL_SH" "$fn")
    [ -n "$body" ] || { printf 'FAIL: %s() not found in %s\n' "$fn" "$INSTALL_SH" >&2; exit 1; }
    eval "$body"
done
for v in APP_ID APP_DISPLAY_NAME APP_CMD APP_BIN PKG_NAME UNINSTALL_CMD OLD_CMD OLD_BIN OLD_PKG_NAME OLD_UNINSTALL_CMD; do
    eval "$v=\$(sed -n 's/^$v=\"\\(.*\\)\"\$/\\1/p' \"\$INSTALL_SH\" | head -n1)"
done
export HOME="$SANDBOX/home"
export XDG_CONFIG_HOME="$HOME/.config" XDG_DATA_HOME="$HOME/.local/share" XDG_STATE_HOME="$HOME/.local/state" XDG_CACHE_HOME="$HOME/.cache"
mkdir -p "$HOME"
STATE_DIR="$HOME/.local/state/win11clip-installer"
MANIFEST_DIR="$STATE_DIR"; MANIFEST="$STATE_DIR/installer-manifest"
OLD_MANIFEST="$HOME/.config/win11-clipboard-history/installer-manifest"
BACKUP_DIR="$STATE_DIR/backup"
SYSROOT="$SANDBOX/root"
mkdir -p "$SYSROOT"
export WIN11CLIP_SYSROOT="$SYSROOT"

# Run confirm_packaged_copy_removal in a subshell; ANSWER is what the user types (y or n).
confirm_with() { # answer -> prints output, exit status in $CONFIRM_RC, REMOVE_PACKAGE in $SANDBOX/remove.flag
    local answer="$1"
    set +e
    CONFIRM_OUT=$(
        ask_yes_no() { [ "$answer" = y ]; }
        REMOVE_PACKAGE=false
        confirm_packaged_copy_removal
        echo "$REMOVE_PACKAGE" > "$SANDBOX/remove.flag"
    )
    CONFIRM_RC=$?
    set -e
}

printf '== rename: install.sh / uninstall.sh / make sandbox tests ==\n'

# ================================================================================================
printf '\n-- Test 1: the names in install.sh and uninstall.sh are the same\n'
for v in APP_ID APP_DISPLAY_NAME APP_CMD APP_BIN PKG_NAME UNINSTALL_CMD OLD_CMD OLD_BIN OLD_PKG_NAME OLD_UNINSTALL_CMD; do
    un=$(sed -n "s/^$v=\"\\(.*\\)\"\$/\\1/p" "$UNINSTALL_SH" | head -n1)
    check_eq "$v is the same in uninstall.sh" "$un" "${!v}"
done
check_eq "display name" "$APP_DISPLAY_NAME" "Win11Clip"
check_eq "command" "$APP_CMD" "win11clip"
check_eq "binary" "$APP_BIN" "win11clip-bin"
check_eq "package" "$PKG_NAME" "win11clip"
check_eq "old package" "$OLD_PKG_NAME" "win11-clipboard-history"

# ================================================================================================
printf '\n-- Test 2: how install.sh classifies an installed package of the old name\n'
clear_pkgs
check_eq "no package -> none" "$(old_package_origin)" "none"

clear_pkgs; add_pkg win11clip 0.7.6 harshp2008 https://github.com/harshp2008/Win11Clip "" /usr/bin/win11clip
check_eq "the NEW name installed is not the old one -> none" "$(old_package_origin)" "none"

clear_pkgs; add_pkg win11-clipboard-history 0.7.6 harshp2008 https://github.com/harshp2008/Win11Clip "100 /var/lib/dpkg/status"
check_eq "maintainer harshp2008 -> own" "$(old_package_origin)" "own"

clear_pkgs; add_pkg win11-clipboard-history 0.7.5 gustavosett "" "500 https://dl.cloudsmith.io/public/gustavosett/clipboard-manager/deb/ubuntu noble/main amd64 Packages"
check_eq "known from the upstream repository -> upstream" "$(old_package_origin)" "upstream"

clear_pkgs; add_pkg win11-clipboard-history 0.7.5 gustavosett "" "100 /var/lib/dpkg/status"
check_eq "gustavosett metadata, no repository (a Win11Clip <= 0.7.5 release looks like this) -> unknown" "$(old_package_origin)" "unknown"

# ================================================================================================
printf '\n-- Test 3: an old-name package of the owner'"'"'s own build is offered for removal, replaced with a backup\n'
clear_pkgs; rm -rf "$STATE_DIR"
mkdir -p "$SANDBOX/files"
echo "wrapper" > "$SANDBOX/files/win11-clipboard-history"
add_pkg win11-clipboard-history 0.7.6 harshp2008 https://github.com/harshp2008/Win11Clip "100 /var/lib/dpkg/status" "$SANDBOX/files/win11-clipboard-history"
confirm_with n
check_eq "answering No cancels the install" "$CONFIRM_RC" "1"
check_contains "the prompt says it is the earlier Win11Clip build" "$CONFIRM_OUT" "earlier Win11Clip build"
check_contains "the prompt names the new package" "$CONFIRM_OUT" "win11clip"
check_contains "the prompt says the history and settings are not touched" "$CONFIRM_OUT" "clipboard history and settings"
check_contains "the prompt says where the backup goes" "$CONFIRM_OUT" "$BACKUP_DIR/package"
check_missing "nothing was removed after No" "$SANDBOX/apt.log"
check_exists "the package is still installed after No" "$PKGS/win11-clipboard-history"

confirm_with y
check_eq "answering Yes continues" "$CONFIRM_RC" "0"
check_eq "REMOVE_PACKAGE is set by a Yes" "$(cat "$SANDBOX/remove.flag")" "true"
REMOVE_PACKAGE=true
remove_packaged_copy
check_contains "apt-get remove was run for the old package" "$(cat "$SANDBOX/apt.log")" "remove -y win11-clipboard-history"
check_exists "the old package's files were saved first" "$BACKUP_DIR/package/win11-clipboard-history_0.7.6_files.tar.gz"
check_contains "the removal is recorded for uninstall.sh" "$(cat "$MANIFEST")" "removed-package:win11-clipboard-history=0.7.6"
check_missing "the old package is gone" "$PKGS/win11-clipboard-history"

# ================================================================================================
printf '\n-- Test 4: the upstream project'"'"'s package is never touched without a Yes\n'
clear_pkgs; rm -rf "$STATE_DIR"
add_pkg win11-clipboard-history 0.7.5 gustavosett "" "500 https://dl.cloudsmith.io/public/gustavosett/clipboard-manager/deb/ubuntu noble/main amd64 Packages" "$SANDBOX/files/win11-clipboard-history"
confirm_with n
check_eq "No cancels" "$CONFIRM_RC" "1"
check_contains "it says this is the upstream project's package" "$CONFIRM_OUT" "upstream project's package"
check_not_contains "it is not called an earlier Win11Clip build" "$CONFIRM_OUT" "earlier Win11Clip build"
check_missing "apt-get was not called" "$SANDBOX/apt.log"
check_exists "the upstream package is still installed" "$PKGS/win11-clipboard-history"
check_missing "no backup was made without a Yes" "$BACKUP_DIR"
# without remove_packaged_copy being allowed (REMOVE_PACKAGE=false) it does nothing, even if called
REMOVE_PACKAGE=false
remove_packaged_copy
check_missing "remove_packaged_copy does nothing without consent" "$SANDBOX/apt.log"

clear_pkgs
add_pkg win11-clipboard-history 0.7.5 gustavosett "" "100 /var/lib/dpkg/status" "$SANDBOX/files/win11-clipboard-history"
confirm_with n
check_contains "metadata that cannot be told apart is shown with its maintainer" "$CONFIRM_OUT" "maintainer: gustavosett"
check_contains "and it says they cannot be told apart" "$CONFIRM_OUT" "cannot be told apart"
check_missing "still nothing removed" "$SANDBOX/apt.log"

clear_pkgs
confirm_with n
check_eq "no old package: nothing to ask" "$CONFIRM_RC" "0"
check_eq "and nothing is removed" "$(cat "$SANDBOX/remove.flag")" "false"

# ================================================================================================
printf '\n-- Test 5: the old name'"'"'s record, files and links\n'
reset_dirs "$HOME"; mkdir -p "$HOME/.config/win11-clipboard-history"
printf 'apt-build:libfoo\nnvm-installed\n' > "$OLD_MANIFEST"
import_old_manifest
check_eq "the old record is copied to the new place" "$(cat "$MANIFEST")" "$(printf 'apt-build:libfoo\nnvm-installed')"
check_exists "the old record is left in place (uninstall.sh removes it)" "$OLD_MANIFEST"
echo "changed" > "$MANIFEST"; import_old_manifest
check_eq "importing again does not overwrite" "$(cat "$MANIFEST")" "changed"

clear_pkgs
OWNED="$SYSROOT/usr/bin/win11-clipboard-history"
mkdir -p "$SYSROOT/usr/bin" "$SYSROOT/usr/local/bin" "$SYSROOT/usr/local/lib/win11-clipboard-history" \
         "$SYSROOT/usr/local/share/applications" "$SYSROOT/usr/share/applications" \
         "$SYSROOT/usr/local/share/icons/hicolor/128x128/apps" "$SYSROOT/usr/share/icons/hicolor/128x128/apps"
touch "$SYSROOT/usr/local/bin/win11-clipboard-history" "$SYSROOT/usr/local/lib/win11-clipboard-history/win11-clipboard-history-bin" \
      "$SYSROOT/usr/local/share/applications/win11-clipboard-history.desktop" \
      "$SYSROOT/usr/local/share/icons/hicolor/128x128/apps/win11-clipboard-history.png" \
      "$SYSROOT/usr/share/applications/win11-clipboard-history.desktop"
ln -s "$SYSROOT/usr/local/bin/win11-clipboard-history" "$OWNED"
# files of the NEW name, user data, and a file an installed package owns
touch "$SYSROOT/usr/local/bin/win11clip" "$SYSROOT/usr/share/applications/io.github.harshp2008.win11clip.desktop"
mkdir -p "$HOME/.local/share/win11-clipboard-history" "$HOME/.local/share/win11clip"
echo '[]' > "$HOME/.local/share/win11-clipboard-history/history.json"
echo '[]' > "$HOME/.local/share/win11clip/history.json"
add_pkg some-package 1.0 someone "" "" "$SYSROOT/usr/share/applications/win11-clipboard-history.desktop"
remove_old_name_files
check_missing "old launcher under /usr/local/bin removed" "$SYSROOT/usr/local/bin/win11-clipboard-history"
check_missing "the /usr/bin link of the old name removed" "$OWNED"
check_missing "old library folder removed" "$SYSROOT/usr/local/lib/win11-clipboard-history"
check_missing "old menu entry under /usr/local removed" "$SYSROOT/usr/local/share/applications/win11-clipboard-history.desktop"
check_missing "old icon removed" "$SYSROOT/usr/local/share/icons/hicolor/128x128/apps/win11-clipboard-history.png"
check_exists "a file a package owns is left to that package" "$SYSROOT/usr/share/applications/win11-clipboard-history.desktop"
check_exists "the new launcher is untouched" "$SYSROOT/usr/local/bin/win11clip"
check_exists "the new menu entry is untouched" "$SYSROOT/usr/share/applications/io.github.harshp2008.win11clip.desktop"
check_exists "old user data is untouched" "$HOME/.local/share/win11-clipboard-history/history.json"
check_exists "new user data is untouched" "$HOME/.local/share/win11clip/history.json"
check_missing "the fake sudo blocked nothing" "$SANDBOX/blocked.log"
remove_old_name_files
check_exists "running it again changes nothing (new launcher still there)" "$SYSROOT/usr/local/bin/win11clip"

# ================================================================================================
printf '\n-- Test 6: uninstall.sh finds the processes of both name sets\n'
FAKEPROC="$SANDBOX/fakeproc"
mkdir -p "$FAKEPROC"
# pgrep -x <comm> -> pids; readlink /proc/<pid>/exe -> the executable (shadows the real tools)
cat > "$BIN/pgrep" <<'FAKE'
#!/bin/bash
# pgrep -x NAME
name="$2"
[ -f "$SANDBOX/fakeproc/comm.$name" ] && cat "$SANDBOX/fakeproc/comm.$name"
exit 0
FAKE
cat > "$BIN/readlink" <<'FAKE'
#!/bin/bash
pid="${1#/proc/}"; pid="${pid%/exe}"
[ -f "$SANDBOX/fakeproc/exe.$pid" ] && cat "$SANDBOX/fakeproc/exe.$pid" || exit 1
FAKE
chmod +x "$BIN/pgrep" "$BIN/readlink"
echo 101 > "$FAKEPROC/comm.win11clip-bin";            echo /usr/bin/win11clip-bin > "$FAKEPROC/exe.101"
echo 202 > "$FAKEPROC/comm.win11-clipboard";          echo /usr/lib/win11-clipboard-history/win11-clipboard-history-bin > "$FAKEPROC/exe.202"
echo 303 >> "$FAKEPROC/comm.win11-clipboard";         echo /home/u/.local/bin/win11-clipboard-history.AppImage > "$FAKEPROC/exe.303"
echo 404 >> "$FAKEPROC/comm.win11-clipboard";         echo /usr/bin/win11-clipboard-manager-other > "$FAKEPROC/exe.404"
echo 505 > "$FAKEPROC/comm.win11clip.AppIm";          echo /home/u/.local/bin/win11clip.AppImage > "$FAKEPROC/exe.505"
for script in "$UNINSTALL_SH" "$INSTALL_SH"; do
    set +e
    PIDS=$(
        for v in APP_ID APP_DISPLAY_NAME APP_CMD APP_BIN OLD_CMD OLD_BIN; do
            eval "$v=\$(sed -n 's/^$v=\"\\(.*\\)\"\$/\\1/p' \"$script\" | head -n1)"
        done
        eval "$(extract_function "$script" app_pids)"
        if [ "$script" = "$INSTALL_SH" ]; then app_pids "$APP_BIN" "$APP_CMD.AppImage" "$OLD_BIN" "$OLD_CMD.AppImage"; else app_pids; fi | sort -n | tr '\n' ' '
    )
    set -e
    check_eq "$(basename "$script"): finds the new binary, both AppImages and the old binary, but not another program" "$PIDS" "101 202 303 505 "
done

# ================================================================================================
printf '\n-- Test 7: uninstall.sh removes both name sets and keeps the user'"'"'s data (whole script, in the sandbox)\n'
rm -f "$BIN/pgrep" "$BIN/readlink"
printf '#!/bin/sh\nexit 0\n' > "$BIN/pgrep"; chmod +x "$BIN/pgrep"
clear_pkgs; reset_dirs "$HOME" "$SYSROOT" "$FAKE_GSETTINGS_STATE"

seed_system() { # create files of both name sets under the sandbox "system"
    local d f
    for d in usr/bin usr/local/bin usr/share/applications usr/local/share/applications usr/share/metainfo \
             usr/share/icons/hicolor/128x128/apps usr/share/icons/hicolor/256x256/apps usr/share/icons/hicolor/scalable/apps \
             usr/local/share/icons/hicolor/128x128/apps usr/local/share/icons/hicolor/256x256/apps \
             usr/local/share/icons/hicolor/scalable/apps usr/local/share/metainfo \
             usr/local/lib/win11clip usr/local/lib/win11-clipboard-history etc/udev/rules.d etc/modules-load.d; do
        mkdir -p "$SYSROOT/$d"
    done
    for f in usr/bin/win11clip usr/bin/win11clip-bin usr/bin/win11-clipboard-history usr/bin/win11-clipboard-history-bin \
             usr/local/bin/win11clip usr/local/bin/win11-clipboard-history usr/local/bin/win11clip-uninstall \
             usr/local/bin/win11-clipboard-uninstall \
             usr/share/applications/io.github.harshp2008.win11clip.desktop usr/share/applications/win11clip.desktop \
             usr/share/applications/win11-clipboard-history.desktop usr/local/share/applications/win11-clipboard-history.desktop \
             usr/share/metainfo/io.github.harshp2008.win11clip.metainfo.xml \
             usr/share/icons/hicolor/128x128/apps/io.github.harshp2008.win11clip.png \
             usr/share/icons/hicolor/256x256/apps/io.github.harshp2008.win11clip.png \
             usr/share/icons/hicolor/scalable/apps/io.github.harshp2008.win11clip.svg \
             usr/share/icons/hicolor/128x128/apps/win11-clipboard-history.png \
             usr/local/share/icons/hicolor/256x256/apps/win11-clipboard-history.png \
             usr/local/share/metainfo/io.github.harshp2008.win11clip.metainfo.xml \
             usr/local/share/icons/hicolor/scalable/apps/io.github.harshp2008.win11clip.svg \
             usr/local/share/icons/hicolor/scalable/apps/win11-clipboard-history.svg \
             usr/local/lib/win11clip/win11clip-bin usr/local/lib/win11-clipboard-history/win11-clipboard-history-bin \
             etc/udev/rules.d/99-win11-clipboard-input.rules etc/modules-load.d/win11-clipboard.conf; do
        echo x > "$SYSROOT/$f"
    done
    # user-level files of both name sets
    mkdir -p "$HOME/.config/autostart" "$HOME/.local/bin" "$HOME/.local/share/applications" "$HOME/.local/state/win11clip-installer"
    for f in .config/autostart/io.github.harshp2008.win11clip.desktop .config/autostart/win11-clipboard-history.desktop \
             .config/autostart/win11clip-firstrun.desktop \
             .local/bin/win11clip .local/bin/win11clip.AppImage .local/bin/win11-clipboard-history .local/bin/win11-clipboard-history.AppImage \
             .local/share/applications/io.github.harshp2008.win11clip.desktop .local/share/applications/win11-clipboard-history.desktop; do
        echo x > "$HOME/$f"
    done
    # the user's data, both name sets
    mkdir -p "$HOME/.config/win11clip" "$HOME/.local/share/win11clip" "$HOME/.cache/win11clip/gifs" \
             "$HOME/.config/win11-clipboard-history" "$HOME/.local/share/win11-clipboard-history" "$HOME/.cache/win11-clipboard-history/gifs"
    echo '{"first_run_completed":true}' > "$HOME/.config/win11clip/setup.json"
    echo '[{"id":"1"}]' > "$HOME/.local/share/win11clip/history.json"
    echo GIF > "$HOME/.cache/win11clip/gifs/a.gif"
    echo '{"first_run_completed":true}' > "$HOME/.config/win11-clipboard-history/setup.json"
    echo '[{"id":"0"}]' > "$HOME/.local/share/win11-clipboard-history/history.json"
    echo GIF > "$HOME/.cache/win11-clipboard-history/gifs/old.gif"
    echo 'apt-build:libfoo' > "$HOME/.config/win11-clipboard-history/installer-manifest"
    echo 'nvm-installed' > "$HOME/.local/state/win11clip-installer/installer-manifest"
}

seed_gsettings() {
    local schema=org.gnome.settings-daemon.plugins.media-keys prefix=/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings
    local i=0 cmd bind list="" name
    while IFS='|' read -r name cmd bind; do
        gsettings set "$schema.custom-keybinding:$prefix/custom$i/" name "'$name'"
        gsettings set "$schema.custom-keybinding:$prefix/custom$i/" command "'$cmd'"
        gsettings set "$schema.custom-keybinding:$prefix/custom$i/" binding "'$bind'"
        list="$list${list:+, }'$prefix/custom$i/'"
        i=$((i + 1))
    done <<'EOF'
Clipboard History|spawn-at spawn --anchor cursor -o -15 -15 -m 10 win11-clipboard-history --clipboard|<Super>v
Emoji Picker|/h/.local/bin/spawn-at spawn --anchor cursor -o -15 -15 -m 10 -c dev.gustavosett.clipboard-history win11-clipboard-history --emoji|<Super>period
Old own class|/h/.local/bin/spawn-at spawn --anchor cursor -o -15 -15 -m 10 -c io.github.harshp2008.win11clip win11-clipboard-history --clipboard|<Ctrl><Alt>v
Win11Clip|/h/.local/bin/spawn-at spawn --anchor cursor -o -15 -15 -m 10 -c io.github.harshp2008.win11clip win11clip --clipboard|<Super>x
Terminal|gnome-terminal|<Super>t
EOF
    gsettings set "$schema" custom-keybindings "[$list]"
}

seed_system; seed_gsettings
HOME_BEFORE=$(find "$HOME/.config/win11clip" "$HOME/.local/share/win11clip" "$HOME/.cache/win11clip" \
                   "$HOME/.config/win11-clipboard-history" "$HOME/.local/share/win11-clipboard-history" "$HOME/.cache/win11-clipboard-history" \
                   -type f ! -name installer-manifest | sort | xargs md5sum)

set +e
UNINSTALL_OUT=$(setsid --wait env WIN11CLIP_SYSROOT="$SYSROOT" HOME="$HOME" bash "$UNINSTALL_SH" < /dev/null 2>&1)
UNINSTALL_RC=$?
set -e
check_eq "uninstall.sh finishes without error" "$UNINSTALL_RC" "0"
check_missing "nothing outside the sandbox was touched (the fake sudo blocked nothing)" "$SANDBOX/blocked.log"

for f in usr/bin/win11clip usr/bin/win11clip-bin usr/bin/win11-clipboard-history usr/bin/win11-clipboard-history-bin \
         usr/local/bin/win11clip usr/local/bin/win11-clipboard-history usr/local/bin/win11clip-uninstall usr/local/bin/win11-clipboard-uninstall \
         usr/share/applications/io.github.harshp2008.win11clip.desktop usr/share/applications/win11clip.desktop \
         usr/share/applications/win11-clipboard-history.desktop usr/local/share/applications/win11-clipboard-history.desktop \
         usr/share/metainfo/io.github.harshp2008.win11clip.metainfo.xml \
         usr/share/icons/hicolor/128x128/apps/io.github.harshp2008.win11clip.png usr/share/icons/hicolor/256x256/apps/io.github.harshp2008.win11clip.png \
         usr/share/icons/hicolor/scalable/apps/io.github.harshp2008.win11clip.svg usr/share/icons/hicolor/128x128/apps/win11-clipboard-history.png \
         usr/local/share/icons/hicolor/256x256/apps/win11-clipboard-history.png \
         usr/local/share/metainfo/io.github.harshp2008.win11clip.metainfo.xml \
         usr/local/share/icons/hicolor/scalable/apps/io.github.harshp2008.win11clip.svg \
         usr/local/share/icons/hicolor/scalable/apps/win11-clipboard-history.svg \
         usr/local/lib/win11clip usr/local/lib/win11-clipboard-history \
         etc/udev/rules.d/99-win11-clipboard-input.rules etc/modules-load.d/win11-clipboard.conf; do
    check_missing "removed: /$f" "$SYSROOT/$f"
done
for f in .config/autostart/io.github.harshp2008.win11clip.desktop .config/autostart/win11-clipboard-history.desktop \
         .config/autostart/win11clip-firstrun.desktop .local/bin/win11clip .local/bin/win11clip.AppImage .local/bin/win11-clipboard-history \
         .local/bin/win11-clipboard-history.AppImage .local/share/applications/io.github.harshp2008.win11clip.desktop \
         .local/share/applications/win11-clipboard-history.desktop \
         .config/win11-clipboard-history/installer-manifest .local/state/win11clip-installer/installer-manifest; do
    check_missing "removed: ~/$f" "$HOME/$f"
done

HOME_AFTER=$(find "$HOME/.config/win11clip" "$HOME/.local/share/win11clip" "$HOME/.cache/win11clip" \
                  "$HOME/.config/win11-clipboard-history" "$HOME/.local/share/win11-clipboard-history" "$HOME/.cache/win11-clipboard-history" \
                  -type f ! -name installer-manifest | sort | xargs md5sum)
check_eq "every file in the data folders of both names is still there, unchanged" "$HOME_AFTER" "$HOME_BEFORE"
check_contains "the message says the data was NOT deleted" "$UNINSTALL_OUT" "were NOT deleted"
for d in .config/win11clip .local/share/win11clip .cache/win11clip .config/win11-clipboard-history .local/share/win11-clipboard-history .cache/win11-clipboard-history; do
    check_contains "the message lists ~/$d" "$UNINSTALL_OUT" "$HOME/$d"
done
check_contains "the final line names Win11Clip" "$UNINSTALL_OUT" "Win11Clip has been removed"
check_not_contains "the old product name is not shown as the thing removed" "$UNINSTALL_OUT" "Win11 Clipboard History has been removed"

# shortcuts: every Win11Clip form (old command, upstream class, own class, new command) was reset; the user's was not
SCHEMA=org.gnome.settings-daemon.plugins.media-keys
check_eq "only the user's own shortcut is left in the list" "$(gsettings get $SCHEMA custom-keybindings)" "['/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom4/']"
check_eq "the user's shortcut keeps its command" "$(gsettings get $SCHEMA.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom4/ command)" "'gnome-terminal'"

# ================================================================================================
printf '\n-- Test 8: uninstall.sh keeps the files of a package the user chose to keep (default No)\n'
clear_pkgs; reset_dirs "$HOME" "$SYSROOT" "$FAKE_GSETTINGS_STATE"
seed_system
add_pkg win11clip 0.7.6 harshp2008 "" "" "$SYSROOT/usr/bin/win11clip" "$SYSROOT/usr/bin/win11clip-bin" \
    "$SYSROOT/usr/share/applications/io.github.harshp2008.win11clip.desktop"
set +e
UNINSTALL_OUT=$(setsid --wait env WIN11CLIP_SYSROOT="$SYSROOT" HOME="$HOME" bash "$UNINSTALL_SH" < /dev/null 2>&1)
set -e
check_contains "it found the package and asked" "$UNINSTALL_OUT" "installed as a system package: win11clip 0.7.6"
check_contains "it kept the package (No is the default)" "$UNINSTALL_OUT" "Kept the package"
check_missing "apt-get remove was not run" "$SANDBOX/apt.log"
check_exists "the package's launcher is left in place" "$SYSROOT/usr/bin/win11clip"
check_exists "the package's menu entry is left in place" "$SYSROOT/usr/share/applications/io.github.harshp2008.win11clip.desktop"
check_missing "files of the old name that no package owns are still removed" "$SYSROOT/usr/local/bin/win11-clipboard-history"
check_contains "the summary says it is partly uninstalled" "$UNINSTALL_OUT" "Partly uninstalled"
check_exists "the uninstaller is kept while the package is (so it can be run again)" "$SYSROOT/usr/local/bin/win11clip-uninstall"
check_exists "and so is the old-name link to it" "$SYSROOT/usr/local/bin/win11-clipboard-uninstall"
check_contains "the message says the uninstaller was kept and how to delete it" "$UNINSTALL_OUT" "this uninstaller (/usr/local/bin/win11clip-uninstall /usr/local/bin/win11-clipboard-uninstall), because the app package is still installed"
check_contains "the kept package comes with its removal command" "$UNINSTALL_OUT" "delete: sudo apt-get remove win11clip"

# ================================================================================================
printf '\n-- Test 9: `make remove-old-name` (and so `make install` / `make uninstall`) removes the old name only\n'
D="$SANDBOX/destdir"
mkdir -p "$D/usr/local/bin" "$D/usr/local/lib/win11-clipboard-history" "$D/usr/local/lib/win11clip" "$D/usr/local/share/applications" \
         "$D/usr/local/share/icons/hicolor/128x128/apps" "$D/usr/bin"
touch "$D/usr/local/bin/win11-clipboard-history" "$D/usr/local/lib/win11-clipboard-history/win11-clipboard-history-bin" \
      "$D/usr/local/share/applications/win11-clipboard-history.desktop" "$D/usr/local/share/icons/hicolor/128x128/apps/win11-clipboard-history.png" \
      "$D/usr/local/bin/win11clip" "$D/usr/local/lib/win11clip/win11clip-bin" "$D/usr/local/share/applications/io.github.harshp2008.win11clip.desktop"
ln -s "$D/usr/local/bin/win11-clipboard-history" "$D/usr/bin/win11-clipboard-history"
make -s -f "$MAKEFILE" -C "$REPO_ROOT" remove-old-name DESTDIR="$D" >/dev/null
check_missing "old launcher removed" "$D/usr/local/bin/win11-clipboard-history"
check_missing "old /usr/bin link removed" "$D/usr/bin/win11-clipboard-history"
check_missing "old library folder removed" "$D/usr/local/lib/win11-clipboard-history"
check_missing "old menu entry removed" "$D/usr/local/share/applications/win11-clipboard-history.desktop"
check_missing "old icon removed" "$D/usr/local/share/icons/hicolor/128x128/apps/win11-clipboard-history.png"
check_exists "new launcher kept" "$D/usr/local/bin/win11clip"
check_exists "new library folder kept" "$D/usr/local/lib/win11clip/win11clip-bin"
check_exists "new menu entry kept" "$D/usr/local/share/applications/io.github.harshp2008.win11clip.desktop"
make -s -f "$MAKEFILE" -C "$REPO_ROOT" remove-old-name DESTDIR="$D" >/dev/null
check_exists "running it twice changes nothing" "$D/usr/local/bin/win11clip"

# ================================================================================================
printf '\n-- Test 10: a full fake install, then uninstall.sh, leaves exactly the allowed set of files\n'
# The install is the real `make install` (into the sandbox, from a tree of links, with a stand-in binary)
# plus the real install.sh functions that write user-level and system files. The fake killall keeps
# `make install` from signalling the developer's running app. Directories are not compared: the system
# ones (/usr/local/lib, /etc/udev/rules.d, ...) are shared and are never removed.
for noop in killall pkill gnome-shell notify-send udevadm modprobe; do
    printf '#!/bin/sh\necho "%s $*" >> "$SANDBOX/noop.log"\nexit 0\n' "$noop" > "$BIN/$noop"; chmod +x "$BIN/$noop"
done
clear_pkgs; reset_dirs "$HOME" "$SYSROOT" "$FAKE_GSETTINGS_STATE"
mkdir -p "$SYSROOT/usr/bin" "$SYSROOT/usr/local/bin"
seed_system   # old-name files, user data, and an installer record, as an older install left them
echo 'backup copy' > "$STATE_DIR/backup/apt-source-note" 2>/dev/null || { mkdir -p "$STATE_DIR/backup"; echo 'backup copy' > "$STATE_DIR/backup/apt-source-note"; }

MINI="$SANDBOX/minitree"
mkdir -p "$MINI/src-tauri/target/release" "$MINI/scripts"
printf '#!/bin/sh\nexit 0\n' > "$MINI/src-tauri/target/release/win11clip-bin"
for l in Makefile extensions bundled-deps; do ln -s "$REPO_ROOT/$l" "$MINI/$l"; done
for l in icons bundle; do ln -s "$REPO_ROOT/src-tauri/$l" "$MINI/src-tauri/$l"; done
cp "$UNINSTALL_SH" "$MINI/scripts/uninstall.sh"
make -s -f "$MINI/Makefile" -C "$MINI" install DESTDIR="$SYSROOT" > "$SANDBOX/make-install.log" 2>&1 \
    || { fail "make install into the sandbox failed"; tail -n 20 "$SANDBOX/make-install.log" >&2; }

INSTALL_FUNCS=$(
    for fn in run_user_gsettings remove_ibus_emoji_hotkey install_gnome_extensions install_window_calls; do extract_function "$INSTALL_SH" "$fn"; done
    # this function holds a heredoc with its own "}" lines, so cut it by line range
    sed -n '/^setup_post_login_enable()/,/^check_if_restart_required()/p' "$INSTALL_SH" | sed '$d'
    # the uninstaller goes to /usr/local/bin: point that at the sandbox (install.sh runs it through sudo)
    extract_function "$INSTALL_SH" install_uninstaller | sed "s#\"/usr/local/bin/#\"$SYSROOT/usr/local/bin/#g"
)
check_eq "install.sh's install_uninstaller writes to two /usr/local/bin paths (the test redirects both)" "$(printf '%s' "$INSTALL_FUNCS" | grep -c "$SYSROOT/usr/local/bin/")" "2"
AUTOSTART_HEREDOC=$(sed -n '/^    cat > "\$autostart_dir\/spawn-at-autoupdate.desktop"/,/^EOF/p' "$INSTALL_SH" | sed 's/^    //')
[ -n "$AUTOSTART_HEREDOC" ] || fail "the spawn-at autostart entry was not found in install.sh"

# the IBus hotkey as install.sh left it (Super+. taken out), with the user's original saved
mkdir -p "$STATE_DIR"
printf '%s\n' "['<Super>period', '<Control><Shift>e']" > "$STATE_DIR/ibus-emoji-hotkey.orig"
gsettings set org.freedesktop.ibus.panel.emoji hotkey "['<Control><Shift>e']"
(
    cd "$REPO_ROOT"
    eval "$INSTALL_FUNCS"
    SUDO_USER=""; XDG_SESSION_TYPE=x11; WAYLAND_DISPLAY=""
    FIRSTRUN_SCRIPT="$STATE_DIR/firstrun.sh"
    mkdir -p "$SANDBOX/inst/scripts"; cp "$UNINSTALL_SH" "$SANDBOX/inst/scripts/uninstall.sh"
    (cd "$SANDBOX/inst" && install_uninstaller)
    install_gnome_extensions
    setup_post_login_enable
    autostart_dir="$HOME/.config/autostart"; sa_exec=spawn-at; mkdir -p "$autostart_dir" "$HOME/.local/bin"
    eval "$AUTOSTART_HEREDOC"
    echo x > "$autostart_dir/spawn-at-update-check.desktop"   # written by `spawn-at install`
    echo x > "$HOME/.local/bin/spawn-at"; echo x > "$SYSROOT/usr/local/bin/spawn-at"
    echo x > "$HOME/.config/autostart/io.github.harshp2008.win11clip.desktop"   # written by the app itself
    echo "log line" > "$STATE_DIR/firstrun.log"; echo 1 > "$STATE_DIR/firstrun.tries"
) > "$SANDBOX/install-funcs.log" 2>&1 || { fail "the install.sh functions failed in the sandbox"; cat "$SANDBOX/install-funcs.log" >&2; }

tree_files() { (cd "$SANDBOX" && find root home \( -type f -o -type l \) | sort); }
# Files that may stay: the user's data, the installer's backups, and the two shared components
# the uninstaller asks about (window-calls and spawn-at), which a run without a terminal keeps.
allowed_after_uninstall() {
    case "$1" in
        */installer-manifest) return 1 ;;   # the installer's own record, in either place
        home/.config/win11clip/*|home/.local/share/win11clip/*|home/.cache/win11clip/*) ;;
        home/.config/win11-clipboard-history/*|home/.local/share/win11-clipboard-history/*|home/.cache/win11-clipboard-history/*) ;;
        home/.local/state/win11clip-installer/backup/*) ;;
        home/.local/share/gnome-shell/extensions/window-calls@domandoman.xyz/*) ;;
        home/.local/bin/spawn-at|root/usr/local/bin/spawn-at) ;;
        home/.config/autostart/spawn-at-autoupdate.desktop|home/.config/autostart/spawn-at-update-check.desktop) ;;
        *) return 1 ;;
    esac
}
BEFORE=$(tree_files)
check_exists "the fake install put the uninstaller in place" "$SYSROOT/usr/local/bin/win11clip-uninstall"
check_exists "the fake install put the old-name link in place" "$SYSROOT/usr/local/bin/win11-clipboard-uninstall"
check_exists "the fake install put the metainfo under /usr/local/share" "$SYSROOT/usr/local/share/metainfo/io.github.harshp2008.win11clip.metainfo.xml"
check_exists "the fake install put the first-login script in place" "$STATE_DIR/firstrun.sh"
EXPECTED=$(printf '%s\n' "$BEFORE" | while IFS= read -r f; do if allowed_after_uninstall "$f"; then printf '%s\n' "$f"; fi; done)

: > "$SANDBOX/sudo.log"
set +e
UNINSTALL_OUT=$(setsid --wait env WIN11CLIP_SYSROOT="$SYSROOT" HOME="$HOME" bash "$SYSROOT/usr/local/bin/win11clip-uninstall" < /dev/null 2>&1)
UNINSTALL_RC=$?
set -e
check_eq "the installed uninstaller runs to the end" "$UNINSTALL_RC" "0"
AFTER=$(tree_files)
check_eq "exactly the allowed files remain (a line starting with > is a leftover, one with < is something that was deleted but should stay)" \
    "$(diff <(printf '%s\n' "$EXPECTED") <(printf '%s\n' "$AFTER") || true)" ""
check_missing "the uninstaller deleted itself" "$SYSROOT/usr/local/bin/win11clip-uninstall"
check_missing "and the old-name link to it" "$SYSROOT/usr/local/bin/win11-clipboard-uninstall"
if [ "$EUID" -ne 0 ]; then
    LAST_TWO=$(tail -n 2 "$SANDBOX/sudo.log")
    check_contains "the very last thing the script ran was deleting itself (1/2)" "$(printf '%s\n' "$LAST_TWO" | head -n 1)" "rm -f $SYSROOT/usr/local/bin/win11clip-uninstall"
    check_contains "the very last thing the script ran was deleting itself (2/2)" "$(printf '%s\n' "$LAST_TWO" | tail -n 1)" "rm -f $SYSROOT/usr/local/bin/win11-clipboard-uninstall"
fi
check_contains "the message says the uninstaller itself was removed" "$UNINSTALL_OUT" "this uninstaller (/usr/local/bin/win11clip-uninstall /usr/local/bin/win11-clipboard-uninstall), deleted as the very last step"
check_contains "the message tells the shell to forget the old path" "$UNINSTALL_OUT" "hash -r"
check_contains "the kept list names the backups folder" "$UNINSTALL_OUT" "$STATE_DIR/backup"
check_contains "the kept list says how to delete the backups" "$UNINSTALL_OUT" "delete: rm -rf ~/.local/state/win11clip-installer"
check_contains "the kept list names window-calls and how to delete it" "$UNINSTALL_OUT" "delete: rm -rf ~/.local/share/gnome-shell/extensions/window-calls@domandoman.xyz"
check_contains "the kept list names spawn-at and how to delete it" "$UNINSTALL_OUT" "~/.config/autostart/spawn-at-*.desktop"
check_contains "the kept list names the system copy of spawn-at" "$UNINSTALL_OUT" "sudo rm -f /usr/local/bin/spawn-at"
for d in .config/win11clip .local/share/win11clip .cache/win11clip; do
    check_contains "the kept list gives the command that deletes ~/$d" "$UNINSTALL_OUT" "delete: rm -rf ~/$d"
done
check_eq "the IBus emoji hotkey is back to the user's original" "$(gsettings get org.freedesktop.ibus.panel.emoji hotkey)" "['<Super>period', '<Control><Shift>e']"
check_missing "and its saved copy is gone" "$STATE_DIR/ibus-emoji-hotkey.orig"
check_missing "the fake sudo blocked nothing" "$SANDBOX/blocked.log"

# the same run without anything in the installer's state folder: the folder itself must not be left
reset_dirs "$HOME"; mkdir -p "$STATE_DIR" "$HOME/.config/win11-clipboard-history"
echo 'nvm-installed' > "$STATE_DIR/installer-manifest"; echo 'apt-build:x' > "$HOME/.config/win11-clipboard-history/installer-manifest"
set +e
setsid --wait env WIN11CLIP_SYSROOT="$SYSROOT" HOME="$HOME" bash "$UNINSTALL_SH" < /dev/null > /dev/null 2>&1
set -e
check_missing "an installer state folder with nothing left in it is removed" "$STATE_DIR"
check_missing "so is the old config folder that held only the installer's record" "$HOME/.config/win11-clipboard-history"

# ================================================================================================
printf '\n-- Test 11: the closing box is aligned, for the shortest and the longest text\n'
BOXFUNCS=$( { extract_function "$UNINSTALL_SH" box_edge; extract_function "$UNINSTALL_SH" box_row; } )
[ -n "$BOXFUNCS" ] || fail "box_edge / box_row not found in uninstall.sh"
box_widths() { # prints the set of visible widths of the lines of a box built from the given texts
    (
        eval "$BOXFUNCS"; BOX_WIDTH=62; BLUE=$'\033[0;34m'; NC=$'\033[0m'; GREEN=$'\033[0;32m'
        box_edge "┌" "┐"; local_t=("$@")
        for t in "${local_t[@]}"; do box_row "$GREEN" "$t"; done
        box_edge "└" "┘"
    ) | python3 -I -c '
import re, sys
print(sorted({len(re.sub(r"\x1b\[[0-9;]*m", "", l.rstrip("\n"))) for l in sys.stdin}))'
}
LONGEST="The app package may still be installed (kept or failed)."
check_eq "shortest text" "$(box_widths "a")" "[64]"
check_eq "empty text" "$(box_widths "")" "[64]"
check_eq "the longest message the script prints" "$(box_widths "$LONGEST")" "[64]"
check_eq "text with a multi-byte character (the check mark)" "$(box_widths "✓ Uninstallation Complete!" "Win11Clip has been removed.")" "[64]"
check_eq "a text exactly as wide as the box" "$(box_widths "$(printf 'x%.0s' $(seq 1 60))")" "[64]"
check_eq "a text wider than the box is not cut, and the other lines keep their width" "$(box_widths "short" "$(printf 'x%.0s' $(seq 1 90))")" "[64, 94]"
BOX_LINES=$(printf '%s\n' "$UNINSTALL_OUT" | sed 's/\x1b\[[0-9;]*m//g' | grep -E '^[┌│└]')
check_eq "the box in the real output is 64 columns wide on every line" \
    "$(printf '%s\n' "$BOX_LINES" | python3 -I -c 'import sys; print(sorted({len(l.rstrip("\n")) for l in sys.stdin}))')" "[64]"
check_contains "and it has the removed line" "$BOX_LINES" "Win11Clip has been removed."

# ================================================================================================
printf '\n-- Test 12: answering Yes to the prompts removes window-calls and spawn-at, and the uninstaller still goes last\n'
if command -v script >/dev/null 2>&1; then
    clear_pkgs; reset_dirs "$HOME" "$SYSROOT" "$FAKE_GSETTINGS_STATE"; seed_system
    mkdir -p "$HOME/.local/share/gnome-shell/extensions/window-calls@domandoman.xyz" "$HOME/.local/share/gnome-shell/extensions/spawn-at@harsh.local" "$HOME/.config/spawn-at"
    echo x > "$HOME/.local/share/gnome-shell/extensions/window-calls@domandoman.xyz/extension.js"
    echo x > "$HOME/.local/share/gnome-shell/extensions/spawn-at@harsh.local/extension.js"
    printf '#!/bin/sh\nexit 0\n' > "$HOME/.local/bin/spawn-at"; chmod +x "$HOME/.local/bin/spawn-at"
    echo x > "$SYSROOT/usr/local/bin/spawn-at"
    echo x > "$HOME/.config/autostart/spawn-at-autoupdate.desktop"; echo x > "$HOME/.config/autostart/spawn-at-update-check.desktop"
    # a pseudo-terminal gives the prompts a /dev/tty; the answers are typed with pauses because the menu
    # throws away keys typed before it is drawn. The run is bounded by timeout.
    set +e
    TTY_OUT=$( { sleep 1; printf 'y\n'; sleep 1; printf '2'; sleep 1; printf 'y\n'; sleep 2; } \
        | timeout 60 script -qec "env WIN11CLIP_SYSROOT='$SYSROOT' HOME='$HOME' bash '$UNINSTALL_SH'" /dev/null 2>&1 )
    set -e
    check_missing "window-calls was removed after a Yes" "$HOME/.local/share/gnome-shell/extensions/window-calls@domandoman.xyz"
    check_missing "the spawn-at extension was removed after choosing Remove and confirming" "$HOME/.local/share/gnome-shell/extensions/spawn-at@harsh.local"
    check_missing "the user's spawn-at was removed" "$HOME/.local/bin/spawn-at"
    check_missing "the system spawn-at was removed" "$SYSROOT/usr/local/bin/spawn-at"
    check_missing "the spawn-at login entries were removed" "$HOME/.config/autostart/spawn-at-autoupdate.desktop"
    check_missing "(both)" "$HOME/.config/autostart/spawn-at-update-check.desktop"
    check_contains "it lists them as removed" "$TTY_OUT" "spawn-at (binary, extension, login entries)"
    check_not_contains "nothing is listed as kept for them" "$TTY_OUT" "which other shortcuts may use"
    check_missing "the uninstaller still deleted itself" "$SYSROOT/usr/local/bin/win11clip-uninstall"
else
    printf 'SKIP: script(1) is not installed; the Yes-path of the prompts was not tested\n'
fi

# --- results ---------------------------------------------------------------------------------------
printf '\n== Results: %d passed, %d failed ==\n' "$PASS" "$FAIL"
[ -f "$SANDBOX/blocked.log" ] && { printf 'BLOCKED calls:\n'; cat "$SANDBOX/blocked.log"; FAIL=$((FAIL + 1)); }
if [ "$FAIL" -ne 0 ]; then exit 1; fi
printf 'All rename shell tests passed.\n'
