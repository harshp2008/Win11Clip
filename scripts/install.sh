#!/bin/bash
# install.sh - Smart installer for Win11 Clipboard History
# Usage: curl -fsSL https://raw.githubusercontent.com/harshp2008/Win11Clip/master/scripts/install.sh | bash

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

# Configuration
REPO_OWNER="${REPO_OWNER:-harshp2008}"
REPO_NAME="${REPO_NAME:-Win11Clip}"
# Pin the installer to this repository's own releases: "latest" unless WIN11CLIP_TAG is set.
RELEASE_TAG_PIN="${WIN11CLIP_TAG:-}"
# Oldest release that contains the focus / always-on-top / rounded-corner fixes. Anything
# older (or no release at all) makes the installer build from source instead.
MIN_RELEASE_VERSION="0.7.3"
MIN_NODE_MAJOR=20
MIN_RUST_VERSION="1.85"
NVM_VERSION="v0.40.3"

# What this installer added on top of the user's system, so uninstall.sh only removes ours.
MANIFEST_DIR="$HOME/.config/win11-clipboard-history"
MANIFEST="$MANIFEST_DIR/installer-manifest"
# Copies of anything this installer removes with your consent, so uninstall.sh can restore or report it.
# Not under ~/.config/win11-clipboard-history: uninstall.sh wipes that folder.
BACKUP_DIR="$HOME/.local/state/win11clip-installer/backup"
# The one-time first-login check (see setup_post_login_enable) and its log live here too.
FIRSTRUN_SCRIPT="$HOME/.local/state/win11clip-installer/firstrun.sh"

# Leftovers of older installers that added gustavosett's upstream package repository.
LEGACY_APT_LIST="/etc/apt/sources.list.d/gustavosett-clipboard-manager.list"
LEGACY_APT_KEY="/usr/share/keyrings/gustavosett-clipboard-manager-archive-keyring.gpg"
LEGACY_RPM_REPOS=(/etc/yum.repos.d/gustavosett-clipboard-manager*.repo /etc/zypp/repos.d/gustavosett-clipboard-manager*.repo)

DRY_RUN=false
BUILD_FROM_SOURCE=false
CLEANUP_PATHS=()
SUDO_KEEPALIVE_PID=""

cleanup() {
    [ -n "$SUDO_KEEPALIVE_PID" ] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    local p
    for p in "${CLEANUP_PATHS[@]}"; do rm -rf "$p"; done
}

# True when $1 >= $2 (dotted versions).
version_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]; }

record_install() {
    mkdir -p "$MANIFEST_DIR"
    grep -qxF "$1" "$MANIFEST" 2>/dev/null || echo "$1" >> "$MANIFEST"
}

# ask_yes_no "question" -> 0 only on an explicit yes. Defaults to No, and to No when there is
# no terminal to ask on (reads /dev/tty so it also works under `curl | bash`).
ask_yes_no() {
    local reply=""
    if ( : < /dev/tty ) 2>/dev/null; then
        read -r -p "$1 [y/N] " reply < /dev/tty || true
    fi
    [[ "$reply" =~ ^[Yy] ]]
}

# Say why sudo is needed before the first prompt, then keep the credential alive so a
# long build doesn't trigger a second password prompt.
SUDO_EXPLAINED=false
explain_sudo() {
    [ "$SUDO_EXPLAINED" = true ] && return 0
    SUDO_EXPLAINED=true
    echo ""
    echo -e "${YELLOW}[!]${NC} Administrator rights (sudo) are needed once to install system packages"
    echo "    with apt and to put the app in /usr. You may be asked for your password."
    echo ""
    sudo -v || error "sudo is required to install system packages. Re-run as a user that can use sudo."
    ( while true; do sudo -n true 2>/dev/null; sleep 50; kill -0 "$$" 2>/dev/null || exit; done ) &
    SUDO_KEEPALIVE_PID=$!
}

