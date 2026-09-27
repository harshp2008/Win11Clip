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
CLOUDSMITH_REPO="gustavosett/clipboard-manager"

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
    
    if [ -f "./src-tauri/target/release/win11-clipboard-history-bin" ]; then
        log "Local compiled binary found. Installing locally..."
        sudo cp "./src-tauri/target/release/win11-clipboard-history-bin" "/usr/bin/win11-clipboard-history"
        sudo chmod +x "/usr/bin/win11-clipboard-history"
        success "Installed local binary to /usr/bin/"
        return 0
    fi

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
    log "Setting up APT repository (Cloudsmith)..."
    
    # Install prerequisites for HTTPS repos
    sudo apt-get update -qq
    sudo apt-get install -y apt-transport-https curl || true
    
    # Try Cloudsmith repository first (enables auto-updates)
    if curl -1sLf "https://dl.cloudsmith.io/public/${CLOUDSMITH_REPO}/setup.deb.sh" | sudo -E bash 2>/dev/null; then
        log "Installing win11-clipboard-history from repository..."
        sudo apt-get update -qq
        if sudo apt-get install -y win11-clipboard-history; then
            success "Installed via APT repository! (auto-updates enabled)"
            return 0
        fi
    fi
    
    # Fallback: download from GitHub releases
    warn "Repository not available, falling back to GitHub release..."
    log "Installing from GitHub releases (.deb)..."
    
    LATEST_RELEASE_URL="https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/releases/latest"
    RELEASE_DATA=$(curl -s "$LATEST_RELEASE_URL")
    RELEASE_TAG=$(echo "$RELEASE_DATA" | grep '"tag_name":' | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/' | tr -cd '[:alnum:]._-')
    [ -z "$RELEASE_TAG" ] && error "Failed to fetch version."
    CLEAN_VERSION="${RELEASE_TAG#v}"
    
    TEMP_DIR=$(mktemp -d)
    chmod 755 "$TEMP_DIR"
    cd "$TEMP_DIR"
    trap 'rm -rf "$TEMP_DIR"' EXIT
    
    FILE_URL=$(echo "$RELEASE_DATA" | grep "browser_download_url.*\.deb" | grep -i "${DEB_ARCH}" | head -1 | cut -d '"' -f 4)
    if [ -n "$FILE_URL" ]; then
        FILE=$(basename "$FILE_URL")
    else
        FILE="win11-clipboard-history_${CLEAN_VERSION}_${DEB_ARCH}.deb"
        FILE_URL="https://github.com/$REPO_OWNER/$REPO_NAME/releases/download/$RELEASE_TAG/$FILE"
    fi
    
    log "Downloading $FILE..."
    if ! curl -L -o "$FILE" "$FILE_URL" --progress-bar --fail; then
        error "Failed to download $FILE"
    fi
    chmod 644 "$FILE"
    
    log "Installing dependencies..."
    sudo apt-get install -y xclip wl-clipboard acl python3-gi gir1.2-gtk-3.0 || true
    sudo apt-get install -y libayatana-appindicator3-1 || sudo apt-get install -y libappindicator3-1 || true
    
    log "Installing .deb package..."
    yes | sudo apt-get install -y "./$FILE"
    
    success "Installed via APT (from GitHub release)"
}

