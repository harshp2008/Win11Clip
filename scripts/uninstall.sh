#!/bin/bash
# uninstall.sh - Win11 Clipboard History Uninstaller
# Usage: curl -fsSL https://raw.githubusercontent.com/harshp2008/Win11Clip/master/scripts/uninstall.sh | bash

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
C_BOLD='\033[1m'
C_DIM='\033[2m'
C_RESET='\033[0m'
C_CYAN='\033[0;36m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'

log()     { echo -e "${BLUE}[*]${NC} $1"; }
success() { echo -e "${GREEN}[✓]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[✗]${NC} $1"; exit 1; }

SUDO_CMD=""
if [ "$EUID" -ne 0 ]; then
    SUDO_CMD="sudo"
fi

# Things install.sh recorded as added by itself (build tools). Anything not listed predates
# the install and is never removed here.
MANIFEST="$HOME/.config/win11-clipboard-history/installer-manifest"

# Where install.sh saved the user's original IBus emoji hotkey (it changes it for Super+.).
STATE_DIR="$HOME/.local/state/win11clip-installer"
IBUS_EMOJI_SCHEMA="org.freedesktop.ibus.panel.emoji"
IBUS_EMOJI_HOTKEY_SAVED="$STATE_DIR/ibus-emoji-hotkey.orig"

# ask_yes_no "question" -> 0 only on an explicit yes; defaults to No, and No when non-interactive.
ask_yes_no() {
    local reply=""
    if ( : < /dev/tty ) 2>/dev/null; then
        read -r -p "$1 [y/N] " reply < /dev/tty || true
    fi
    [[ "$reply" =~ ^[Yy] ]]
}

# Run gsettings as the desktop user: under sudo it is the user owning the session, not root.
# The sudo hop is only needed when this script itself runs as root; when it already runs as the
# user (e.g. `sudo -u "$SUDO_USER" bash uninstall.sh`, which can still carry SUDO_USER in the
# environment) calling sudo again would be a pointless and failure-prone round trip.
run_user_gsettings() {
    if [ "$EUID" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
        sudo -u "$SUDO_USER" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u "$SUDO_USER")/bus" gsettings "$@"
    else
        gsettings "$@"
    fi
}

# Put back the IBus emoji hotkey install.sh removed so Super+. could open Win11Clip's emoji
# picker. Does nothing when this installer never changed it; on failure the saved value is kept.
restore_ibus_emoji_hotkey() {
    [ -f "$IBUS_EMOJI_HOTKEY_SAVED" ] || return 0

    local saved
    saved=$(cat "$IBUS_EMOJI_HOTKEY_SAVED" 2>/dev/null) || saved=""
    if [ -z "$saved" ]; then
        warn "The saved IBus emoji hotkey is empty; leaving the setting alone."
        return 0
    fi
    if ! command -v gsettings &>/dev/null; then
        warn "gsettings was not found, so the IBus emoji hotkey was not restored. Saved value kept in $IBUS_EMOJI_HOTKEY_SAVED."
        return 0
    fi

    if run_user_gsettings set "$IBUS_EMOJI_SCHEMA" hotkey "$saved" 2>/dev/null; then
        rm -f "$IBUS_EMOJI_HOTKEY_SAVED" 2>/dev/null || true
        success "Restored the IBus emoji hotkey (Super+.)."
    else
        warn "Could not restore the IBus emoji hotkey. Saved value kept in $IBUS_EMOJI_HOTKEY_SAVED."
    fi
    return 0
}

# Used by `make uninstall`: restore the saved IBus emoji hotkey and exit before any other
# uninstall step (no prompts, no file removal, no package changes). The normal uninstall path
# below still calls restore_ibus_emoji_hotkey() at its usual place, unchanged.
RESTORE_HOTKEY_ONLY=false
for arg in "$@"; do
    case "$arg" in
        --restore-ibus-hotkey-only) RESTORE_HOTKEY_ONLY=true ;;
    esac
done
if [ "$RESTORE_HOTKEY_ONLY" = true ]; then
    # `sudo make uninstall` runs this as root with HOME=/root; the saved state and the gsettings
    # database belong to the user who called sudo, so resolve that user's home directory.
    if [ "$EUID" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
        SUDO_HOME=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6 || true)
        if [ -n "$SUDO_HOME" ]; then
            HOME="$SUDO_HOME"
            STATE_DIR="$HOME/.local/state/win11clip-installer"
            IBUS_EMOJI_HOTKEY_SAVED="$STATE_DIR/ibus-emoji-hotkey.orig"
        fi
    fi
    restore_ibus_emoji_hotkey
    exit 0