# Offer to remove the apt/dnf/zypper source older installers added for gustavosett's upstream
# package. It would otherwise keep offering (and `apt upgrade` installing) upstream's build
# in place of this project's. Asks first (default No) and saves a copy; uninstall.sh restores it.
remove_legacy_cloudsmith_source() {
    local found=()
    [ -f "$LEGACY_APT_LIST" ] && found+=("$LEGACY_APT_LIST")
    [ -f "$LEGACY_APT_KEY" ] && found+=("$LEGACY_APT_KEY")
    local f
    for f in "${LEGACY_RPM_REPOS[@]}"; do [ -f "$f" ] && found+=("$f"); done
    [ ${#found[@]} -eq 0 ] && return 0

    echo ""
    warn "Found the old upstream package source added by a previous installer:"
    for f in "${found[@]}"; do echo "      $f"; done
    echo "    It makes your package manager offer gustavosett's upstream build, which lacks this"
    echo "    project's fixes, and a routine upgrade could replace this app with it."
    echo "    If you remove it, a copy is saved under $BACKUP_DIR/apt-source"
    echo "    and uninstall.sh can put it back."
    if ! ask_yes_no "Remove the old upstream package source?"; then
        warn "Kept the upstream package source. A routine 'apt upgrade' may swap this app for upstream's build."
        return 0
    fi

    mkdir -p "$BACKUP_DIR/apt-source"
    cp -p --parents "${found[@]}" "$BACKUP_DIR/apt-source/" \
        || error "Could not save a backup copy to $BACKUP_DIR/apt-source, so nothing was removed."
    explain_sudo
    sudo rm -f "${found[@]}" || error "Could not remove ${found[*]}. Remove them by hand with: sudo rm -f ${found[*]}"
    for f in "${found[@]}"; do record_install "removed-source:$f"; done
    command -v apt-get >/dev/null 2>&1 && { sudo apt-get update -qq || true; }
    success "Removed the upstream package source (backup: $BACKUP_DIR/apt-source)."
}

# --build installs under /usr/local, but the launcher prefers a copy in /usr/bin, so an
# already-installed apt package (for example upstream's) would keep running instead of the
# new build. Ask once, before the long build, so a "no" costs nothing. Sets REMOVE_PACKAGE.
REMOVE_PACKAGE=false
confirm_packaged_copy_removal() {
    command -v dpkg >/dev/null 2>&1 && dpkg -s win11-clipboard-history >/dev/null 2>&1 || return 0
    local ver maint
    ver=$(dpkg-query -W -f='${Version}' win11-clipboard-history 2>/dev/null)
    maint=$(dpkg-query -W -f='${Maintainer}' win11-clipboard-history 2>/dev/null)

    echo ""
    warn "An apt package named win11-clipboard-history is already installed: version $ver (maintainer: $maint)."
    echo "    A source build installs to /usr/local, but the launcher prefers the copy in /usr/bin,"
    echo "    so that package would keep running instead of the build you are about to make."
    echo "    To fix that, after the build succeeds this installer would run:"
    echo "        sudo apt-get remove win11-clipboard-history"
    echo "    Your clipboard history and settings (~/.config) are not touched. Before removing it, the"
    echo "    package's files are saved under $BACKUP_DIR/package and uninstall.sh reports what was removed."
    if ask_yes_no "Remove the installed package once the new build is ready?"; then
        REMOVE_PACKAGE=true
    else
        error "Cancelled, nothing was changed. Either remove the package yourself (sudo apt remove win11-clipboard-history) and re-run, or re-run and answer y."
    fi
}

# Save the installed package's files, record it in the manifest, then remove it.
remove_packaged_copy() {
    [ "$REMOVE_PACKAGE" = true ] || return 0
    dpkg -s win11-clipboard-history >/dev/null 2>&1 || return 0
    local ver files=() p
    ver=$(dpkg-query -W -f='${Version}' win11-clipboard-history)
    while IFS= read -r p; do
        { [ -f "$p" ] || [ -L "$p" ]; } && files+=("${p#/}")
    done < <(dpkg -L win11-clipboard-history)

    mkdir -p "$BACKUP_DIR/package"
    tar -C / -czf "$BACKUP_DIR/package/win11-clipboard-history_${ver}_files.tar.gz" "${files[@]}" \
        || error "Could not save a backup of the installed package to $BACKUP_DIR/package, so it was not removed."
    sudo apt-get remove -y win11-clipboard-history \
        || error "Could not remove the installed win11-clipboard-history package. Run: sudo apt remove win11-clipboard-history   then re-run."
    record_install "removed-package:win11-clipboard-history=$ver"
    success "Removed the apt package win11-clipboard-history $ver (files saved in $BACKUP_DIR/package)."
}

# --- GitHub release lookup (this repository only) --------------------------------------
RELEASE_DATA=""
RELEASE_TAG=""
fetch_release() {
    local url="https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/releases/latest"
    [ -n "$RELEASE_TAG_PIN" ] && url="https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/releases/tags/$RELEASE_TAG_PIN"
    RELEASE_DATA=$(curl -fsSL "$url" 2>/dev/null) || return 1
    RELEASE_TAG=$(echo "$RELEASE_DATA" | grep '"tag_name":' | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/' | tr -cd '[:alnum:]._-')
    [ -n "$RELEASE_TAG" ]
}

# Print the download URL of the release asset with extension $1 ("deb", "rpm") for this arch.
release_asset_url() {
    local ext="$1" arch="$DEB_ARCH"
    [ "$ext" = "rpm" ] && arch="$RPM_ARCH"
    echo "$RELEASE_DATA" | grep "browser_download_url.*\.${ext}\"" | grep -i "${arch}" | head -1 | cut -d '"' -f 4
}

# Decide whether the default (prebuilt) install can be used. Sets RELEASE_PROBLEM when not.
RELEASE_PROBLEM=""
release_is_usable() {
    local ext="$1"
    if ! fetch_release; then
        RELEASE_PROBLEM="could not reach the GitHub releases of $REPO_OWNER/$REPO_NAME (offline, rate-limited, or no release published)"
        return 1
    fi
    if ! version_ge "${RELEASE_TAG#v}" "$MIN_RELEASE_VERSION"; then
        RELEASE_PROBLEM="the latest release ($RELEASE_TAG) is older than $MIN_RELEASE_VERSION and does not include the focus and rounded-corner fixes"
        return 1
    fi
    if [ -z "$(release_asset_url "$ext")" ]; then
        RELEASE_PROBLEM="release $RELEASE_TAG has no .$ext asset for this CPU architecture"
        return 1
    fi
    return 0
}

# --- Build-from-source toolchain (user-local, no sudo) ---------------------------------
load_nvm() {
    export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
    if [ -s "$NVM_DIR/nvm.sh" ]; then
        # nvm.sh is not written for `set -e`
        set +e; . "$NVM_DIR/nvm.sh"; set -e
    fi
}

node_ok() {
    command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1 && \
        [ "$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)" -ge "$MIN_NODE_MAJOR" ]
}

ensure_node() {
    load_nvm
    if node_ok; then
        success "Node.js $(node -v) already available."
        return 0
    fi
    if ! command -v nvm >/dev/null 2>&1; then
        # A stale NVM_DIR (folder deleted, profile still exports it) makes nvm's own installer refuse to run.
        [ -s "${NVM_DIR:-}/nvm.sh" ] || unset NVM_DIR
        log "Installing nvm $NVM_VERSION into ~/.nvm (no sudo; your shell profile is left untouched)..."
        curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_VERSION/install.sh" | PROFILE=/dev/null bash \
            || error "Could not install nvm. Check your internet connection, or install Node.js $MIN_NODE_MAJOR+ yourself and re-run."
        record_install "nvm-installed"
        load_nvm
    fi
    command -v nvm >/dev/null 2>&1 || error "nvm was installed but could not be loaded. Open a new terminal and re-run the installer."
    log "Installing Node.js $MIN_NODE_MAJOR+ with nvm..."
    set +e; nvm install --lts; local rc=$?; set -e
    [ "$rc" -eq 0 ] && node_ok || error "Node.js $MIN_NODE_MAJOR+ could not be installed with nvm. Install it manually (https://nodejs.org) and re-run."
    record_install "node-installed-by-nvm"
    success "Node.js $(node -v) ready."
}

rust_ok() {
    command -v cargo >/dev/null 2>&1 && command -v rustc >/dev/null 2>&1 && \
        version_ge "$(rustc --version | awk '{print $2}')" "$MIN_RUST_VERSION"
}

ensure_rust() {
    [ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
    if rust_ok; then
        success "Rust $(rustc --version | awk '{print $2}') already available."
        return 0
    fi
    if command -v rustup >/dev/null 2>&1; then
        log "Updating the Rust toolchain with rustup..."
        rustup toolchain install stable --profile minimal && rustup default stable \
            || error "rustup could not install a current Rust toolchain. Run 'rustup update stable' and re-run."
    else
        log "Installing Rust with rustup into ~/.cargo (no sudo; your shell profile is left untouched)..."
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --no-modify-path \
            || error "Could not install Rust. Check your internet connection, or install it from https://rustup.rs and re-run."
        record_install "rustup-installed"
    fi
    [ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
    rust_ok || error "A Rust toolchain >= $MIN_RUST_VERSION is required but was not found after installation."
    success "Rust $(rustc --version | awk '{print $2}') ready."
}

# Cleanup previous AppImage installation (prevents conflicts with package manager installs)
cleanup_appimage_installation() {
    local has_appimage=false
    
    # Check for AppImage installation artifacts
    if [ -f "$HOME/.local/bin/win11-clipboard-history.AppImage" ] || \
       [ -f "$HOME/.local/bin/win11-clipboard-history" ] || \
       [ -f "$HOME/.local/share/applications/win11-clipboard-history.desktop" ]; then
        has_appimage=true
    fi
    
    if [ "$has_appimage" = true ]; then
        log "Detected previous AppImage installation. Cleaning up..."
        
        # Kill any running AppImage instances
        killall -q win11-clipboard-history.AppImage 2>/dev/null || pkill -x win11-clipboard-history.AppImage 2>/dev/null || true

        # Wait for processes to terminate, with a timeout
        timeout=5
        interval=1
        elapsed=0
        while pgrep -f "win11-clipboard-history.AppImage" >/dev/null 2>&1; do
            if [ "$elapsed" -ge "$timeout" ]; then
                warn "Timed out waiting for Win11 Clipboard History AppImage processes to terminate."
                break
            fi
            sleep "$interval"
            elapsed=$((elapsed + interval))
        done
        
        # Remove AppImage files
        rm -f "$HOME/.local/bin/win11-clipboard-history.AppImage" 2>/dev/null || true
        rm -f "$HOME/.local/bin/win11-clipboard-history" 2>/dev/null || true
        rm -f "$HOME/.local/share/applications/win11-clipboard-history.desktop" 2>/dev/null || true
        rm -f "$HOME/.local/share/icons/hicolor"/*/apps/win11-clipboard-history.png 2>/dev/null || true
        
        # Update desktop database if available
        if command -v update-desktop-database &>/dev/null; then
            update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
        fi
        
        success "Previous AppImage installation cleaned up"
    fi
}

# Detect the distribution
detect_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        DISTRO_ID="${ID}"
        DISTRO_ID_LIKE="${ID_LIKE:-}"
        DISTRO_VERSION_ID="${VERSION_ID:-}"
        SYSTEM_FAMILY_INFO=$(echo "$ID $ID_LIKE" | tr '[:upper:]' '[:lower:]')
    else
        error "Cannot detect distribution. /etc/os-release not found."
    fi
}

# Detect system architecture and set DEB_ARCH/RPM_ARCH
detect_arch() {
    local arch
    arch=$(uname -m)
    
    case "$arch" in
        x86_64|amd64)
            DEB_ARCH="amd64"
            RPM_ARCH="x86_64"
            ;;
        aarch64|arm64)
            DEB_ARCH="arm64"
            RPM_ARCH="aarch64"
            ;;
        armv7l|armhf)
            DEB_ARCH="armhf"
            RPM_ARCH="armv7hl"
            ;;
        *)
            warn "Unknown architecture: $arch. Defaulting to x86_64."
            DEB_ARCH="amd64"
            RPM_ARCH="x86_64"
            ;;
    esac
    
    log "Architecture: $arch (DEB: $DEB_ARCH, RPM: $RPM_ARCH)"
}

# Check WebKitGTK compatibility
check_webkit_compatibility() {
    log "Checking WebKitGTK compatibility..."
    
    if ldconfig -p 2>/dev/null | grep -q "libwebkit2gtk-4.1"; then
        success "WebKitGTK 4.1 found (modern)"
        return 0
    elif ldconfig -p 2>/dev/null | grep -q "libwebkit2gtk-4.0"; then
        warn "WebKitGTK 4.0 found (legacy)"
        warn "Package manager installation may fail. AppImage fallback available."
        return 1
    else
        warn "WebKitGTK not found. Will be installed with the package."
        return 0
    fi
}

# Installation via package manager
install_via_package_manager() {
    # Clean up any previous AppImage installation to prevent PATH conflicts
    cleanup_appimage_installation

    # IMPORTANT: Check distro ID/family FIRST before falling back to command detection.
    # This prevents misdetection when tools like pacman are installed on non-Arch systems.
    
    # 1. Check for Fedora/RHEL Family
    # Note: fedora-asahi-remix is a Fedora-based distro for Apple Silicon Macs
    if [[ "$DISTRO_ID" == "fedora-asahi-remix" || "$SYSTEM_FAMILY_INFO" =~ "fedora" || "$SYSTEM_FAMILY_INFO" =~ "rhel" || "$SYSTEM_FAMILY_INFO" =~ "centos" ]]; then
        install_rpm
        return 0
    
    # 2. Check for Debian/Ubuntu Family
    elif [[ "$SYSTEM_FAMILY_INFO" =~ "debian" || "$SYSTEM_FAMILY_INFO" =~ "ubuntu" ]]; then
        install_deb
        return 0
    
    # 3. Check for OpenSUSE Family
    elif [[ "$SYSTEM_FAMILY_INFO" =~ "suse" ]]; then
        install_rpm_suse
        return 0
    
    # 4. Check for Arch Family (Arch, Manjaro, CachyOS, Endeavour, etc)
    # Check this AFTER other distros to avoid false positives from pacman being installed
    elif [[ "$SYSTEM_FAMILY_INFO" =~ "arch" ]]; then
        install_aur
        return 0
    fi
    
    # Fallback: Check for package managers if distro detection failed
    # This handles edge cases where /etc/os-release is incomplete
    if command -v dnf &>/dev/null; then
        install_rpm
        return 0
    elif command -v apt-get &>/dev/null; then
        install_deb
        return 0
    elif command -v zypper &>/dev/null; then
        install_rpm_suse
        return 0
    elif command -v pacman &>/dev/null; then
        install_aur
        return 0
    fi

    return 1  # Unknown system family
}

install_deb() {
    command -v apt-get >/dev/null 2>&1 || error "apt-get was not found, but this looks like a Debian/Ubuntu system. Install apt, or run: $0 --build"

    local deb_url
    deb_url=$(release_asset_url deb)
    local file="${deb_url##*/}"

    # Runtime tools the .deb's own Depends line does not cover (gdbus/gsettings, notify-send).
    local extra=() pkg
    for pkg in libglib2.0-bin libnotify-bin; do
        is_pkg_installed "$pkg" || extra+=("$pkg")
    done

    TEMP_DIR=$(mktemp -d)
    CLEANUP_PATHS+=("$TEMP_DIR")
    chmod 755 "$TEMP_DIR"

    log "Downloading $file ($RELEASE_TAG)..."
    curl -fL --progress-bar -o "$TEMP_DIR/$file" "$deb_url" \
        || error "Download failed: $deb_url. Check your connection and re-run, or build from source with: $0 --build"
    chmod 644 "$TEMP_DIR/$file"

    remove_legacy_cloudsmith_source

    explain_sudo
    log "Installing $file and its runtime dependencies with apt..."
    # --reinstall/--allow-downgrades: an older upstream build may already own this package name.
    sudo apt-get update -qq || warn "apt-get update failed; continuing with the package lists apt already has."
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --reinstall --allow-downgrades "$TEMP_DIR/$file" "${extra[@]}" \
        || error "apt could not install $file. Read the apt error above; fix it (often 'sudo apt --fix-broken install') and re-run."

    success "Installed $RELEASE_TAG from the GitHub release."
}

install_rpm() {
    log "Installing from GitHub releases (.rpm)..."
    
    LATEST_RELEASE_URL="https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/releases/latest"
    RELEASE_DATA=$(curl -s "$LATEST_RELEASE_URL")
    RELEASE_TAG=$(echo "$RELEASE_DATA" | grep '"tag_name":' | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/' | tr -cd '[:alnum:]._-')
    [ -z "$RELEASE_TAG" ] && error "Failed to fetch version."
    CLEAN_VERSION="${RELEASE_TAG#v}"
    
    TEMP_DIR=$(mktemp -d)
    chmod 755 "$TEMP_DIR"
    cd "$TEMP_DIR"
    CLEANUP_PATHS+=("$TEMP_DIR")
    
    FILE_URL=$(echo "$RELEASE_DATA" | grep "browser_download_url.*\.rpm" | grep -i "${RPM_ARCH}" | head -1 | cut -d '"' -f 4)
    if [ -n "$FILE_URL" ]; then
        FILE=$(basename "$FILE_URL")
    else
        FILE="win11-clipboard-history-${CLEAN_VERSION}-1.${RPM_ARCH}.rpm"
        FILE_URL="https://github.com/$REPO_OWNER/$REPO_NAME/releases/download/$RELEASE_TAG/$FILE"
    fi
    
    log "Downloading $FILE..."
    if ! curl -L -o "$FILE" "$FILE_URL" --progress-bar --fail; then
        error "Failed to download $FILE"
    fi
    chmod 644 "$FILE"
    
    log "Installing dependencies..."
    sudo dnf install -y xclip wl-clipboard acl libayatana-appindicator-gtk3 python3-gobject gtk3 || true
    
    log "Installing .rpm package..."
    sudo dnf install -y "./$FILE"
    
    success "Installed via DNF (from GitHub release)"
}

install_rpm_suse() {
    log "Installing from GitHub releases (.rpm)..."
    
    LATEST_RELEASE_URL="https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/releases/latest"
    RELEASE_DATA=$(curl -s "$LATEST_RELEASE_URL")
    RELEASE_TAG=$(echo "$RELEASE_DATA" | grep '"tag_name":' | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/' | tr -cd '[:alnum:]._-')
    [ -z "$RELEASE_TAG" ] && error "Failed to fetch version."
    CLEAN_VERSION="${RELEASE_TAG#v}"
    
    TEMP_DIR=$(mktemp -d)
    chmod 755 "$TEMP_DIR"
    cd "$TEMP_DIR"
    CLEANUP_PATHS+=("$TEMP_DIR")
    
    FILE_URL=$(echo "$RELEASE_DATA" | grep "browser_download_url.*\.rpm" | grep -i "${RPM_ARCH}" | head -1 | cut -d '"' -f 4)
    if [ -n "$FILE_URL" ]; then
        FILE=$(basename "$FILE_URL")
    else
        FILE="win11-clipboard-history-${CLEAN_VERSION}-1.${RPM_ARCH}.rpm"
        FILE_URL="https://github.com/$REPO_OWNER/$REPO_NAME/releases/download/$RELEASE_TAG/$FILE"
    fi
    
    log "Downloading $FILE..."
    if ! curl -L -o "$FILE" "$FILE_URL" --progress-bar --fail; then
        error "Failed to download $FILE"
    fi
    chmod 644 "$FILE"
    
    log "Installing dependencies..."
    sudo zypper install -y xclip wl-clipboard acl libayatana-appindicator3-1 python3-gobject gtk3 || true
    
    log "Installing .rpm package..."
    sudo zypper install -y "./$FILE"
    
    success "Installed via Zypper (from GitHub release)"
}

install_aur() {
    log "Installing from AUR..."
    
    # Detect AUR helper
    if command -v yay &>/dev/null; then
        yay -S --noconfirm win11-clipboard-history-bin
    elif command -v paru &>/dev/null; then
        paru -S --noconfirm win11-clipboard-history-bin
    else
        warn "No AUR helper found. Installing yay first..."
        sudo pacman -S --needed --noconfirm git base-devel
        git clone https://aur.archlinux.org/yay-bin.git /tmp/yay-bin
        cd /tmp/yay-bin && makepkg -si --noconfirm
        yay -S --noconfirm win11-clipboard-history-bin
    fi
    
    success "Installed via AUR!"
}

install_appimage() {
    log "Installing AppImage (universal fallback)..."
    
    local arch_name
    arch_name=$(uname -m)
    
    # Fetch latest version, filtering by architecture
    LATEST_URL=$(curl -s https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/releases/latest \
        | grep "browser_download_url.*AppImage" \
        | grep -i "${DEB_ARCH}\|${arch_name}" \
        | head -1 \
        | cut -d '"' -f 4)
    
    # Fallback: try any AppImage if no arch-specific match found
    if [ -z "$LATEST_URL" ]; then
        LATEST_URL=$(curl -s https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/releases/latest \
            | grep "browser_download_url.*AppImage" \
            | head -1 \
            | cut -d '"' -f 4)
    fi
    
    if [ -z "$LATEST_URL" ]; then
        error "Could not find AppImage download URL"
    fi
    
    # Create directories
    mkdir -p "$HOME/.local/bin"
    mkdir -p "$HOME/.local/share/applications"
    mkdir -p "$HOME/.local/share/icons/hicolor/128x128/apps"
    
    # Download AppImage
    log "Downloading AppImage..."
    curl -fsSL -o "$HOME/.local/bin/win11-clipboard-history.AppImage" "$LATEST_URL"
    chmod +x "$HOME/.local/bin/win11-clipboard-history.AppImage"
    
    # Download app icon for proper menu integration
    log "Downloading app icon..."
    curl -fsSL -o "$HOME/.local/share/icons/hicolor/128x128/apps/win11-clipboard-history.png" \
        "https://raw.githubusercontent.com/$REPO_OWNER/$REPO_NAME/master/src-tauri/icons/128x128.png" 2>/dev/null || true
    
    # Wrapper script — mirrors src-tauri/bundle/linux/wrapper.sh sanitization
    cat > "$HOME/.local/bin/win11-clipboard-history" << 'WRAPPER_EOF'
#!/bin/bash
# AppImage wrapper for win11-clipboard-history
# Sanitizes Snap/Flatpak environment leaks, then launches the AppImage.

# Always clear library/runtime overrides from sandbox parents
unset LD_LIBRARY_PATH
unset LD_PRELOAD
unset GTK_PATH
unset GIO_MODULE_DIR
unset GTK_IM_MODULE_FILE
unset GTK_EXE_PREFIX
unset LOCPATH
unset GSETTINGS_SCHEMA_DIR

# Fix XDG_DATA_DIRS only when contaminated by sandbox paths
sanitize_xdg_data_dirs() {
    local xdg="${XDG_DATA_DIRS:-}"
    local system_dirs="/usr/local/share:/usr/share:/var/lib/snapd/desktop"

    if [[ -z "${SNAP:-}" && -z "${FLATPAK_ID:-}" && "$xdg" != *"/snap/"* && "$xdg" != *"/flatpak/"* ]]; then
        return
    fi

    local cleaned=""
    local entry
    IFS=':' read -ra entries <<< "$xdg"
    for entry in "${entries[@]}"; do
        case "$entry" in
            */snap/*|*/flatpak/*) continue ;;
        esac
        case ":$system_dirs:" in
            *":$entry:"*) continue ;;
        esac
        cleaned="${cleaned:+$cleaned:}$entry"
    done

    export XDG_DATA_DIRS="${system_dirs}${cleaned:+:$cleaned}"
}
sanitize_xdg_data_dirs

export NO_AT_BRIDGE=1

exec "$HOME/.local/bin/win11-clipboard-history.AppImage" "$@"
WRAPPER_EOF
    chmod +x "$HOME/.local/bin/win11-clipboard-history"
    
    # .desktop file with proper icon
    cat > "$HOME/.local/share/applications/win11-clipboard-history.desktop" << EOF
[Desktop Entry]
Type=Application
Name=Clipboard History
Comment=Windows 11-style Clipboard History Manager
Exec=$HOME/.local/bin/win11-clipboard-history
Icon=win11-clipboard-history
Terminal=false
Categories=Utility;
StartupWMClass=win11-clipboard-history
EOF
    
    # Ask about udev rules for AppImage (optional - maintains portability)
    setup_udev_appimage_optional
    
    success "AppImage installed to ~/.local/bin/"
    warn "Add ~/.local/bin to your PATH if not already there"
}

setup_udev_appimage_optional() {
    echo ""
    warn "For paste simulation to work, the app needs access to /dev/uinput."
    echo ""
    echo "You have two options:"
    echo "  1. Quick fix (no logout required): Run this command:"
    echo "     sudo setfacl -m u:$USER:rw /dev/uinput"
    echo ""
    echo "  2. Permanent fix (requires sudo, then logout/login):"
    echo "     The installer can set up udev rules for you."
    echo ""
    
    # Check if running interactively
    if [ -t 0 ]; then
        read -p "Set up permanent udev rules now? [y/N] " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            setup_udev_appimage
        else
            log "Skipping udev setup. You can run this later if paste doesn't work:"
            echo "  sudo setfacl -m u:$USER:rw /dev/uinput"
        fi
    else
        # Non-interactive: just use ACL for immediate access
        log "Non-interactive mode: Using ACL for immediate access..."
        if command -v setfacl &>/dev/null && [ -e /dev/uinput ]; then
            sudo setfacl -m "u:${USER}:rw" /dev/uinput 2>/dev/null || true
            success "Permissions configured via ACL"
        else
            warn "Run 'sudo setfacl -m u:$USER:rw /dev/uinput' if paste doesn't work"
        fi
    fi
}

setup_udev_appimage() {
    log "Setting up permanent uinput permissions (requires sudo)..."
    
    # Create udev rule
    sudo tee /etc/udev/rules.d/99-win11-clipboard-input.rules > /dev/null << 'EOF'
# udev rules for Windows 11 Clipboard History
ACTION=="add", SUBSYSTEM=="misc", KERNEL=="uinput", OPTIONS+="static_node=uinput"
KERNEL=="uinput", SUBSYSTEM=="misc", MODE="0660", GROUP="input", TAG+="uaccess"
EOF
    
    # Configure module to load on boot
    echo "uinput" | sudo tee /etc/modules-load.d/win11-clipboard.conf > /dev/null
    
    # Load now
    sudo modprobe uinput 2>/dev/null || true
    sudo udevadm control --reload-rules 2>/dev/null || true
    sudo udevadm trigger --subsystem-match=misc 2>/dev/null || true
    
    # ACL for immediate access
    if command -v setfacl &>/dev/null && [ -e /dev/uinput ]; then
        sudo setfacl -m "u:${USER}:rw" /dev/uinput 2>/dev/null || true
        success "Permissions configured (immediate access via ACL)"
    else
        warn "You may need to log out and back in for permissions to take effect"
    fi
}


for arg in "$@"; do
    case "$arg" in
        --build|--build-from-source) BUILD_FROM_SOURCE=true ;;
        --dry-run) DRY_RUN=true ;;
        -h|--help)
            echo "Usage: install.sh [--build] [--dry-run]"
            echo "  --build     build from source instead of installing the prebuilt release"
            echo "  --dry-run   print what would be installed and exit without changing anything"
            echo "  WIN11CLIP_TAG=vX.Y.Z pins the release (or, with --build, the source tag) to install"
            exit 0
            ;;
        *) error "Unknown option: $arg (see --help)" ;;
    esac
done

is_pkg_installed() {
    local pkg="$1"
    dpkg -s "$pkg" >/dev/null 2>&1 || dpkg -s "${pkg}t64" >/dev/null 2>&1
}

# apt packages the app needs at runtime beyond its shared libraries (the .deb's own Depends
# line already covers these when installing the release package).
runtime_apt_deps() {
    local pkexec_pkg="pkexec"
    apt-cache show pkexec >/dev/null 2>&1 || pkexec_pkg="policykit-1"
    echo "xclip xdotool wl-clipboard acl libglib2.0-bin libnotify-bin $pkexec_pkg libgtk-3-0 librsvg2-2 libayatana-appindicator3-1"
}

build_apt_deps() {
    local webkit="libwebkit2gtk-4.1"
    apt-cache show libwebkit2gtk-4.1-dev >/dev/null 2>&1 || webkit="libwebkit2gtk-4.0"
    echo "build-essential curl wget file git pkg-config libssl-dev libgtk-3-dev libayatana-appindicator3-dev librsvg2-dev libxdo-dev libudev-dev ${webkit}-dev $( [ "$webkit" = libwebkit2gtk-4.1 ] && echo libwebkit2gtk-4.1-0 || echo libwebkit2gtk-4.0-37 )"
}

check_and_install_deps() {
    command -v apt-get >/dev/null 2>&1 || error "Building from source needs apt-get to install system libraries, and it was not found. Install the GTK3/WebKitGTK 4.1 development packages for your distribution (see the README), then re-run."

    local MISSING_RUNTIME=() MISSING_BUILD=() dep
    for dep in $(runtime_apt_deps); do
        is_pkg_installed "$dep" || MISSING_RUNTIME+=("$dep")
    done
    for dep in $(build_apt_deps); do
        is_pkg_installed "$dep" || MISSING_BUILD+=("$dep")
    done

    if [ $(( ${#MISSING_RUNTIME[@]} + ${#MISSING_BUILD[@]} )) -eq 0 ]; then
        success "All apt dependencies are satisfied."
        return 0
    fi

    log "Missing system packages: ${MISSING_RUNTIME[*]} ${MISSING_BUILD[*]}"
    explain_sudo
    sudo apt-get update -qq || warn "apt-get update failed; continuing with the package lists apt already has."
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${MISSING_RUNTIME[@]}" "${MISSING_BUILD[@]}" \
        || error "apt could not install the build dependencies. Read the apt error above, fix it, and re-run."

    # Remember which build packages are ours, so uninstall.sh never removes ones you already had.
    for dep in "${MISSING_BUILD[@]}"; do record_install "apt-build:$dep"; done
}

# Use the checkout the installer runs from, or shallow-clone one (curl | bash has none).
prepare_source_tree() {
    if [ -f package.json ] && [ -f src-tauri/Cargo.toml ]; then
        return 0
    fi
    local here
    here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd)" || here=""
    if [ -n "$here" ] && [ -f "$here/package.json" ] && [ -f "$here/src-tauri/Cargo.toml" ]; then
        cd "$here"
        return 0
    fi

    command -v git >/dev/null 2>&1 || error "git is needed to download the source. Install it with: sudo apt install git"
    # Not /tmp: the build tree is several GB.
    mkdir -p "$HOME/.cache"
    local dir
    dir=$(mktemp -d "$HOME/.cache/win11clip-src.XXXXXX")
    CLEANUP_PATHS+=("$dir")
    log "Downloading the source from github.com/$REPO_OWNER/$REPO_NAME${RELEASE_TAG_PIN:+ ($RELEASE_TAG_PIN)}..."
    git clone --depth 1 ${RELEASE_TAG_PIN:+--branch "$RELEASE_TAG_PIN"} "https://github.com/$REPO_OWNER/$REPO_NAME.git" "$dir" \
        || error "Could not download the source from github.com/$REPO_OWNER/$REPO_NAME. Check your connection and re-run."
    cd "$dir"
}

build_from_source() {
    log "Starting build from source..."
    confirm_packaged_copy_removal
    check_and_install_deps
    ensure_node
    ensure_rust
    prepare_source_tree

    log "Installing npm dependencies (from package-lock.json)..."
    npm ci || error "npm ci failed. Read the error above; re-running the installer is safe."

    log "Building the app (this takes several minutes the first time)..."
    # --no-bundle: only the binary is needed here; `make install` puts it in place.
    npm run tauri:build -- --no-bundle || error "The build failed. Read the error above; re-running the installer is safe."

    log "Installing system-wide..."
    explain_sudo
    remove_legacy_cloudsmith_source
    # The wrapper looks in /usr/bin before /usr/local/lib, so a packaged copy (for example
    # upstream's) would keep running instead of the build that was just made.
    remove_packaged_copy
    sudo env "PATH=$PATH" make install PREFIX=/usr/local || error "make install failed. Read the error above."

    success "Build and install from source completed successfully."
}

# What the installer would do on this machine, without changing anything.
print_plan() {
    local ext="deb" mode="prebuilt release"
    [[ "$SYSTEM_FAMILY_INFO" =~ (fedora|rhel|centos|suse) ]] && ext="rpm"
    echo ""
    echo -e "${C_BOLD}Dry run: nothing will be changed.${NC}"
    echo "  System      : $DISTRO_ID ($DEB_ARCH), session: ${XDG_SESSION_TYPE:-unknown}, desktop: ${XDG_CURRENT_DESKTOP:-unknown}"

    if [ "$BUILD_FROM_SOURCE" = true ]; then
        mode="build from source (--build)"
    elif [[ "$SYSTEM_FAMILY_INFO" =~ arch ]]; then
        mode="AUR package"
    elif release_is_usable "$ext"; then
        echo "  Release     : $RELEASE_TAG -> $(release_asset_url "$ext")"
    else
        mode="build from source (no usable release: $RELEASE_PROBLEM)"
        BUILD_FROM_SOURCE=true
    fi
    echo "  Install mode: $mode"

    if command -v dpkg >/dev/null 2>&1; then
        local pkgs=() dep
        for dep in $(runtime_apt_deps); do is_pkg_installed "$dep" || pkgs+=("$dep"); done
        echo "  Runtime apt packages still missing (sudo apt): ${pkgs[*]:-none}"
        if [ "$BUILD_FROM_SOURCE" = true ]; then
            pkgs=(); for dep in $(build_apt_deps); do is_pkg_installed "$dep" || pkgs+=("$dep"); done
            echo "  Build apt packages still missing (sudo apt): ${pkgs[*]:-none}"
            load_nvm; [ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
            node_ok && echo "  Node.js     : already available ($(node -v))" || echo "  Node.js     : will be installed with nvm into ~/.nvm (no sudo)"
            rust_ok && echo "  Rust        : already available ($(rustc --version | awk '{print $2}'))" || echo "  Rust        : will be installed with rustup into ~/.cargo (no sudo)"
        fi
    fi
    [ -f "$LEGACY_APT_LIST" ] && echo "  Will ask    : before removing $LEGACY_APT_LIST (old upstream apt source) and its key (default No, backed up first)"
    if [ "$BUILD_FROM_SOURCE" = true ] && command -v dpkg >/dev/null 2>&1 && dpkg -s win11-clipboard-history >/dev/null 2>&1; then
        echo "  Will ask    : before removing the installed apt package win11-clipboard-history $(dpkg-query -W -f='${Version}' win11-clipboard-history) (default No, backed up first)"
    fi
    echo "  Extensions  : win11-clipboard-bridge, window-calls (patched) -> ~/.local/share/gnome-shell/extensions"
    local sa_bundled sa_v sa_src_v sa_t sa_iv
    sa_bundled=$(bundled_spawn_at)
    sa_v=""
    if [ -n "$sa_bundled" ]; then sa_v=$(spawn_at_version "$sa_bundled"); fi
    sa_src_v="$sa_v"
    for sa_t in "$SPAWN_AT_SYSTEM_BIN" "$SPAWN_AT_USER_BIN"; do
        sa_iv=$(spawn_at_version "$sa_t")
        if [ -n "$sa_iv" ] && { [ -z "$sa_src_v" ] || semver_lt "$sa_src_v" "$sa_iv"; }; then sa_src_v="$sa_iv"; fi
    done
    if [ -n "$sa_v" ]; then
        echo "  spawn-at    : bundled $sa_v (needs $SPAWN_AT_MIN_VERSION or newer); a newer installed copy is kept, older ones are replaced"
    else
        echo "  spawn-at    : no bundled copy here; $SPAWN_AT_MIN_VERSION or newer is downloaded from github.com/harshp2008/spawn-at unless one is already installed"
        sa_src_v="${sa_src_v:-$SPAWN_AT_MIN_VERSION}"
    fi
    for sa_t in "$SPAWN_AT_SYSTEM_BIN" "$SPAWN_AT_USER_BIN"; do
        echo "                $(spawn_at_copy_plan "$sa_t" "$sa_src_v")"
    done
    echo "                its GNOME extension is deployed by that same CLI, so the two never differ"
    echo "  Shortcuts   : Super+V, Ctrl+Alt+V, Super+. via GNOME custom keybindings"
    if [[ "${XDG_SESSION_TYPE:-}" == "wayland" ]]; then
        echo "  Note        : on Wayland, newly installed or updated GNOME extensions only load after you log out and back in."
        echo "  After login : a one-time check (autostart) reports in plain English if an extension did not load; log: ~/.local/state/win11clip-installer/firstrun.log"
    fi
    echo "  sudo        : needed once for apt and for installing under /usr"
    echo ""
}

launch_app() {
    log "Starting application..."
    
    # Kill any existing instances (matches both wrapper and -bin binary)
    killall -q win11-clipboard-history-bin 2>/dev/null || pkill -x win11-clipboard-history-bin 2>/dev/null || true
    killall -q win11-clipboard-history.AppImage 2>/dev/null || pkill -x win11-clipboard-history.AppImage 2>/dev/null || true
    sleep 1
    
    # Launch detached from terminal
    nohup win11-clipboard-history >/dev/null 2>&1 < /dev/null & disown
    
    sleep 2
    
    if command -v pgrep >/dev/null 2>&1; then
        pgrep -f "win11-clipboard-history" >/dev/null 2>&1 || return 1
    elif command -v ps >/dev/null 2>&1; then
        ps aux | grep -v grep | grep -q "win11-clipboard-history" || return 1
    fi

    return 0
}

# Oldest spawn-at with the stale-arm fix: extension protocol 7 plus a CLI that withdraws its own
# unclaimed arm. bundled-deps/VERSIONS must list at least this version.
SPAWN_AT_MIN_VERSION="0.2.3"
SPAWN_AT_SYSTEM_BIN="/usr/local/bin/spawn-at"
SPAWN_AT_USER_BIN="$HOME/.local/bin/spawn-at"
SPAWN_AT_EXT_DIR="$HOME/.local/share/gnome-shell/extensions/spawn-at@harsh.local"

# Prints the release version an executable reports ("spawn-at 0.2.3" -> 0.2.3), or nothing when it
# is missing, can't run, or is not a release build (a dev build prints "DEV BUILD").
spawn_at_version() {
    local exe="$1" first=""
    [ -x "$exe" ] || return 0
    first=$("$exe" -V 2>/dev/null | head -n 1) || true
    if [[ "$first" =~ ^spawn-at[[:space:]]+([0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?)$ ]]; then
        echo "${BASH_REMATCH[1]}"
    fi
}

# semver_lt A B -> success when A is older than B. major.minor.patch are compared as numbers
# (sort -V, so 0.2.10 > 0.2.3); with equal numbers a pre-release (0.2.3-beta.1) is older than the release.
semver_lt() {
    local a="$1" b="$2" ac="${1%%-*}" bc="${2%%-*}"
    if [ "$ac" != "$bc" ]; then
        [ "$(printf '%s\n%s\n' "$ac" "$bc" | sort -V | head -n 1)" = "$ac" ]
        return
    fi
    [ "$a" = "$b" ] && return 1
    if [ "$a" != "$ac" ] && [ "$b" = "$bc" ]; then return 0; fi
    if [ "$a" = "$ac" ] && [ "$b" != "$bc" ]; then return 1; fi
    [ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -n 1)" = "$a" ]
}

# Path of the spawn-at CLI shipped in this checkout (empty when running without one, e.g. curl | bash).
bundled_spawn_at() {
    local p
    for p in bundled-deps/bin/spawn-at ../bundled-deps/bin/spawn-at; do
        [ -f "$p" ] && { echo "$p"; return 0; }
    done
    return 0
}

# Succeeds when the bundled CLI matches the sha256 recorded for it in bundled-deps/VERSIONS.
bundled_spawn_at_checksum_ok() {
    local bin="$1" manifest want got
    manifest="$(dirname "$(dirname "$bin")")/VERSIONS"
    [ -f "$manifest" ] || return 1
    want=$(awk '$1=="spawn-at"{print $3}' "$manifest")
    got=$(sha256sum "$bin" | awk '{print $1}')
    [ -n "$want" ] && [ "$want" = "$got" ]
}

# One line saying what will happen to the spawn-at copy at $1 given the version we will install.
spawn_at_copy_plan() {
    local path="$1" want="$2" have
    if [ ! -e "$path" ]; then echo "$path: not installed -> install $want"; return; fi
    have=$(spawn_at_version "$path")
    if [ -z "$have" ]; then echo "$path: no release version (dev build?) -> replace with $want, old file saved"
    elif semver_lt "$have" "$want"; then echo "$path: $have -> replace with $want"
    else echo "$path: $have -> keep (not older than $want)"; fi
}

# Fingerprint of the deployed spawn-at extension files, to tell whether `spawn-at install` changed them.
spawn_at_ext_fingerprint() {
    [ -d "$SPAWN_AT_EXT_DIR" ] || { echo "absent"; return; }
    (cd "$SPAWN_AT_EXT_DIR" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}')
}

install_spawn_at() {
    log "Installing spawn-at utility (minimum version $SPAWN_AT_MIN_VERSION)..."
    local bundled bundled_v="" src="" src_v="" t v
    local targets=("$SPAWN_AT_SYSTEM_BIN" "$SPAWN_AT_USER_BIN")

    bundled=$(bundled_spawn_at)
    if [ -n "$bundled" ]; then
        bundled_spawn_at_checksum_ok "$bundled" || error "bundled-deps/bin/spawn-at does not match the sha256 in bundled-deps/VERSIONS. Re-download the source and try again."
        bundled_v=$(spawn_at_version "$bundled")
        if [ -z "$bundled_v" ]; then
            warn "The bundled spawn-at can't run on this machine ($(uname -m)); using the official release instead."
            bundled=""
        elif semver_lt "$bundled_v" "$SPAWN_AT_MIN_VERSION"; then
            error "The bundled spawn-at is $bundled_v, older than the required $SPAWN_AT_MIN_VERSION."
        fi
    fi

    # The copy every location is brought up to: the newest of the bundled CLI and what is already installed.
    # Nothing is ever downgraded.
    if [ -n "$bundled" ]; then src="$bundled"; src_v="$bundled_v"; fi
    for t in "${targets[@]}"; do
        v=$(spawn_at_version "$t")
        if [ -n "$v" ] && { [ -z "$src_v" ] || semver_lt "$src_v" "$v"; }; then src="$t"; src_v="$v"; fi
    done

    if [ -z "$src" ] || semver_lt "$src_v" "$SPAWN_AT_MIN_VERSION"; then
        log "Downloading the latest spawn-at release from its official repository..."
        curl -fsSL https://raw.githubusercontent.com/harshp2008/spawn-at/main/install.sh | bash -s -- --headless --yes --no-action \
            || error "Failed to install spawn-at from the official installer"
        for t in "${targets[@]}"; do
            v=$(spawn_at_version "$t")
            if [ -n "$v" ] && { [ -z "$src_v" ] || semver_lt "$src_v" "$v"; }; then src="$t"; src_v="$v"; fi
        done
        if [ -z "$src" ] || semver_lt "$src_v" "$SPAWN_AT_MIN_VERSION"; then
            warn "spawn-at ${src_v:-unknown} is installed, but $SPAWN_AT_MIN_VERSION or newer is required (older ones can misplace the popup)."
        fi
    fi

    # Work from a private copy: $src may be one of the targets, and replacing it must not change what we copy.
    local work
    work="$(mktemp -d)"; CLEANUP_PATHS+=("$work")
    if [ -n "$src" ]; then
        cp -f "$src" "$work/spawn-at"; chmod 755 "$work/spawn-at"
        for t in "${targets[@]}"; do
            v=$(spawn_at_version "$t")
            if [ -e "$t" ] && [ -n "$v" ] && ! semver_lt "$v" "$src_v"; then
                log "Keeping $t ($v, not older than $src_v)"
                continue
            fi
            if [ -e "$t" ] && [ -z "$v" ]; then
                mkdir -p "$BACKUP_DIR"
                cp -f "$t" "$BACKUP_DIR/spawn-at$(echo "$t" | tr / _).$(date +%Y%m%d-%H%M%S)" 2>/dev/null \
                    && log "$t has no release version (a dev build?); saved a copy in $BACKUP_DIR"
            fi
            if [ "$t" = "$SPAWN_AT_SYSTEM_BIN" ]; then
                if sudo install -Dm755 "$work/spawn-at" "$t" 2>/dev/null; then log "Installed spawn-at $src_v to $t"
                else warn "Could not write $t (needs sudo); the copy in ~/.local/bin is used instead."; fi
            else
                mkdir -p "$(dirname "$t")"
                install -Dm755 "$work/spawn-at" "$t" && log "Installed spawn-at $src_v to $t"
            fi
        done
    fi

    # Deploy the extension from the CLI that stays installed (the newest copy, never older than the
    # bundled one), so the CLI and the extension always come from the same release.
    local best="" best_v=""
    for t in "${targets[@]}"; do
        v=$(spawn_at_version "$t")
        if [ -n "$v" ] && { [ -z "$best_v" ] || semver_lt "$best_v" "$v"; }; then best="$t"; best_v="$v"; fi
    done
    if [ -n "$best" ]; then
        local before after
        before=$(spawn_at_ext_fingerprint)
        log "Deploying the spawn-at $best_v GNOME extension..."
        "$best" install --headless --yes --no-action --skip-bin 2>/dev/null || warn "spawn-at install reported a problem; run: $best install --skip-bin"
        after=$(spawn_at_ext_fingerprint)
        # The Shell only loads extension files at login, so any change needs a log out.
        if [ "$before" != "$after" ]; then
            EXTENSIONS_MODIFIED=1
            RESTART_NEEDED=1
        fi
    fi

    # Configure auto-update on login
    local autostart_dir="$HOME/.config/autostart"
    mkdir -p "$autostart_dir"
    cat > "$autostart_dir/spawn-at-autoupdate.desktop" << 'EOF'
[Desktop Entry]
Type=Application
Name=spawn-at Auto Update
Exec=sh -c 'sleep 10 && (spawn-at update --headless || ~/.local/bin/spawn-at update --headless || /usr/local/bin/spawn-at update --headless)'
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
Comment=Automatically check and install spawn-at updates on login
EOF

    # If spawn-at install created spawn-at-update-check.desktop with --check, ensure it updates directly
    if [ -f "$autostart_dir/spawn-at-update-check.desktop" ]; then
        sed -i 's/ update --check --headless/ update --headless/g' "$autostart_dir/spawn-at-update-check.desktop" 2>/dev/null || true
    fi

    success "spawn-at ${best_v:-?} installed and auto-update configured at login"
}

install_uninstaller() {
    log "Installing uninstaller utility..."
    if [ -f "scripts/uninstall.sh" ]; then
        sudo install -Dm755 scripts/uninstall.sh /usr/local/bin/win11-clipboard-uninstall
    elif [ -f "../scripts/uninstall.sh" ]; then
        sudo install -Dm755 ../scripts/uninstall.sh /usr/local/bin/win11-clipboard-uninstall
    elif [ -f "uninstall.sh" ]; then
        sudo install -Dm755 uninstall.sh /usr/local/bin/win11-clipboard-uninstall
    else
        local fetched=false
        local owners=("$REPO_OWNER" "harshp2008")
        local repos=("$REPO_NAME" "Windows-11-Clipboard-History-For-Linux")
        for owner in "${owners[@]}"; do
            for repo in "${repos[@]}"; do
                local UNINSTALL_URL="https://raw.githubusercontent.com/$owner/$repo/master/scripts/uninstall.sh"
                if sudo curl -fsSL -o /usr/local/bin/win11-clipboard-uninstall "$UNINSTALL_URL" 2>/dev/null; then
                    fetched=true
                    break 2
                fi
            done
        done
        if [ "$fetched" = false ]; then
            error "Failed to download uninstall.sh"
        fi
    fi
    sudo chmod 755 /usr/local/bin/win11-clipboard-uninstall
    success "Uninstaller installed to /usr/local/bin/win11-clipboard-uninstall"
}

install_window_calls() {
    if ! command -v gnome-extensions &>/dev/null; then
        return 0
    fi

    local WC_UUID="window-calls@domandoman.xyz"
    local EXT_DIR="$HOME/.local/share/gnome-shell/extensions"
    local staging_needed=false
    local temp_dir=""

    if [[ "$XDG_SESSION_TYPE" == "wayland" ]] || [[ -n "$WAYLAND_DISPLAY" ]]; then
        log "GNOME Wayland session detected. Installing patched $WC_UUID extension..."
    else
        log "Deploying patched $WC_UUID extension..."
    fi

    # If running via curl | bash without local bundled-deps, fetch the patched repository archive/files
    if [ ! -f "bundled-deps/extensions/$WC_UUID/extension.js" ]; then
        if [ -f "../bundled-deps/extensions/$WC_UUID/extension.js" ]; then
            mkdir -p bundled-deps/extensions
            cp -r "../bundled-deps/extensions/$WC_UUID" bundled-deps/extensions/
            staging_needed=true
        else
            log "Local bundled-deps not found. Fetching patched $WC_UUID from repository..."
            temp_dir=$(mktemp -d)
            mkdir -p "bundled-deps/extensions/$WC_UUID"
            staging_needed=true
            local fetched=false
            local owners=("$REPO_OWNER" "harshp2008")
            local repos=("$REPO_NAME" "Windows-11-Clipboard-History-For-Linux")
            for owner in "${owners[@]}"; do
                for repo in "${repos[@]}"; do
                    local raw_url="https://raw.githubusercontent.com/$owner/$repo/master/bundled-deps/extensions/$WC_UUID"
                    if curl -fsSL "$raw_url/metadata.json" -o "bundled-deps/extensions/$WC_UUID/metadata.json" 2>/dev/null && \
                       curl -fsSL "$raw_url/extension.js" -o "bundled-deps/extensions/$WC_UUID/extension.js" 2>/dev/null; then
                        fetched=true
                        break 2
                    fi
                done
            done
            if [ "$fetched" = false ]; then
                warn "Direct raw fetch failed, trying repository archive tarball..."
                for owner in "${owners[@]}"; do
                    for repo in "${repos[@]}"; do
                        if curl -fsSL "https://github.com/$owner/$repo/archive/refs/heads/master.tar.gz" | tar -xz -C "$temp_dir" 2>/dev/null; then
                            local archive_wc
                            archive_wc=$(find "$temp_dir" -type d -name "$WC_UUID" | head -n 1)
                            if [ -n "$archive_wc" ] && [ -f "$archive_wc/extension.js" ]; then
                                cp -r "$archive_wc/"* "bundled-deps/extensions/$WC_UUID/"
                                fetched=true
                                break 2
                            fi
                        fi
                    done
                done
            fi
        fi
    fi

    if [ -f "bundled-deps/extensions/$WC_UUID/extension.js" ]; then
        mkdir -p "$HOME/.local/share/gnome-shell/extensions"
        rm -rf "$HOME/.local/share/gnome-shell/extensions/window-calls@domandoman.xyz"
        cp -r "bundled-deps/extensions/window-calls@domandoman.xyz" "$HOME/.local/share/gnome-shell/extensions/"
        gnome-extensions enable "window-calls@domandoman.xyz" 2>/dev/null || true

        EXTENSIONS_MODIFIED=1
        RESTART_NEEDED=1
        success "Deployed and enabled patched $WC_UUID"
    else
        error "Failed to locate or download patched $WC_UUID extension."
    fi

    if [ "$staging_needed" = true ]; then
        rm -rf bundled-deps/extensions/"$WC_UUID" 2>/dev/null || true
        rmdir bundled-deps/extensions 2>/dev/null || true
        rmdir bundled-deps 2>/dev/null || true
        [ -n "$temp_dir" ] && rm -rf "$temp_dir"
    fi
}

install_gnome_extensions() {
    if ! command -v gnome-extensions &>/dev/null; then
        if [[ "${XDG_CURRENT_DESKTOP:-}" == *GNOME* ]]; then
            warn "GNOME was detected but the 'gnome-extensions' command is missing, so the focus/always-on-top"
            warn "extensions were NOT installed. Install it with: sudo apt install gnome-shell   (then re-run)"
        fi
        return 0
    fi
    
    log "Setting up GNOME Shell extensions..."
    
    # 1. win11-clipboard-bridge
    local BRIDGE_UUID="win11-clipboard-bridge@harshp2008.github.com"
    local EXT_DIR="$HOME/.local/share/gnome-shell/extensions"
    local BRIDGE_DIR="$EXT_DIR/$BRIDGE_UUID"
    
    local bridge_existed=false
    [ -f "$BRIDGE_DIR/metadata.json" ] && bridge_existed=true

    mkdir -p "$BRIDGE_DIR"
    if [ -d "extensions/$BRIDGE_UUID" ]; then
        cp -r "extensions/$BRIDGE_UUID/"* "$BRIDGE_DIR/"
    elif [ -d "../extensions/$BRIDGE_UUID" ]; then
        cp -r "../extensions/$BRIDGE_UUID/"* "$BRIDGE_DIR/"
    else
        local fetched=false
        local repos=("$REPO_NAME" "Windows-11-Clipboard-History-For-Linux")
        for repo in "${repos[@]}"; do
            if curl -fsSL "https://raw.githubusercontent.com/$REPO_OWNER/$repo/master/extensions/$BRIDGE_UUID/metadata.json" -o "$BRIDGE_DIR/metadata.json" 2>/dev/null && \
               curl -fsSL "https://raw.githubusercontent.com/$REPO_OWNER/$repo/master/extensions/$BRIDGE_UUID/extension.js" -o "$BRIDGE_DIR/extension.js" 2>/dev/null; then
                mkdir -p "$BRIDGE_DIR/schemas"
                curl -fsSL "https://raw.githubusercontent.com/$REPO_OWNER/$repo/master/extensions/$BRIDGE_UUID/schemas/org.gnome.shell.extensions.win11-clipboard-bridge.gschema.xml" -o "$BRIDGE_DIR/schemas/org.gnome.shell.extensions.win11-clipboard-bridge.gschema.xml" 2>/dev/null || true
                fetched=true
                break
            fi
        done
    fi
    
    if [ "$bridge_existed" = false ]; then
        EXTENSIONS_MODIFIED=1
    fi

    if command -v glib-compile-schemas &>/dev/null && [ -d "$BRIDGE_DIR/schemas" ]; then
        glib-compile-schemas "$BRIDGE_DIR/schemas" 2>/dev/null || true
    fi
    
    gnome-extensions enable "$BRIDGE_UUID" 2>/dev/null || true
    success "Configured $BRIDGE_UUID"
    
    # 2. window-calls@domandoman.xyz (Patched with GetCoordinates)
    install_window_calls
}

# If running under sudo, execute gsettings as the actual user
run_user_gsettings() {
    if [ -n "$SUDO_USER" ]; then
        sudo -u "$SUDO_USER" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u "$SUDO_USER")/bus" gsettings "$@"
    else
        gsettings "$@"
    fi
}

configure_gnome_shortcuts() {
    if ! command -v gsettings &>/dev/null; then
        return 0
    fi
    
    if ! run_user_gsettings list-schemas 2>/dev/null | grep -q "org.gnome.settings-daemon.plugins.media-keys"; then
        return 0
    fi

    log "Configuring GNOME custom shortcuts..."

    local target_cb_cmd="spawn-at spawn --anchor cursor -o -15 -15 -m 10 win11-clipboard-history --clipboard"
    local target_emoji_cmd="spawn-at spawn --anchor cursor -o -15 -15 -m 10 win11-clipboard-history --emoji"

    local raw_bindings
    raw_bindings=$(run_user_gsettings get org.gnome.settings-daemon.plugins.media-keys custom-keybindings 2>/dev/null || echo "[]")

    local paths=()
    while IFS= read -r p; do
        [ -n "$p" ] && paths+=("$p")
    done < <(echo "$raw_bindings" | grep -o "'[^']*'" | tr -d "'")

    local found_cb=false
    local found_alt=false
    local found_emoji=false

    for p in "${paths[@]}"; do
        local schema="org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$p"
        local cmd
        cmd=$(run_user_gsettings get "$schema" command 2>/dev/null || true)
        local bind
        bind=$(run_user_gsettings get "$schema" binding 2>/dev/null || true)

        cmd=$(echo "$cmd" | sed "s/^'//;s/'$//")
        bind=$(echo "$bind" | sed "s/^'//;s/'$//")

        if [[ "$p" == *"win11-clipboard-history-emoji"* ]] || [[ "$cmd" == *"--emoji"* ]] || [[ "$bind" == "<Super>period" ]]; then
            run_user_gsettings set "$schema" name "'Win11Clip Emoji Picker'" 2>/dev/null || true
            run_user_gsettings set "$schema" command "'$target_emoji_cmd'" 2>/dev/null || true
            run_user_gsettings set "$schema" binding "'<Super>period'" 2>/dev/null || true
            found_emoji=true
        elif [[ "$p" == *"win11-clipboard-history-alt"* ]] || [[ "$bind" == "<Ctrl><Alt>v" || "$bind" == "<Primary><Alt>v" ]]; then
            run_user_gsettings set "$schema" name "'Win11Clip Clipboard History (Alt)'" 2>/dev/null || true
            run_user_gsettings set "$schema" command "'$target_cb_cmd'" 2>/dev/null || true
            run_user_gsettings set "$schema" binding "'<Ctrl><Alt>v'" 2>/dev/null || true
            found_alt=true
        elif [[ "$cmd" == *"win11-clipboard-history"* ]] || [[ "$bind" == "<Super>v" ]] || [[ "$p" == *"win11-clipboard-history"* ]]; then
            run_user_gsettings set "$schema" name "'Win11Clip Clipboard History'" 2>/dev/null || true
            run_user_gsettings set "$schema" command "'$target_cb_cmd'" 2>/dev/null || true
            run_user_gsettings set "$schema" binding "'<Super>v'" 2>/dev/null || true
            found_cb=true
        fi
    done

    local default_cb_path="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/win11-clipboard-history/"
    local default_alt_path="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/win11-clipboard-history-alt/"
    local default_emoji_path="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/win11-clipboard-history-emoji/"

    if [ "$found_cb" = false ]; then
        local schema="org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$default_cb_path"
        run_user_gsettings set "$schema" name "'Win11Clip Clipboard History'" 2>/dev/null || true
        run_user_gsettings set "$schema" command "'$target_cb_cmd'" 2>/dev/null || true
        run_user_gsettings set "$schema" binding "'<Super>v'" 2>/dev/null || true
        if [[ ! " ${paths[*]} " =~ " $default_cb_path " ]]; then
            paths+=("$default_cb_path")
        fi
    fi

    if [ "$found_alt" = false ]; then
        local schema="org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$default_alt_path"
        run_user_gsettings set "$schema" name "'Win11Clip Clipboard History (Alt)'" 2>/dev/null || true
        run_user_gsettings set "$schema" command "'$target_cb_cmd'" 2>/dev/null || true
        run_user_gsettings set "$schema" binding "'<Ctrl><Alt>v'" 2>/dev/null || true
        if [[ ! " ${paths[*]} " =~ " $default_alt_path " ]]; then
            paths+=("$default_alt_path")
        fi
    fi

    if [ "$found_emoji" = false ]; then
        local schema="org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$default_emoji_path"
        run_user_gsettings set "$schema" name "'Win11Clip Emoji Picker'" 2>/dev/null || true
        run_user_gsettings set "$schema" command "'$target_emoji_cmd'" 2>/dev/null || true
        run_user_gsettings set "$schema" binding "'<Super>period'" 2>/dev/null || true
        if [[ ! " ${paths[*]} " =~ " $default_emoji_path " ]]; then
            paths+=("$default_emoji_path")
        fi
    fi

    local formatted_array="["
    for i in "${!paths[@]}"; do
        formatted_array+="'${paths[$i]}'"
        if [ "$i" -lt $((${#paths[@]} - 1)) ]; then
            formatted_array+=", "
        fi
    done
    formatted_array+="]"

    run_user_gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings "$formatted_array" 2>/dev/null || true
    success "Configured GNOME custom shortcuts (Super+V, Ctrl+Alt+V & Super+.)"
}

# Prints the "shell-version" entries of the extension in directory $1 (space separated).
extension_shell_versions() {
    local f="$1/metadata.json"
    [ -f "$f" ] || return 0
    tr -d '\n' < "$f" | sed -n 's/.*"shell-version"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p' | tr -d '" ' | tr ',' ' '
}

# Warns plainly for every extension whose metadata does not list the running GNOME Shell: GNOME
# marks such an extension OUT OF DATE and never loads it, however often you log in.
check_extension_shell_versions() {
    command -v gnome-shell >/dev/null 2>&1 || return 0
    local major
    major=$(gnome-shell --version 2>/dev/null | sed -n 's/^GNOME Shell \([0-9][0-9]*\).*/\1/p')
    [ -n "$major" ] || return 0

    local ext_root="$HOME/.local/share/gnome-shell/extensions" bad=0 uuid dir versions v ok
    for uuid in win11-clipboard-bridge@harshp2008.github.com window-calls@domandoman.xyz spawn-at@harsh.local; do
        dir="$ext_root/$uuid"
        [ -d "$dir" ] || dir="/usr/share/gnome-shell/extensions/$uuid"
        if [ ! -d "$dir" ]; then
            warn "The GNOME extension $uuid is not installed, so part of Win11Clip will not work."
            bad=1; continue
        fi
        versions=$(extension_shell_versions "$dir")
        ok=false
        for v in $versions; do
            if [ "$v" = "$major" ] || [ "${v%%.*}" = "$major" ]; then ok=true; fi
        done
        if [ "$ok" != true ]; then
            warn "$uuid only lists GNOME Shell ${versions:-(nothing)}, but this is GNOME Shell $major."
            warn "  GNOME will mark it OUT OF DATE and will not load it, even after logging in again. Update Win11Clip or ask the extension's author to add $major."
            bad=1
        fi
    done
    [ "$bad" -eq 0 ] && success "All three GNOME extensions list GNOME Shell $major."
    return 0
}

setup_post_login_enable() {
    if ! command -v gnome-shell &>/dev/null; then
        return 0
    fi
    
    log "Setting up the first-login check for the GNOME extensions..."
    local AUTOSTART_DIR="$HOME/.config/autostart"
    local DESKTOP_FILE="$AUTOSTART_DIR/win11clip-firstrun.desktop"
    
    mkdir -p "$AUTOSTART_DIR" "$(dirname "$FIRSTRUN_SCRIPT")"

    # The script enables the extensions, starts the app, waits for spawn-at's login update to finish
    # (it may rewrite the extension after the Shell loaded it), and then says in plain English whether
    # everything is really loaded. It keeps itself for up to 3 logins while something is still wrong.
    cat > "$FIRSTRUN_SCRIPT" << 'EOF'
#!/bin/sh
# First-login check written by Win11Clip's install.sh. "--check-only" skips enabling, starting the
# app and waiting, and prints notifications instead of showing them (for testing).
STATE_DIR="$HOME/.local/state/win11clip-installer"
LOG="$STATE_DIR/firstrun.log"
TRIES="$STATE_DIR/firstrun.tries"
HOOK="$HOME/.config/autostart/win11clip-firstrun.desktop"
UUIDS="win11-clipboard-bridge@harshp2008.github.com window-calls@domandoman.xyz spawn-at@harsh.local"
SPAWN_AT_MIN_PROTOCOL=7
CHECK_ONLY=0; [ "$1" = "--check-only" ] && CHECK_ONLY=1
mkdir -p "$STATE_DIR"

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }
notify() { # urgency title body
    log "[$1] $2 - $3"
    if [ "$CHECK_ONLY" = 1 ]; then echo "NOTIFY[$1] $2 - $3"; return; fi
    command -v notify-send >/dev/null 2>&1 && notify-send -u "$1" -a "Clipboard History" -i win11-clipboard-history "$2" "$3"
}

if [ "$CHECK_ONLY" = 0 ]; then
    sleep 3
    for u in $UUIDS; do gnome-extensions enable "$u" >/dev/null 2>&1; done
    (win11-clipboard-history >/dev/null 2>&1 &)
    # spawn-at's own login update (10 s after login) and the app's startup update may rewrite the
    # spawn-at extension after the Shell has loaded it; judge only once they are done (at most ~70 s).
    sleep 12
    i=0
    while pgrep -u "$(id -u)" -f 'spawn-at update' >/dev/null 2>&1 && [ "$i" -lt 30 ]; do sleep 2; i=$((i + 1)); done
    sleep 2
fi

problems=""
add() { problems="$problems
 - $1"; }

for u in $UUIDS; do
    case "$u" in
        win11-clipboard-bridge*) name="the Win11Clip GNOME bridge" ;;
        window-calls*) name="window-calls" ;;
        *) name="spawn-at" ;;
    esac
    state=$(gnome-extensions info "$u" 2>/dev/null | sed -n 's/^ *State: *//p')
    case "$state" in
        ACTIVE) ;;
        "") add "GNOME does not know $name at all (not installed?)" ;;
        "OUT OF DATE") add "GNOME says $name is OUT OF DATE for this GNOME Shell" ;;
        ERROR) add "$name failed to load (ERROR)" ;;
        *) add "$name is not running (state: $state)" ;;
    esac
