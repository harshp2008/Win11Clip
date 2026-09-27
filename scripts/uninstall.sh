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

echo ""
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║     Win11 Clipboard History - Uninstaller                 ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""

# 1. Terminate running instances
log "Terminating running instances..."
pkill -f win11-clipboard-history 2>/dev/null || true
pkill -f win11-clipboard-history.AppImage 2>/dev/null || true
success "Processes terminated."

# 2. Clean Custom Extension
log "Removing win11-clipboard-bridge extension..."
BRIDGE_UUID="win11-clipboard-bridge@harshp2008.github.com"
if command -v gnome-extensions &>/dev/null; then
    gnome-extensions disable "$BRIDGE_UUID" 2>/dev/null || true
fi
rm -rf "$HOME/.local/share/gnome-shell/extensions/$BRIDGE_UUID"
$SUDO_CMD rm -rf "/usr/share/gnome-shell/extensions/$BRIDGE_UUID" 2>/dev/null || true
success "win11-clipboard-bridge removed."

# 3. Prompt for window-calls
WC_UUID="window-calls@domandoman.xyz"
WC_LOCAL="$HOME/.local/share/gnome-shell/extensions/$WC_UUID"
WC_SYS="/usr/share/gnome-shell/extensions/$WC_UUID"

if [ -d "$WC_LOCAL" ] || [ -d "$WC_SYS" ]; then
    echo ""
    echo -e "${C_CYAN}┌──────────────────────────────────────────────────────────────┐${C_RESET}"
    echo -e "${C_CYAN}│${C_RESET}  ${C_BOLD}Component: window-calls extension${C_RESET}                           ${C_CYAN}│${C_RESET}"
    echo -e "${C_CYAN}│${C_RESET}  This extension may be used by other GNOME tools.            ${C_CYAN}│${C_RESET}"
    echo -e "${C_CYAN}└──────────────────────────────────────────────────────────────┘${C_RESET}"
    echo ""

    prompt_window_calls_removal() {
        local options=(
            "Keep window-calls (Recommended if used by other tools)"
            "Remove window-calls"
        )
        local selected=0
        local count=${#options[@]}

        # Ensure input is read from /dev/tty if stdin is piped (e.g. curl | bash)
        local tty_in=""
        if [ -r /dev/tty ]; then
            exec 3</dev/tty
            tty_in=3
        elif [ ! -t 0 ]; then
            echo -e "${C_YELLOW}[!] Non-interactive session. Keeping window-calls.${C_RESET}"
            return 0
        fi

        # Hide cursor
        echo -ne "\033[?25l"
        trap 'echo -ne "\033[?25h"' EXIT INT TERM

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
    prompt_window_calls_removal || selected=$?
    echo ""

    if [ "$selected" -eq 1 ]; then
        log "Removing window-calls..."
        if command -v gnome-extensions &>/dev/null; then
            gnome-extensions disable "$WC_UUID" 2>/dev/null || true
        fi
        rm -rf "$WC_LOCAL"
        $SUDO_CMD rm -rf "$WC_SYS" 2>/dev/null || true
        success "window-calls removed."
    else
        success "Kept window-calls extension."
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
            if any(k in cmd for k in ["win11-clipboard-history", "spawn-at"]) or "Clipboard History" in name:
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

# 5. Clean Binaries, Config, and Package
log "Cleaning configuration, packages, and binaries..."
# Package manager (APT / RPM / Pacman / AppImage)
if command -v apt-get &>/dev/null && dpkg -l | grep -q win11-clipboard-history 2>/dev/null; then
    $SUDO_CMD apt-get remove -y win11-clipboard-history 2>/dev/null || true
elif command -v dnf &>/dev/null && rpm -qa | grep -q win11-clipboard-history 2>/dev/null; then
    $SUDO_CMD dnf remove -y win11-clipboard-history 2>/dev/null || true
elif command -v pacman &>/dev/null && pacman -Qs win11-clipboard-history &>/dev/null; then
    $SUDO_CMD pacman -Rns --noconfirm win11-clipboard-history 2>/dev/null || true
fi

# AppImage and user-local files
rm -f "$HOME/.local/bin/win11-clipboard-history.AppImage"
rm -f "$HOME/.local/bin/win11-clipboard-history"
rm -f "$HOME/.local/bin/spawn-at"
rm -f "$HOME/.local/share/applications/win11-clipboard-history.desktop"
rm -f "$HOME/.config/autostart/win11clip-firstrun.desktop"
rm -f "$HOME/.config/autostart/win11-clipboard-history.desktop"
rm -rf "$HOME/.config/win11-clipboard-history"

# System binaries, desktop files, and utilities
for target in \
    "/usr/bin/win11-clipboard-history" \
    "/usr/bin/win11-clipboard-history-bin" \
    "/usr/local/bin/win11-clipboard-history" \
    "/usr/local/bin/win11-clipboard-history-bin" \
    "/usr/local/bin/spawn-at" \
    "/usr/local/bin/win11-clipboard-uninstall" \
    "/usr/share/applications/win11-clipboard-history.desktop" \
    "/usr/local/share/applications/win11-clipboard-history.desktop"; do
    if [ -e "$target" ] || [ -L "$target" ]; then
        $SUDO_CMD rm -f "$target"
        if [ -e "$target" ] || [ -L "$target" ]; then
            error "Failed to remove system file: $target"
        fi
    fi
done

success "Configuration and binaries removed."

# Display completion message
echo -e "\n${BLUE}┌──────────────────────────────────────────────────────────────┐${NC}"
echo -e "${BLUE}│${NC}  ${GREEN}✓ Uninstallation Complete!${NC}                                  ${BLUE}│${NC}"
echo -e "${BLUE}│${NC}  Win11 Clipboard History has been removed.                   ${BLUE}│${NC}"
echo -e "${BLUE}└──────────────────────────────────────────────────────────────┘${NC}\n"