fi

# What this run removed and what it left alone, printed at the end.
SUMMARY_REMOVED=()
SUMMARY_KEPT=()

echo ""
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║     Win11 Clipboard History - Uninstaller                 ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""

# Process ids of the running app: a process whose executable (or, for the wrapper script, whose script)
# is named exactly win11-clipboard-history, win11-clipboard-history-bin or win11-clipboard-history.AppImage.
# `pkill -f` is not used: it matches any command line that merely contains the text (an editor open on
# a file with that name, a shell, this script's caller). `pkill -x` with the full name is not possible
# either: the kernel keeps only 15 characters of a process name, so procps refuses longer names and
# matches nothing. So take the processes named "win11-clipboard" (the first 15 characters) and keep
# those whose executable name is exactly ours.
app_pids() {
    local pid exe name
    for pid in $(pgrep -x win11-clipboard 2>/dev/null || true); do
        exe=$(readlink "/proc/$pid/exe" 2>/dev/null) || continue
        exe="${exe% (deleted)}"
        name="${exe##*/}"
        case "$name" in
            bash|sh|dash)   # the wrapper script: the script's name is the first argument that is not an option
                name=$(tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null | awk 'NR>1 && $0 !~ /^-/ {print; exit}')
                name="${name##*/}" ;;
        esac
        case "$name" in
            win11-clipboard-history|win11-clipboard-history-bin|win11-clipboard-history.AppImage) echo "$pid" ;;
        esac
    done
}

# 1. Terminate running instances
log "Terminating running instances..."
APP_PIDS=$(app_pids)
if [ -n "$APP_PIDS" ]; then
    # shellcheck disable=SC2086  # one pid per word
    kill $APP_PIDS 2>/dev/null || true
    success "Stopped the running app (pid $(echo $APP_PIDS))."
else
    success "The app is not running."
fi

# 2. Clean Custom Extension
log "Removing win11-clipboard-bridge extension..."
BRIDGE_UUID="win11-clipboard-bridge@harshp2008.github.com"
if command -v gnome-extensions &>/dev/null; then
    gnome-extensions disable "$BRIDGE_UUID" 2>/dev/null || true
fi
rm -rf "$HOME/.local/share/gnome-shell/extensions/$BRIDGE_UUID"
$SUDO_CMD rm -rf "/usr/share/gnome-shell/extensions/$BRIDGE_UUID" 2>/dev/null || true
success "win11-clipboard-bridge removed."

# 2b. Things install.sh removed with your consent (see its backups), and old upstream sources
BACKUP_DIR="$HOME/.local/state/win11clip-installer/backup"
REMOVED_SOURCES=()
REMOVED_PACKAGE=""
RESTORED_SOURCES=false
if [ -f "$MANIFEST" ]; then
    while IFS= read -r line; do REMOVED_SOURCES+=("${line#removed-source:}"); done < <(grep '^removed-source:' "$MANIFEST")
    REMOVED_PACKAGE=$(sed -n 's/^removed-package://p' "$MANIFEST" | head -n 1)
fi