done

proto=$(gdbus call --session --dest org.gnome.Shell --object-path /org/gnome/Shell/Extensions/SpawnAt \
    --method org.freedesktop.DBus.Properties.Get org.gnome.Shell.Extensions.SpawnAt ProtocolVersion 2>/dev/null \
    | sed -n 's/.*uint32 \([0-9][0-9]*\).*/\1/p')
if [ -z "$proto" ]; then
    add "the spawn-at extension is not answering, so the popup cannot be placed at your cursor"
elif [ "$proto" -lt "$SPAWN_AT_MIN_PROTOCOL" ]; then
    add "an older spawn-at extension (protocol $proto, need $SPAWN_AT_MIN_PROTOCOL) is still loaded in this session"
fi

if [ -z "$problems" ]; then
    notify normal "Clipboard History is ready" "All GNOME extensions are loaded. Press Super+V to open it."
    [ "$CHECK_ONLY" = 0 ] && rm -f "$HOOK" "$TRIES"
else
    n=$(cat "$TRIES" 2>/dev/null || echo 0); n=$((n + 1))
    [ "$CHECK_ONLY" = 0 ] && echo "$n" > "$TRIES"
    notify critical "Clipboard History: log out and back in once more" "GNOME has not loaded everything yet:$problems
Log out and back in once more, then press Super+V. Details: $LOG"
    [ "$CHECK_ONLY" = 0 ] && [ "$n" -ge 3 ] && rm -f "$HOOK" "$TRIES" && log "Giving up the first-login check after $n tries."
