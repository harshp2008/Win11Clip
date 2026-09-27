<div align="center">
  <img width="64" height="64" alt="Win11Clip Logo" src="https://github.com/user-attachments/assets/4534e915-5d83-45f3-9f09-48a0f94b1d9a" />

  # Win11Clip

  **The aesthetic Windows 11 clipboard manager for Linux — fully hardened for modern Wayland & cursor positioning.**

  [![License](https://img.shields.io/badge/License-MIT-blue.svg?style=for-the-badge)](LICENSE)
  [![Tauri](https://img.shields.io/badge/Built_With-Tauri_v2-24C8D6?style=for-the-badge&logo=tauri&logoColor=white)](https://tauri.app/)
  [![Rust](https://img.shields.io/badge/Powered_By-Rust-000000?style=for-the-badge&logo=rust&logoColor=white)](https://www.rust-lang.org/)

  ![App Screenshot](https://github.com/user-attachments/assets/74400c8b-9d7d-49ce-8de7-45dfd556e256)
</div>

---

> [!NOTE]
> **Win11Clip** is an independent, hardened evolution of [gustavosett/Windows-11-Clipboard-History-For-Linux](https://github.com/gustavosett/Windows-11-Clipboard-History-For-Linux). It was rebuilt to eliminate Wayland positioning failures, fix window focus lockouts, upgrade to WebKitGTK 4.1, and deliver genuine mouse-pointer flyout behavior across modern Linux distributions.

---

## 🌟 Why Win11Clip?

Most Linux clipboard managers either fall back to centering on screen, break entirely under pure Wayland, or run into Mutter's Focus Stealing Prevention (FSP). **Win11Clip** solves these platform boundaries directly at the compositor and shell bridge level.

| Feature | Details |
| :--- | :--- |
| **🎯 Native Cursor Snapping** | Spawns precisely adjacent to your active mouse cursor across multiple monitors instead of defaulting to screen center. |
| **🛡️ Focus Stealing Bypass** | Communicates with GNOME Shell over D-Bus to prevent Mutter focus toasts ("Window is ready") and capture keyboard focus instantly. |
| **📌 Pinned Items** | Keep critical code snippets, tokens, and templates pinned permanently at the top. |
| **🤩 Searchable Emoji Picker** | Full emoji keyboard with direct paste integration. |
| **📦 Modern WebKitGTK 4.1** | Native support for Ubuntu 24.04+ (Noble Numbat), modern Fedora, and rolling distributions without legacy WebKitGTK 4.0 breakage. |
| **🔒 Local & Private** | Zero network analytics. All clipboard history remains stored locally on your machine. |

---

## ⚡ Quick Start (Recommended)

### One-Line Quick Install

Run the automated installer to detect your distribution, install or build the application, configure shortcuts, deploy cursor positioning utilities, and register GNOME Shell extensions:

```bash
curl -fsSL https://raw.githubusercontent.com/harshp2008/Win11Clip/master/scripts/install.sh | bash
```

### Or Build / Run from Source

```bash
git clone https://github.com/harshp2008/Win11Clip.git
cd Win11Clip
./scripts/install.sh
```

To force a local build from source during installation:

```bash
./scripts/install.sh --build
```

---

## 🧩 Wayland & GNOME Cursor Positioning

Under Wayland, security isolation prevents regular applications from reading global cursor coordinates or moving windows arbitrarily. Win11Clip achieves seamless, sub-pixel cursor positioning on GNOME Wayland via two tightly integrated components:

1. **`spawn-at` CLI Utility:** Queries the mouse position and window coordinates directly via D-Bus, calculates monitor bounds and display offsets, and moves the Win11Clip window dynamically.
2. **Patched `window-calls` Extension:** Bundles a hardened version of `window-calls@domandoman.xyz` enhanced with a custom `GetCoordinates` D-Bus endpoint to retrieve pointer positions and monitor geometry safely inside Mutter.

> [!IMPORTANT]
> **Post-Install Session Restart:**  
> When installing on **GNOME Wayland for the first time**, you must **log out and log back in** (or restart your session). GNOME Shell only initializes newly installed extension D-Bus interfaces upon starting a fresh user session.

---

## ⌨️ Shortcuts & Safe Registration

Win11Clip registers custom global shortcuts directly with your desktop environment without overwriting your existing hotkeys:

| Shortcut | Action | Description |
| :--- | :--- | :--- |
| <kbd>Super</kbd> + <kbd>V</kbd> | **Clipboard History** | Opens the clipboard history flyout at the mouse pointer. |
| <kbd>Super</kbd> + <kbd>.</kbd> | **Emoji Picker** | Opens the searchable emoji picker flyout at the mouse pointer. |
| <kbd>Enter</kbd> | **Paste Item** | Pastes the selected clipboard item or emoji into the active window. |
| <kbd>Esc</kbd> | **Close** | Closes the flyout immediately. |

### Safe Shortcut Conflict Resolution
On GNOME, `<Super>v` is bound by default to `focus-active-notification` (Message Tray). Win11Clip detects this conflict and **safely reassigns** the collision without destroying any other user shortcuts.

### Manual Keybinding Setup (If Needed)
If you are running a standalone window manager (Sway, Hyprland, i3, etc.) or prefer manual configuration:
- **Clipboard History:** `spawn-at -o -15 -15 -b win11-clipboard-history --clipboard`
- **Emoji Picker:** `spawn-at -o -15 -15 -b win11-clipboard-history --emoji`

---

## 🗑️ Uninstallation

Win11Clip includes a clean uninstaller that removes binaries, desktop integration, custom GNOME shortcuts, and offers an interactive prompt to cleanly keep or remove companion extensions.

### From Terminal (Anytime)
```bash
win11-clipboard-uninstall
```

### Or One-Line Remote Uninstall
```bash
curl -fsSL https://raw.githubusercontent.com/harshp2008/Win11Clip/master/scripts/uninstall.sh | bash
```

---

## 📦 Packages & Distribution Binaries

Pre-compiled packages for each release are available on the [Releases](https://github.com/harshp2008/Win11Clip/releases) page.

### Debian / Ubuntu (.deb)
```bash
sudo dpkg -i win11-clipboard-history_*.deb
sudo apt install -f -y
sudo setfacl -m u:$USER:rw /dev/uinput
```

### Fedora / RHEL (.rpm)
```bash
sudo dnf install ./win11-clipboard-history-*.rpm
sudo setfacl -m u:$USER:rw /dev/uinput
```

### AppImage
```bash
chmod +x win11-clipboard-history_*.AppImage
sudo setfacl -m u:$USER:rw /dev/uinput
./win11-clipboard-history_*.AppImage --clipboard
```

---

## 🔧 Troubleshooting

- **Flyout Spawning at Screen Center:** Ensure the GNOME Shell session was restarted after initial install so Mutter loads `window-calls` and `win11-clipboard-bridge`. Test with:
  ```bash
  gdbus call --session --dest org.gnome.Shell --object-path /org/gnome/Shell/Extensions/Windows --method org.gnome.Shell.Extensions.Windows.GetCoordinates
  ```
- **Window Focus on Wayland:** If focus is not captured immediately:
  ```bash
  gnome-extensions enable win11-clipboard-bridge@harshp2008.github.com
  gnome-extensions enable window-calls@domandoman.xyz
  ```
- **NVIDIA / Transparency Issues:** Run with the hardware acceleration workaround flag:
  ```bash
  IS_NVIDIA=1 win11-clipboard-history --clipboard
  ```

---

## 🛠️ Development

Requirements: Rust toolchain, Node.js, `libwebkit2gtk-4.1-dev`, `libgtk-3-dev`, and `libxdo-dev`.

```bash
# 1. Clone repository
git clone https://github.com/harshp2008/Win11Clip.git
cd Win11Clip

# 2. Install dependencies & configure environment
make deps && make rust && make node
source ~/.cargo/env

# 3. Launch live development environment
make dev
```

---

## 📜 Credits & License

- **Core Base & Visual Concept:** Originates from [gustavosett/Windows-11-Clipboard-History-For-Linux](https://github.com/gustavosett/Windows-11-Clipboard-History-For-Linux) under the MIT License.
- **Wayland Hardening, Spawn-At Positioning & WebKitGTK 4.1 Migration:** [Harsh P. (harshp2008)](https://github.com/harshp2008).
- **License:** [MIT License](LICENSE)