if [ ${#REMOVED_SOURCES[@]} -gt 0 ]; then
    echo ""
    echo "install.sh removed this upstream package source from your system (a copy was saved):"
    printf '      %s\n' "${REMOVED_SOURCES[@]}"
    if ask_yes_no "Restore it? It makes apt offer gustavosett's upstream build again."; then
        for f in "${REMOVED_SOURCES[@]}"; do
            if [ -f "$BACKUP_DIR/apt-source$f" ]; then
                $SUDO_CMD install -Dm644 "$BACKUP_DIR/apt-source$f" "$f" || warn "Could not restore $f (copy kept at $BACKUP_DIR/apt-source$f)."
            else
                warn "No backup found for $f."
            fi
        done
        command -v apt-get &>/dev/null && { $SUDO_CMD apt-get update -qq 2>/dev/null || true; }
        RESTORED_SOURCES=true
        success "Restored the upstream package source."
    else
        success "Left it removed. The saved copy stays in $BACKUP_DIR/apt-source."
    fi
fi

if [ -n "$REMOVED_PACKAGE" ]; then
    echo ""
    warn "install.sh removed the apt package ${REMOVED_PACKAGE%%=*} ${REMOVED_PACKAGE#*=} so that its source build would run."
    echo "    It is not reinstalled automatically. A copy of its files is in $BACKUP_DIR/package."
    echo "    To get that version back (needs the upstream source above): sudo apt install ${REMOVED_PACKAGE}"
fi

# Any other leftover upstream source (older installers added it without recording it).
LEGACY_SOURCES=()
for f in /etc/apt/sources.list.d/gustavosett-clipboard-manager.list \
         /usr/share/keyrings/gustavosett-clipboard-manager-archive-keyring.gpg \
         /etc/yum.repos.d/gustavosett-clipboard-manager*.repo \
         /etc/zypp/repos.d/gustavosett-clipboard-manager*.repo; do
    [ -f "$f" ] && LEGACY_SOURCES+=("$f")
done
if [ "$RESTORED_SOURCES" != true ] && [ ${#LEGACY_SOURCES[@]} -gt 0 ]; then
    echo ""
    echo "An old upstream package source (added by an older installer) is still on this system:"
    printf '      %s\n' "${LEGACY_SOURCES[@]}"
    if ask_yes_no "Remove it? Choose No if you use gustavosett's upstream package on purpose."; then
        $SUDO_CMD rm -f "${LEGACY_SOURCES[@]}" || warn "Could not remove them; run: sudo rm -f ${LEGACY_SOURCES[*]}"
        command -v apt-get &>/dev/null && { $SUDO_CMD apt-get update -qq 2>/dev/null || true; }
        success "Old upstream package source removed."
    else
        success "Kept the old upstream package source."
    fi
fi

# 2c. window-calls (patched copy installed by install.sh; other GNOME tools may rely on it)
WC_UUID="window-calls@domandoman.xyz"
WC_LOCAL="$HOME/.local/share/gnome-shell/extensions/$WC_UUID"
# Copies of a window-calls that was already installed before install.sh replaced it (oldest first;
# the oldest is the one you had originally).
# Found in the backup folder itself (not the manifest, which this script deletes), so it also
# works on a later run.
WC_BACKUPS=()
for d in "$BACKUP_DIR"/window-calls/*/; do
    [ -d "$d" ] && WC_BACKUPS+=("${d%/}")
done
if [ -d "$WC_LOCAL" ]; then
    echo ""
    echo "window-calls is a shared GNOME extension that install.sh deployed (patched build)."
    [ ${#WC_BACKUPS[@]} -gt 0 ] && echo "    install.sh replaced a window-calls you already had; it saved your copy in ${WC_BACKUPS[0]}"
    if ask_yes_no "Remove window-calls too? Choose No if other tools use it."; then
        command -v gnome-extensions &>/dev/null && { gnome-extensions disable "$WC_UUID" 2>/dev/null || true; }
        rm -rf "$WC_LOCAL"
        if [ ${#WC_BACKUPS[@]} -gt 0 ]; then
            mkdir -p "$WC_LOCAL" && cp -a "${WC_BACKUPS[0]}/." "$WC_LOCAL/" \
                && { success "window-calls removed and your previous copy restored from ${WC_BACKUPS[0]}."; SUMMARY_REMOVED+=("window-calls (patched copy; your previous one was restored)"); } \
                || { warn "Removed the patched window-calls but could not restore your copy; it is still in ${WC_BACKUPS[0]}."; SUMMARY_REMOVED+=("window-calls (restore failed, copy kept in ${WC_BACKUPS[0]})"); }
        else
            success "window-calls removed."
            SUMMARY_REMOVED+=("window-calls")
        fi
    else
        success "Kept window-calls."
        SUMMARY_KEPT+=("window-calls")
        [ ${#WC_BACKUPS[@]} -gt 0 ] && echo "    Your earlier copy stays saved in ${WC_BACKUPS[0]} (it was replaced by the patched build)."
    fi
fi

# 3. Prompt for spawn-at removal
# The copy install.sh manages lives in ~/.local/bin. /usr/local/bin/spawn-at is only there on
# machines that an earlier installer (or `make install`) put it on. Nothing else is ours: a
# spawn-at in /usr/bin or elsewhere on the PATH belongs to a package or to you and is never touched.
SPAWN_AT_USER_BIN="$HOME/.local/bin/spawn-at"
SPAWN_AT_SYSTEM_BIN="/usr/local/bin/spawn-at"
SPAWN_AT_BIN=""
if [ -x "$SPAWN_AT_USER_BIN" ]; then
    SPAWN_AT_BIN="$SPAWN_AT_USER_BIN"
elif [ -x "$SPAWN_AT_SYSTEM_BIN" ]; then
    SPAWN_AT_BIN="$SPAWN_AT_SYSTEM_BIN"
fi

SPAWN_AT_UUID="spawn-at@harsh.local"
SPAWN_AT_LOCAL_EXT="$HOME/.local/share/gnome-shell/extensions/$SPAWN_AT_UUID"
SPAWN_AT_SYS_EXT="/usr/share/gnome-shell/extensions/$SPAWN_AT_UUID"

if [ -e "$SPAWN_AT_USER_BIN" ] || [ -e "$SPAWN_AT_SYSTEM_BIN" ] || [ -d "$SPAWN_AT_LOCAL_EXT" ] || [ -d "$SPAWN_AT_SYS_EXT" ]; then
    echo ""
    echo -e "${C_CYAN}┌──────────────────────────────────────────────────────────────┐${C_RESET}"
    echo -e "${C_CYAN}│${C_RESET}  ${C_BOLD}Component: spawn-at${C_RESET}                                         ${C_CYAN}│${C_RESET}"
    echo -e "${C_CYAN}│${C_RESET}  This tool may be used by other applications or shortcuts.   ${C_CYAN}│${C_RESET}"
    echo -e "${C_CYAN}└──────────────────────────────────────────────────────────────┘${C_RESET}"
    echo ""

    prompt_spawn_at_removal() {
        local options=(
            "Keep spawn-at (Recommended if used by other tools)"
            "Remove spawn-at"
        )
        local selected=0
        local count=${#options[@]}

        # Ensure input is read from /dev/tty if stdin is piped (e.g. curl | bash)
        local tty_in=""
        if ( : < /dev/tty ) 2>/dev/null; then
            exec 3</dev/tty
            tty_in=3
        elif [ ! -t 0 ]; then
            echo -e "${C_YELLOW}[!] Non-interactive session. Keeping spawn-at.${C_RESET}"
            return 0
        fi

        # Hide cursor
        echo -ne "\033[?25l"
        trap 'echo -ne "\033[?25h"' EXIT INT TERM

        # Throw away keys typed during the earlier prompts (an arrow key would otherwise move the
        # cursor off "Keep" before the menu is even drawn).
        while IFS= read -u "${tty_in:-0}" -rsn1 -t 0.05 _; do :; done

        print_menu() {
            for i in "${!options[@]}"; do
                # Clear line first
                echo -ne "\033[2K\r"
                if [ "$i" -eq "$selected" ]; then
                    if [ "$i" -eq 1 ]; then
                        # Destructive option in bold red
                        echo -e "\033[1;31m  ❯ ${options[$i]}\033[0m"
                    else
                        echo -e "\033[1;36m  ❯ ${options[$i]}\033[0m"
                    fi
                else
                    echo -e "\033[2m    ${options[$i]}\033[0m"
                fi
            done
        }

        print_menu

        while true; do
            local key=""
            IFS= read -u "${tty_in:-0}" -rsn1 key || true
            if [[ $key == $'\x1b' ]]; then
                read -u "${tty_in:-0}" -rsn2 -t 0.1 key 2>/dev/null || true
                case "$key" in
                    "[A"|"[D"|"OA") # Up / Left
                        selected=$(( (selected - 1 + count) % count ))
                        ;;
                    "[B"|"[C"|"OB") # Down / Right
                        selected=$(( (selected + 1) % count ))
                        ;;
                esac
            elif [[ $key == "" ]]; then # Enter
                break
            elif [[ $key == "1" ]]; then
                selected=0; break
            elif [[ $key == "2" ]]; then
                selected=1; break
            fi

            # Move cursor back up to the top of the menu before redrawing
            echo -ne "\033[${count}A"
            print_menu
        done

        [ -n "$tty_in" ] && exec 3<&-

        # Restore cursor
        echo -ne "\033[?25h"
        return "$selected"
    }

    selected=0
    prompt_spawn_at_removal || selected=$?
    echo ""

    if [ "$selected" -eq 1 ] && ! ask_yes_no "Really remove spawn-at? Other shortcuts that use it will stop working."; then
        selected=0
    fi

    if [ "$selected" -eq 1 ]; then
        log "Removing spawn-at..."
        if [ -n "$SPAWN_AT_BIN" ] && [ -x "$SPAWN_AT_BIN" ]; then
            "$SPAWN_AT_BIN" uninstall --headless --gnome-delete-files true 2>/dev/null || true
        fi

        if command -v gnome-extensions &>/dev/null; then
            gnome-extensions disable "$SPAWN_AT_UUID" 2>/dev/null || true
        fi
        rm -rf "$SPAWN_AT_LOCAL_EXT"
        $SUDO_CMD rm -rf "$SPAWN_AT_SYS_EXT" 2>/dev/null || true
        rm -f "$SPAWN_AT_USER_BIN"
        if [ -e "$SPAWN_AT_SYSTEM_BIN" ] || [ -L "$SPAWN_AT_SYSTEM_BIN" ]; then
            $SUDO_CMD rm -f "$SPAWN_AT_SYSTEM_BIN" 2>/dev/null || true
            if [ -e "$SPAWN_AT_SYSTEM_BIN" ] || [ -L "$SPAWN_AT_SYSTEM_BIN" ]; then
                warn "Could not remove $SPAWN_AT_SYSTEM_BIN (needs sudo). Run: sudo rm $SPAWN_AT_SYSTEM_BIN"
            fi
        fi
        rm -rf "$HOME/.config/spawn-at"
        rm -f "$HOME/.config/autostart/spawn-at-autoupdate.desktop"
        rm -f "$HOME/.config/autostart/spawn-at-update-check.desktop"
        success "spawn-at removed."
        SUMMARY_REMOVED+=("spawn-at (binary, extension, login entries)")
    else
        success "Kept spawn-at."
        SUMMARY_KEPT+=("spawn-at")
    fi
fi

# 4. Clean GNOME Custom Shortcuts
log "Cleaning GNOME custom shortcuts..."
if command -v gsettings &>/dev/null && command -v python3 &>/dev/null && gsettings list-schemas 2>/dev/null | grep -q "org.gnome.settings-daemon.plugins.media-keys"; then
    python3 -c '
import subprocess, ast

schema = "org.gnome.settings-daemon.plugins.media-keys"
key = "custom-keybindings"

# Explicitly purge known static named paths
for named_path in [
    "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/win11-clipboard-history/",
    "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/win11-clipboard-history-emoji/",
    "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/win11-clipboard-history-alt/",
]:
    subprocess.run(["gsettings", "reset-recursively", f"{schema}.custom-keybinding:{named_path}"], check=False)

try:
    raw = subprocess.check_output(["gsettings", "get", schema, key], text=True).strip()
    bindings = ast.literal_eval(raw) if raw and raw != "@as []" else []
    keep = []
    for path in bindings:
        if any(token in path for token in ["win11-clipboard-history", "win11clip"]):
            base_schema = f"{schema}.custom-keybinding:{path}"
            subprocess.run(["gsettings", "reset-recursively", base_schema], check=False)
            continue
        
        # Check properties for customN paths
        base_schema = f"{schema}.custom-keybinding:{path}"
        try:
            cmd = subprocess.check_output(["gsettings", "get", base_schema, "command"], text=True).strip().strip("\x27\"")
            name = subprocess.check_output(["gsettings", "get", base_schema, "name"], text=True).strip().strip("\x27\"")
            # Old-form commands (no -c, or the upstream class) and the current one (-c io.github.harshp2008.win11clip)
            # all run win11-clipboard-history through spawn-at, so these tokens match every form.
            if any(k in cmd for k in ["win11-clipboard-history", "io.github.harshp2008.win11clip", "dev.gustavosett.clipboard-history", "spawn-at"]) or "Clipboard History" in name:
                subprocess.run(["gsettings", "reset-recursively", base_schema], check=False)
            else:
                keep.append(path)
        except Exception:
            keep.append(path)
            
    subprocess.run(["gsettings", "set", schema, key, str(keep)], check=False)
except Exception as e:
    print(f"Error cleaning keybindings: {e}")
'
    success "Cleared app shortcuts from GNOME."
else
    success "Skipped GNOME shortcuts (not on GNOME or gsettings/python3 missing)."
fi

# install.sh took '<Super>period' out of the IBus emoji hotkey so it would stop clashing with
# Win11Clip's emoji picker; give the user their original value back before the state dir is cleaned.
restore_ibus_emoji_hotkey

# 4b. Build tools the installer added for --build (only what the manifest lists)
if [ -f "$MANIFEST" ]; then
    BUILD_PKGS=$(sed -n 's/^apt-build://p' "$MANIFEST" | tr '\n' ' ')
    if [ -n "${BUILD_PKGS// /}" ]; then
        echo ""
        echo "install.sh installed these build packages (they were not on your system before):"
        echo "  $BUILD_PKGS"
        if ask_yes_no "Remove them with apt? apt will show what else it would remove and ask first."; then
            # Not -y on purpose: apt lists dependents and asks, so nothing you rely on goes silently.
            $SUDO_CMD apt-get remove $BUILD_PKGS < /dev/tty || warn "Skipped. Remove them later with: sudo apt remove $BUILD_PKGS"
        else
            success "Kept the build packages. To remove them later: sudo apt remove $BUILD_PKGS"
        fi
    fi
    if grep -qx "nvm-installed" "$MANIFEST" && [ -d "$HOME/.nvm" ]; then
        if ask_yes_no "Remove ~/.nvm (Node.js installed by install.sh)?"; then rm -rf "$HOME/.nvm"; success "Removed ~/.nvm."; else success "Kept ~/.nvm (remove later with: rm -rf ~/.nvm)"; fi
    fi
    if grep -qx "rustup-installed" "$MANIFEST" && [ -d "$HOME/.rustup" ]; then
        if ask_yes_no "Remove ~/.rustup and ~/.cargo (Rust installed by install.sh)?"; then rm -rf "$HOME/.rustup" "$HOME/.cargo"; success "Removed ~/.rustup and ~/.cargo."; else success "Kept ~/.rustup and ~/.cargo (remove later with: rm -rf ~/.rustup ~/.cargo)"; fi
    fi
fi

# 5. Clean Binaries, Config, and Package
log "Cleaning configuration, packages, and binaries..."

# The app can be installed as a system package (apt / dnf / pacman). Removing it deletes the app
# itself, so it is asked first: default No, and No when there is no terminal.
PKG_MANAGER=""; PKG_VERSION=""
if command -v apt-get &>/dev/null && dpkg -s win11-clipboard-history >/dev/null 2>&1; then
    PKG_MANAGER="apt"; PKG_VERSION=$(dpkg-query -W -f='${Version}' win11-clipboard-history 2>/dev/null)
elif command -v dnf &>/dev/null && rpm -q win11-clipboard-history >/dev/null 2>&1; then
    PKG_MANAGER="dnf"; PKG_VERSION=$(rpm -q --qf '%{VERSION}' win11-clipboard-history 2>/dev/null)
elif command -v pacman &>/dev/null && pacman -Qi win11-clipboard-history &>/dev/null; then
    PKG_MANAGER="pacman"; PKG_VERSION=$(pacman -Q win11-clipboard-history 2>/dev/null | awk '{print $2}')
fi
PACKAGE_KEPT=false
if [ -n "$PKG_MANAGER" ]; then
    echo ""
    echo "The Win11Clip app is installed as a system package: win11-clipboard-history $PKG_VERSION ($PKG_MANAGER)."
    echo "    Removing it deletes the app from /usr. Your clipboard history (~/.local/share) is not touched."
    if ask_yes_no "Remove the package win11-clipboard-history?"; then
        case "$PKG_MANAGER" in
            apt)    PKG_REMOVE=(apt-get remove -y win11-clipboard-history) ;;
            dnf)    PKG_REMOVE=(dnf remove -y win11-clipboard-history) ;;
            pacman) PKG_REMOVE=(pacman -Rns --noconfirm win11-clipboard-history) ;;
        esac
        if $SUDO_CMD "${PKG_REMOVE[@]}"; then
            success "Removed the package win11-clipboard-history $PKG_VERSION."
            SUMMARY_REMOVED+=("package win11-clipboard-history $PKG_VERSION")
        else
            warn "Could not remove the package. Run it yourself: sudo ${PKG_REMOVE[*]}"
            PACKAGE_KEPT=true
            SUMMARY_KEPT+=("package win11-clipboard-history $PKG_VERSION (removal failed)")
        fi
    else
        PACKAGE_KEPT=true
        success "Kept the package. Remove it later with: sudo ${PKG_MANAGER/apt/apt-get} remove win11-clipboard-history"
        SUMMARY_KEPT+=("package win11-clipboard-history $PKG_VERSION (app files in /usr)")
    fi
fi

# True for a file that belongs to the package we just decided to keep: those are left alone.
owned_by_kept_package() {
    [ "$PACKAGE_KEPT" = true ] || return 1
    case "$PKG_MANAGER" in
        apt) dpkg -S "$1" 2>/dev/null | grep -q '^win11-clipboard-history' ;;
        *) case "$1" in /usr/local/*) return 1 ;; *) return 0 ;; esac ;;
    esac
}

# AppImage and user-local files
rm -f "$HOME/.local/bin/win11-clipboard-history.AppImage"
rm -f "$HOME/.local/bin/win11-clipboard-history"
rm -f "$HOME/.local/share/applications/win11-clipboard-history.desktop"
rm -f "$HOME/.config/autostart/win11clip-firstrun.desktop"
rm -f "$HOME/.local/state/win11clip-installer/firstrun.sh" "$HOME/.local/state/win11clip-installer/firstrun.log" "$HOME/.local/state/win11clip-installer/firstrun.tries"
rm -f "$HOME/.config/autostart/win11-clipboard-history.desktop"
rm -rf "$HOME/.config/win11-clipboard-history"

# System binaries, desktop files, and utilities
for target in \
    "/usr/bin/win11-clipboard-history" \
    "/usr/bin/win11-clipboard-history-bin" \
    "/usr/local/bin/win11-clipboard-history" \
    "/usr/local/bin/win11-clipboard-history-bin" \
    "/usr/local/bin/win11-clipboard-uninstall" \
    "/usr/share/applications/win11-clipboard-history.desktop" \
    "/usr/local/share/applications/win11-clipboard-history.desktop" \
    "/usr/local/share/icons/hicolor/128x128/apps/win11-clipboard-history.png" \
    "/usr/local/share/icons/hicolor/256x256/apps/win11-clipboard-history.png" \
    "/etc/udev/rules.d/99-win11-clipboard-input.rules" \
    "/etc/modules-load.d/win11-clipboard.conf"; do
    if [ -e "$target" ] || [ -L "$target" ]; then
        if owned_by_kept_package "$target"; then continue; fi
        $SUDO_CMD rm -f "$target"
        if [ -e "$target" ] || [ -L "$target" ]; then
            error "Failed to remove system file: $target"
        fi
    fi
done

# Where `make install` (the --build path) puts the app binary
$SUDO_CMD rm -rf "/usr/local/lib/win11-clipboard-history"

success "Configuration and binaries removed."
if [ -d "$BACKUP_DIR" ]; then
    echo "    Backups of what install.sh removed are kept in $BACKUP_DIR"
    echo "    (delete them when you no longer need them: rm -rf ~/.local/state/win11clip-installer)"
fi

# What was removed and what was left alone
echo ""
if [ ${#SUMMARY_REMOVED[@]} -gt 0 ]; then
    echo "Removed:"; printf '  - %s\n' "${SUMMARY_REMOVED[@]}"
fi
if [ ${#SUMMARY_KEPT[@]} -gt 0 ]; then
    echo "Kept (you chose to, or it could not be removed):"; printf '  - %s\n' "${SUMMARY_KEPT[@]}"
fi

# Display completion message
echo -e "\n${BLUE}┌──────────────────────────────────────────────────────────────┐${NC}"
if [ "$PACKAGE_KEPT" = true ]; then
echo -e "${BLUE}│${NC}  ${YELLOW}! Partly uninstalled.${NC}                                       ${BLUE}│${NC}"
echo -e "${BLUE}│${NC}  The app package may still be installed (kept or failed).    ${BLUE}│${NC}"
else
echo -e "${BLUE}│${NC}  ${GREEN}✓ Uninstallation Complete!${NC}                                  ${BLUE}│${NC}"
echo -e "${BLUE}│${NC}  Win11 Clipboard History has been removed.                   ${BLUE}│${NC}"
fi
echo -e "${BLUE}└──────────────────────────────────────────────────────────────┘${NC}\n"