fi
exit 0
EOF
    chmod +x "$FIRSTRUN_SCRIPT"

    cat > "$DESKTOP_FILE" << EOF
[Desktop Entry]
Type=Application
Name=Win11Clip First-Run Setup
Exec=$FIRSTRUN_SCRIPT
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
EOF
    
    chmod +x "$DESKTOP_FILE"
    success "First-login check created at $DESKTOP_FILE"
}

check_if_restart_required() {
    # If not on GNOME, no restart is needed for extensions
    local is_gnome=false
    if [[ "$XDG_CURRENT_DESKTOP" =~ [Gg][Nn][Oo][Mm][Ee] ]] || command -v gnome-shell >/dev/null 2>&1; then
        is_gnome=true
    fi

    if [ "$is_gnome" = false ]; then
        RESTART_NEEDED=0
        return
    fi
    
    if ! command -v gnome-extensions >/dev/null 2>&1; then
        RESTART_NEEDED=1
        return
    fi

    # 1. Flag fresh installs / modifications directly:
    # If window-calls or any extension was newly installed or updated during this script run,
    # or RESTART_NEEDED was already asserted, GNOME Shell MUST restart session
    # to load the new extension methods (such as GetCoordinates) into memory.
    if [ "${RESTART_NEEDED:-0}" -eq 1 ] || [ "${EXTENSIONS_MODIFIED:-0}" -eq 1 ]; then
        RESTART_NEEDED=1
        return
    fi

    local exts=(
        "win11-clipboard-bridge@harshp2008.github.com"
        "window-calls@domandoman.xyz"
        "spawn-at@harsh.local"
    )
    
    for ext in "${exts[@]}"; do
        # Try enabling via D-Bus
        gnome-extensions enable "$ext" 2>/dev/null || true

        # Enabled is not enough: an extension GNOME marked OUT OF DATE is still on the enabled list.
        # It has to be running (State: ACTIVE) in the current session.
        if ! gnome-extensions list --enabled 2>/dev/null | grep -q "^${ext}$" \
           || ! gnome-extensions info "$ext" 2>/dev/null | grep -Eq '^ *State: *ACTIVE'; then
            RESTART_NEEDED=1
            return
        fi
    done
}