install_rpm() {
    log "Setting up RPM repository (Cloudsmith)..."
    
    local env_args=()
    if [[ "$DISTRO_ID" == "fedora-asahi-remix" ]]; then
        log "Detected Fedora Asahi Remix - using standard Fedora repository..."
        local fedora_version=""
        if [ -f /etc/os-release ]; then
            fedora_version="$(awk -F= '$1=="VERSION_ID"{gsub(/"/,"",$2);print $2}' /etc/os-release)"
        fi
        env_args=("distro=fedora" "codename=")
        if [[ -n "$fedora_version" ]]; then
            env_args+=("version=$fedora_version")
        fi
    fi
    
    # Try Cloudsmith repository first (enables auto-updates)
    local repo_setup_success=false
    if [[ ${#env_args[@]} -gt 0 ]]; then
        # Export the override vars so they survive through sudo -E inside the
        # Cloudsmith setup script (env + bash -c loses them at the sudo boundary).
        for _evar in "${env_args[@]}"; do
            export "${_evar?}"
        done
        curl -1sLf "https://dl.cloudsmith.io/public/${CLOUDSMITH_REPO}/setup.rpm.sh" | sudo -E bash 2>/dev/null && repo_setup_success=true
        # Clean up exported overrides
        unset distro version codename 2>/dev/null || true
    else
        curl -1sLf "https://dl.cloudsmith.io/public/${CLOUDSMITH_REPO}/setup.rpm.sh" | sudo -E bash 2>/dev/null && repo_setup_success=true
    fi
    
    if [ "$repo_setup_success" = true ]; then
        log "Installing win11-clipboard-history from repository..."
        if sudo dnf install -y win11-clipboard-history; then
            success "Installed via DNF repository! (auto-updates enabled)"
            return 0
        fi
    fi
    
    # Fallback: download from GitHub releases
    warn "Repository not available, falling back to GitHub release..."
    log "Installing from GitHub releases (.rpm)..."
    
    LATEST_RELEASE_URL="https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/releases/latest"
    RELEASE_DATA=$(curl -s "$LATEST_RELEASE_URL")
    RELEASE_TAG=$(echo "$RELEASE_DATA" | grep '"tag_name":' | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/' | tr -cd '[:alnum:]._-')
    [ -z "$RELEASE_TAG" ] && error "Failed to fetch version."
    CLEAN_VERSION="${RELEASE_TAG#v}"
    
    TEMP_DIR=$(mktemp -d)
    chmod 755 "$TEMP_DIR"
    cd "$TEMP_DIR"
    trap 'rm -rf "$TEMP_DIR"' EXIT
    
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
    log "Setting up RPM repository (Cloudsmith)..."
    
    # Try Cloudsmith repository first (enables auto-updates)
    if curl -1sLf "https://dl.cloudsmith.io/public/${CLOUDSMITH_REPO}/setup.rpm.sh" | sudo -E bash 2>/dev/null; then
        log "Installing win11-clipboard-history from repository..."
        if sudo zypper install -y win11-clipboard-history; then
            success "Installed via Zypper repository! (auto-updates enabled)"
            return 0
        fi
    fi
    
    # Fallback: download from GitHub releases
    warn "Repository not available, falling back to GitHub release..."
    log "Installing from GitHub releases (.rpm)..."
    
    LATEST_RELEASE_URL="https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/releases/latest"
    RELEASE_DATA=$(curl -s "$LATEST_RELEASE_URL")
    RELEASE_TAG=$(echo "$RELEASE_DATA" | grep '"tag_name":' | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/' | tr -cd '[:alnum:]._-')
    [ -z "$RELEASE_TAG" ] && error "Failed to fetch version."
    CLEAN_VERSION="${RELEASE_TAG#v}"
    
    TEMP_DIR=$(mktemp -d)
    chmod 755 "$TEMP_DIR"
    cd "$TEMP_DIR"
    trap 'rm -rf "$TEMP_DIR"' EXIT
    
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


BUILD_FROM_SOURCE=false
for arg in "$@"; do
    if [ "$arg" = "--build" ] || [ "$arg" = "--build-from-source" ]; then
        BUILD_FROM_SOURCE=true
    fi
done

is_pkg_installed() {
    local pkg="$1"
    dpkg -s "$pkg" >/dev/null 2>&1 || dpkg -s "${pkg}t64" >/dev/null 2>&1
}

check_and_install_deps() {
    local RUNTIME_DEPS=(xclip wl-clipboard acl libgtk-3-0 librsvg2-2)
    local BUILD_DEPS=(build-essential curl wget file pkg-config libssl-dev libgtk-3-dev libayatana-appindicator3-dev librsvg2-dev libxdo-dev libudev-dev)
    local MISSING_DEPS=()
    
    # Ensure apt package list is updated before checking package availability
    sudo apt-get update -qq || true

    local use_webkit_41=false
    if apt-cache show libwebkit2gtk-4.1-dev >/dev/null 2>&1; then
        use_webkit_41=true
    else
        local major_ver="${DISTRO_VERSION_ID%%.*}"
        if [[ "$SYSTEM_FAMILY_INFO" =~ "ubuntu" && "$major_ver" -ge 24 ]] 2>/dev/null; then
            use_webkit_41=true
        elif [[ "$SYSTEM_FAMILY_INFO" =~ "debian" && "$major_ver" -ge 12 ]] 2>/dev/null; then
            use_webkit_41=true
        fi
    fi

    if [ "$use_webkit_41" = true ]; then
        BUILD_DEPS+=(libwebkit2gtk-4.1-dev)
        RUNTIME_DEPS+=(libwebkit2gtk-4.1-0)
    else
        BUILD_DEPS+=(libwebkit2gtk-4.0-dev)
        RUNTIME_DEPS+=(libwebkit2gtk-4.0-37)
    fi
    
    for dep in "${RUNTIME_DEPS[@]}" "${BUILD_DEPS[@]}"; do
        if ! is_pkg_installed "$dep"; then
            MISSING_DEPS+=("$dep")
        fi
    done

    if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
        log "Missing dependencies detected: ${MISSING_DEPS[*]}"
        log "Installing via apt-get..."
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${MISSING_DEPS[@]}"
    else
        success "All apt dependencies are satisfied."
    fi
}

install_node_rust_cargo() {
    if ! command -v curl >/dev/null 2>&1; then
        sudo apt-get install -y curl
    fi

    if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
        warn "Node.js or npm is missing."
        echo "Run the following commands to install Node.js (v20):"
        echo "  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -"
        echo "  sudo apt-get install -y nodejs"
        if [ "$DEBIAN_FRONTEND" = "noninteractive" ] || [ ! -t 0 ]; then
            log "Non-interactive environment detected, attempting auto-install of Node.js..."
            curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
            sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
        else
            error "Please install Node.js to build from source."
        fi
    fi

    if ! command -v cargo >/dev/null 2>&1; then
        warn "Rust/Cargo is missing."
        echo "Run the following command to install Rust:"
        echo "  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y"
        echo "  source \$HOME/.cargo/env"
        if [ "$DEBIAN_FRONTEND" = "noninteractive" ] || [ ! -t 0 ]; then
            log "Non-interactive environment detected, attempting auto-install of Rust..."
            curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
            export PATH="$HOME/.cargo/bin:$PATH"
        else
            error "Please install Rust to build from source."
        fi
    fi
}

build_from_source() {
    log "Starting build from source..."
    check_and_install_deps
    install_node_rust_cargo
    
    [ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env"
    
    log "Installing npm dependencies..."
    npm install
    
    log "Building the Tauri application..."
    npm run tauri:build
    
    log "Installing system-wide..."
    sudo env "PATH=$PATH" make install PREFIX=/usr/local
    
    success "Build and install from source completed successfully."
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

    # Try to steal focus on Wayland via window-calls
    if [[ "$XDG_SESSION_TYPE" == "wayland" ]] || [[ "$WAYLAND_DISPLAY" != "" ]]; then
        gdbus call --session --dest org.gnome.Shell --object-path /org/gnome/Shell/Extensions/Windows --method org.gnome.Shell.Extensions.Windows.Focus "win11-clipboard-history" 2>/dev/null || true
    fi

    return 0
}

install_spawn_at() {
    log "Installing spawn-at utility..."
    if [ -f "bundled-deps/bin/spawn-at" ]; then
        sudo install -Dm755 bundled-deps/bin/spawn-at /usr/local/bin/spawn-at
    elif [ -f "../bundled-deps/bin/spawn-at" ]; then
        sudo install -Dm755 ../bundled-deps/bin/spawn-at /usr/local/bin/spawn-at
    else
        local fetched=false
        local owners=("$REPO_OWNER" "harshp2008")
        local repos=("$REPO_NAME" "Windows-11-Clipboard-History-For-Linux")
        for owner in "${owners[@]}"; do
            for repo in "${repos[@]}"; do
                local SPAWN_AT_URL="https://raw.githubusercontent.com/$owner/$repo/master/bundled-deps/bin/spawn-at"
                if sudo curl -fsSL -o /usr/local/bin/spawn-at "$SPAWN_AT_URL" 2>/dev/null; then
                    fetched=true
                    break 2
                fi
            done
        done
        if [ "$fetched" = false ]; then
            error "Failed to download spawn-at"
        fi
    fi
    sudo chmod 755 /usr/local/bin/spawn-at
    success "spawn-at installed to /usr/local/bin/spawn-at"
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
            local owners=("$REPO_OWNER" "harshp2008" "gustavosett")
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

    local target_cb_cmd="spawn-at -o -15 -15 -b win11-clipboard-history --clipboard"
    local target_emoji_cmd="spawn-at -o -15 -15 -b win11-clipboard-history --emoji"

    local raw_bindings
    raw_bindings=$(run_user_gsettings get org.gnome.settings-daemon.plugins.media-keys custom-keybindings 2>/dev/null || echo "[]")

    local paths=()
    while IFS= read -r p; do
        [ -n "$p" ] && paths+=("$p")
    done < <(echo "$raw_bindings" | grep -o "'[^']*'" | tr -d "'")

    local found_cb=false
    local found_emoji=false

    for p in "${paths[@]}"; do
        local schema="org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$p"
        local cmd
        cmd=$(run_user_gsettings get "$schema" command 2>/dev/null || true)
        local bind
        bind=$(run_user_gsettings get "$schema" binding 2>/dev/null || true)

        cmd=$(echo "$cmd" | sed "s/^'//;s/'$//")
        bind=$(echo "$bind" | sed "s/^'//;s/'$//")

        if [[ "$cmd" == *"win11-clipboard-history"* ]] || [[ "$bind" == "<Super>v" ]] || [[ "$p" == *"win11-clipboard-history/"* && "$p" != *"emoji"* ]]; then
            if [[ "$cmd" == *"--emoji"* ]] || [[ "$bind" == "<Super>period" ]] || [[ "$p" == *"emoji"* ]]; then
                run_user_gsettings set "$schema" name "'Win11Clip Emoji Picker'" 2>/dev/null || true
                run_user_gsettings set "$schema" command "'$target_emoji_cmd'" 2>/dev/null || true
                run_user_gsettings set "$schema" binding "'<Super>period'" 2>/dev/null || true
                found_emoji=true
            else
                run_user_gsettings set "$schema" name "'Win11Clip Clipboard History'" 2>/dev/null || true
                run_user_gsettings set "$schema" command "'$target_cb_cmd'" 2>/dev/null || true
                run_user_gsettings set "$schema" binding "'<Super>v'" 2>/dev/null || true
                found_cb=true
            fi
        fi
    done

    local default_cb_path="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/win11-clipboard-history/"
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
    success "Configured GNOME custom shortcuts (Super+V & Super+.)"
}

setup_post_login_enable() {
    if ! command -v gnome-shell &>/dev/null; then
        return 0
    fi
    
    log "Setting up one-time first-run autostart hook for GNOME extensions..."
    local AUTOSTART_DIR="$HOME/.config/autostart"
    local DESKTOP_FILE="$AUTOSTART_DIR/win11clip-firstrun.desktop"
    
    mkdir -p "$AUTOSTART_DIR"
    
    cat > "$DESKTOP_FILE" << 'EOF'
[Desktop Entry]
Type=Application
Name=Win11Clip First-Run Setup
Exec=sh -c 'sleep 3 && gnome-extensions enable win11-clipboard-bridge@harshp2008.github.com && gnome-extensions enable window-calls@domandoman.xyz && win11-clipboard-history & sleep 1 && for i in 1 2 3 4 5; do gdbus call --session --dest org.gnome.Shell --object-path /org/gnome/Shell/Extensions/Windows --method org.gnome.Shell.Extensions.Windows.Focus "win11-clipboard-history" 2>/dev/null && break; sleep 0.2; done; rm -f ~/.config/autostart/win11clip-firstrun.desktop'
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
EOF
    
    chmod +x "$DESKTOP_FILE"
    success "First-run autostart hook created at $DESKTOP_FILE"
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
    )
    
    for ext in "${exts[@]}"; do
        # Try enabling via D-Bus
        gnome-extensions enable "$ext" 2>/dev/null || true

        # Verify whether it is actually active in gnome-extensions list --enabled
        if ! gnome-extensions list --enabled 2>/dev/null | grep -q "^${ext}$"; then
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
    
    command -v curl >/dev/null 2>&1 || error "curl is required."
    
    detect_distro
    detect_arch
    log "Detected: $DISTRO_ID (Family: $SYSTEM_FAMILY_INFO)"
    
    # Check WebKitGTK compatibility
    check_webkit_compatibility
    webkit_status=$?
    
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