# Main
main() {
    EXTENSIONS_MODIFIED=0

    echo ""
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║     Win11 Clipboard History - Linux Installer             ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo ""
    
    trap cleanup EXIT

    command -v curl >/dev/null 2>&1 || error "curl is required. Install it with: sudo apt install curl (then re-run)."
    
    detect_distro
    detect_arch
    log "Detected: $DISTRO_ID (Family: $SYSTEM_FAMILY_INFO)"

    if [ "$DRY_RUN" = true ]; then
        print_plan
        exit 0
    fi
    
    # Check WebKitGTK compatibility
    check_webkit_compatibility
    webkit_status=$?

    # The default path installs the prebuilt release. Without a usable one (not published yet,
    # older than the fixes, offline), say so plainly and build from source instead.
    if [ "$BUILD_FROM_SOURCE" != true ] && ! [[ "$SYSTEM_FAMILY_INFO" =~ arch ]]; then
        local gate_ext="deb"
        [[ "$SYSTEM_FAMILY_INFO" =~ (fedora|rhel|centos|suse) ]] && gate_ext="rpm"
        [ "$webkit_status" -eq 1 ] && gate_ext="AppImage"
        if ! release_is_usable "$gate_ext"; then
            warn "No usable prebuilt release: $RELEASE_PROBLEM."
            warn "Falling back to building from source. This installs build tools (system libraries via apt,"
            warn "Node.js via nvm and Rust via rustup in your home folder, no sudo for those) and takes several minutes."
            if [ -r /dev/tty ]; then
                local reply=""
                read -r -p "Build from source now? [Y/n] " reply < /dev/tty || true
                [[ "$reply" =~ ^[Nn] ]] && error "Cancelled. Re-run later, or run: $0 --dry-run to see the plan."
            else
                log "Continuing in 5 seconds (Ctrl+C to cancel)..."
                sleep 5
            fi
            BUILD_FROM_SOURCE=true
        fi
    fi
    
    if [ "$BUILD_FROM_SOURCE" = true ]; then
        build_from_source
    elif [ "$webkit_status" -eq 1 ]; then
        warn "Legacy WebKitGTK detected. Preferring AppImage for better compatibility."
        install_appimage || build_from_source
    elif install_via_package_manager; then
        success "Package installation complete!"
    else
        warn "No native package found for your system family. Trying AppImage..."
        install_appimage || build_from_source
    fi
    
    # Install spawn-at utility globally
    install_spawn_at
    
    # Install uninstaller globally
    install_uninstaller
    
    # Configure GNOME custom shortcuts (Super+V & Super+.)
    configure_gnome_shortcuts
    
    # Configure GNOME Shell extensions if applicable
    install_gnome_extensions

    # Warn if GNOME would refuse to load any of them on this Shell version
    check_extension_shell_versions
    
    # Check if a restart is genuinely needed
    check_if_restart_required
    
    if [ "$RESTART_NEEDED" -eq 1 ]; then
        # Set up one-time autostart hook for GNOME extensions
        setup_post_login_enable

        echo -e "\n${BLUE}┌──────────────────────────────────────────────────────────────┐${NC}"
        echo -e "${BLUE}│${NC}  ${GREEN}✓ Installation Complete!${NC}                                    ${BLUE}│${NC}"
        echo -e "${BLUE}│${NC}  GNOME Shell requires a fresh session to index extensions.   ${BLUE}│${NC}"
        echo -e "${BLUE}└──────────────────────────────────────────────────────────────┘${NC}\n"

        interactive_session_prompt
    else
        # No restart needed, enable extensions live if on GNOME
        if [[ "$XDG_CURRENT_DESKTOP" == *"GNOME"* ]] && command -v gnome-extensions >/dev/null 2>&1; then
            gnome-extensions enable win11-clipboard-bridge@harshp2008.github.com 2>/dev/null || true
            gnome-extensions enable window-calls@domandoman.xyz 2>/dev/null || true
            gnome-extensions enable spawn-at@harsh.local 2>/dev/null || true
        fi
        
        # Clean up any previous firstrun hook just in case
        rm -f "$HOME/.config/autostart/win11clip-firstrun.desktop"

        echo -e "\n${BLUE}┌──────────────────────────────────────────────────────────────┐${NC}"
        echo -e "${BLUE}│${NC}  ${GREEN}✓ Installation Complete!${NC}                                    ${BLUE}│${NC}"
        echo -e "${BLUE}│${NC}  All components are active. Press Super+V to open Win11Clip. ${BLUE}│${NC}"
        echo -e "${BLUE}└──────────────────────────────────────────────────────────────┘${NC}\n"
        
        # Launch app directly
        launch_app >/dev/null 2>&1 || true
    fi
}

interactive_session_prompt() {
    local options=(
        "Log Out Now (Recommended)"
        "Reboot System"
        "I will restart my session later"
    )
    local selected=0
    local key=""

    # Ensure input is read from /dev/tty if stdin is piped (e.g. curl | bash)
    local tty_in=""
    if [ -r /dev/tty ]; then
        exec 3</dev/tty
        tty_in=3
    elif [ ! -t 0 ]; then
        echo -e "${C_YELLOW}[!] Non-interactive session. Please restart your session or log out to activate extensions.${C_RESET}"
        return 0
    fi

    # 1. Print the header ONCE outside the loop
    echo -e "${C_BOLD}Would you like to restart your session now?${C_RESET} ${C_DIM}(Use arrow keys or 1-3)${C_RESET}"
    echo ""

    # Hide cursor
    printf "\033[?25l"
    trap 'printf "\033[?25h"; echo ""; exit 1' INT TERM

    while true; do
        # 2. Print ONLY the options
        for i in "${!options[@]}"; do
            if [ "$i" -eq "$selected" ]; then
                echo -e "\033[K  ${C_CYAN}${C_BOLD}❯ ${options[$i]}${C_RESET}"
            else
                echo -e "\033[K  ${C_DIM}  ${options[$i]}${C_RESET}"
            fi
        done

        # Read user input
        key=""
        IFS= read -u "${tty_in:-0}" -rsn1 key || true
        if [[ $key == $'\x1b' ]]; then
            # An escape sequence was started; read next 2 characters without timeout races
            read -u "${tty_in:-0}" -rsn2 -t 0.1 key 2>/dev/null || true
            case "$key" in
                '[A'|'OA') # Up arrow
                    selected=$(( (selected - 1 + ${#options[@]}) % ${#options[@]} ))
                    ;;
                '[B'|'OB') # Down arrow
                    selected=$(( (selected + 1) % ${#options[@]} ))
                    ;;
            esac
        elif [[ $key == "" ]]; then
            # Enter key pressed
            break
        elif [[ $key == "1" ]]; then
            selected=0; break
        elif [[ $key == "2" ]]; then
            selected=1; break
        elif [[ $key == "3" ]]; then
            selected=2; break
        elif [[ $key == "q" || $key == "Q" ]]; then
            # Allow clean quit
            selected=2; break
        fi

        # Move cursor back up exactly by the number of options printed
        printf "\033[%dA" "${#options[@]}"
    done

    [ -n "$tty_in" ] && exec 3<&-

    # Restore cursor
    printf "\033[?25h"
    echo ""

    case "$selected" in
        0)
            echo -e "${C_GREEN}[*] Logging out of GNOME session...${C_RESET}"
            gnome-session-quit --logout --no-prompt 2>/dev/null || pkill -KILL -u "$USER"
            ;;
        1)
            echo -e "${C_GREEN}[*] Rebooting system...${C_RESET}"
            systemctl reboot 2>/dev/null || sudo reboot
            ;;
        2)
            echo -e "${C_YELLOW}[!] Remember to log out and back in before using Win11Clip (Super+V).${C_RESET}"
            ;;
    esac
}

main "$@"
