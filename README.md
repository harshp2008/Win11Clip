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

The installer needs nothing pre-installed beyond `curl` and `sudo`. By default it installs the prebuilt `.deb` from this repository's latest GitHub release (plus any missing runtime packages via `apt`, asking for `sudo` once). If no usable release exists, or with `--build`, it builds from source: system libraries come from `apt`, while Node.js (nvm) and Rust (rustup) are installed in your home folder without `sudo`, and only if you don't already have them. **Arch Linux is not supported by the installer yet.** On Arch it stops with an explanation and installs nothing; in particular it does not install the AUR package `win11-clipboard-history-bin`, which is maintained by the upstream project and does not contain this project's fixes.

To see exactly what it would do first:

```bash
curl -fsSL https://raw.githubusercontent.com/harshp2008/Win11Clip/master/scripts/install.sh | bash -s -- --dry-run
```

If it finds an older upstream package or apt source of `gustavosett/Windows-11-Clipboard-History-For-Linux`, it explains and asks before removing anything (default No), and saves a copy under `~/.local/state/win11clip-installer/backup`. `uninstall.sh` removes what the installer added, offers to restore anything the installer removed, and asks before touching shared components (`spawn-at`, `window-calls`) or any build tools it installed.

---

## 🧩 Wayland & GNOME Cursor Positioning

Under Wayland, security isolation prevents regular applications from reading global cursor coordinates or moving windows arbitrarily. Win11Clip achieves seamless, sub-pixel cursor positioning on GNOME Wayland via two tightly integrated components:

1. **`spawn-at` CLI Utility (version 0.2.4 or newer):** Queries the mouse position and window coordinates directly via D-Bus, calculates monitor bounds and display offsets, and moves the Win11Clip window dynamically. It comes with its own GNOME Shell extension; both must be 0.2.4 or newer. Older ones can place the popup at a stale position after a shortcut press that found the popup already open (fixed in 0.2.3), and before 0.2.4 a login update that changed the extension said nothing, so you were not told to log out and back in; 0.2.4 sends a notification for that and states honestly which GNOME Shell versions it has been tested on. The installer bundles 0.2.4 (`bundled-deps/VERSIONS` records the checksum), replaces an older `spawn-at`, never downgrades a newer one, and deploys the extension from that same CLI. It keeps **one** copy, in `~/.local/bin/spawn-at`: spawn-at's login updater can only replace the file it runs from, and only a file you own can be replaced without `sudo`, so a second copy in `/usr/local/bin` would be left behind at the old version. The GNOME shortcuts the installer creates run that copy by its full path, so they do not depend on `~/.local/bin` being on the `PATH` your session started with. If an earlier installer left a copy in `/usr/local/bin`, the installer brings it up to date (or tells you the `sudo` command if it cannot), and `uninstall.sh` removes it together with the user copy.
2. **Patched `window-calls` Extension:** Bundles a hardened version of `window-calls@domandoman.xyz` enhanced with a custom `GetCoordinates` D-Bus endpoint to retrieve pointer positions and monitor geometry safely inside Mutter.

> [!IMPORTANT]
> **Post-Install Session Restart:**  
> When installing on **GNOME Wayland for the first time**, you must **log out and log back in** (or restart your session). GNOME Shell only initializes newly installed extension D-Bus interfaces upon starting a fresh user session. The same applies whenever the installer updates one of the three extensions (`win11-clipboard-bridge`, `window-calls`, `spawn-at`) or `spawn-at` is updated later.
>
> One login is enough. About 20 seconds after you log in, a one-time check shows a notification either way: "Win11Clip is ready", or "log out and back in once more" naming what did not load (the details are in `~/.local/state/win11clip-installer/firstrun.log`). The installer also warns up front if an extension does not list your GNOME Shell version, since GNOME then refuses to load it.

---

## ⌨️ Shortcuts & Safe Registration

Win11Clip registers custom global shortcuts directly with your desktop environment without overwriting your existing hotkeys:

| Shortcut | Action | Description |
| :--- | :--- | :--- |
| <kbd>Super</kbd> + <kbd>V</kbd> | **Clipboard history** | Opens the clipboard history flyout at the mouse pointer. |
| <kbd>Super</kbd> + <kbd>.</kbd> | **Emoji Picker** | Opens the searchable emoji picker flyout at the mouse pointer. |
| <kbd>Enter</kbd> | **Paste Item** | Pastes the selected clipboard item or emoji into the active window. |
| <kbd>Esc</kbd> | **Close** | Closes the flyout immediately. |

### Safe Shortcut Conflict Resolution
On GNOME, `<Super>v` is bound by default to `focus-active-notification` (Message Tray). Win11Clip detects this conflict and **safely reassigns** the collision without destroying any other user shortcuts.

### Manual Keybinding Setup (If Needed)
If you are running a standalone window manager (Sway, Hyprland, i3, etc.) or prefer manual configuration (use the full path, `~/.local/bin/spawn-at`, if that folder is not on the `PATH` your session starts with):
- **Clipboard history (Super+V):** `spawn-at spawn --anchor cursor -o -15 -15 -m 10 -c io.github.harshp2008.win11clip win11clip --clipboard`
- **Emoji picker (Super+.):** `spawn-at spawn --anchor cursor -o -15 -15 -m 10 -c io.github.harshp2008.win11clip win11clip --emoji`

`-c io.github.harshp2008.win11clip` is the app's own Wayland app id (X11 `WM_CLASS`). It tells `spawn-at` which window is the popup, so keep it in every shortcut you write by hand. Shortcuts from earlier releases (the old command `win11-clipboard-history`, without `-c`, or with the old `dev.gustavosett.clipboard-history` class) are replaced by the installer and the app, never duplicated.

---

## 🔄 Upgrading from the old name

Until version 0.7.5 this app was called *Clipboard History* and its command, package and folders were named `win11-clipboard-history` (the name the upstream project uses for its own package). Win11Clip is now `win11clip` everywhere:

| | Before | Now |
| :--- | :--- | :--- |
| Name shown | Clipboard History | **Win11Clip** |
| Command | `win11-clipboard-history` | `win11clip` (the executable is `win11clip-bin`) |
| Package (deb, rpm, AUR) | `win11-clipboard-history` | `win11clip` (declares `Replaces`, `Conflicts` and `Provides` for the old name) |
| Desktop file and icon | `win11-clipboard-history` | `io.github.harshp2008.win11clip` |
| Autostart entry | `win11-clipboard-history.desktop` | `io.github.harshp2008.win11clip.desktop` |
| Data, config and cache folders | `win11-clipboard-history` | `win11clip` |

Installing over an old installation is safe:

- **Package:** the installer asks (default No) before it removes the old `win11-clipboard-history` package, saves that package's files under `~/.local/state/win11clip-installer/backup` first, and installs `win11clip`. Release packages of Win11Clip up to 0.7.5 carry the same maintainer as the upstream project's package, so the installer shows you the maintainer instead of guessing which one it is.
- **Your data:** on its first start the new version **copies** your clipboard history, settings, first-run flag and GIF cache from the old folders to the new ones. The old folders are never moved or deleted, and nothing is copied again once the new ones exist, so you will not see the Setup Wizard again.
- **Shortcuts and autostart:** shortcuts and the autostart entry of the old name are rewritten in place for the new command, never duplicated.
- **Old files:** the installer removes the old launcher, menu entry and icons that no package owns, so the app menu shows Win11Clip once.

---

## 🗑️ Uninstallation

Win11Clip includes a clean uninstaller that removes binaries, desktop integration, custom GNOME shortcuts, and offers an interactive prompt to cleanly keep or remove companion extensions. It removes everything of Win11Clip **and** of the old name (`win11-clipboard-history`) in one go. It never deletes your clipboard history or settings: `~/.config/win11clip`, `~/.local/share/win11clip` and `~/.cache/win11clip` (and the same folders under the old name) stay where they are, and it tells you which ones exist. At the end it lists everything it kept on purpose (those folders, the installer's backups in `~/.local/state/win11clip-installer`, and `window-calls` or `spawn-at` if you chose to keep them), each with the command that deletes it. It deletes itself as its very last step, unless you kept the app's system package, in which case it stays so you can run it again.

### From Terminal (Anytime)
```bash
win11clip-uninstall
```

The old command `win11-clipboard-uninstall` still works; the installer leaves it as a link to the new one. If the terminal still finds `win11clip-uninstall` after it has finished, that is the shell remembering the old path; run `hash -r`.

### Or One-Line Remote Uninstall
```bash
curl -fsSL https://raw.githubusercontent.com/harshp2008/Win11Clip/master/scripts/uninstall.sh | bash
```

---

## 📦 Packages & Distribution Binaries

Pre-compiled packages for each release are available on the [Releases](https://github.com/harshp2008/Win11Clip/releases) page.

### Debian / Ubuntu (.deb)
```bash
sudo dpkg -i win11clip_*.deb
sudo apt install -f -y
sudo setfacl -m u:$USER:rw /dev/uinput
```

### Fedora / RHEL (.rpm)
```bash
sudo dnf install ./win11clip-*.rpm
sudo setfacl -m u:$USER:rw /dev/uinput
```

### AppImage
```bash
chmod +x win11clip_*.AppImage
sudo setfacl -m u:$USER:rw /dev/uinput
./win11clip_*.AppImage --clipboard
```

### GNOME: `spawn-at` and the log-out after a manual install
The packages install the app only. On GNOME the popup is placed at your cursor by [`spawn-at`](https://github.com/harshp2008/spawn-at) **0.2.4 or newer** and its GNOME Shell extension, plus the two companion extensions (`win11-clipboard-bridge`, `window-calls`); the [Quick Install](#one-line-quick-install) script sets all of them up. After a manual install, install `spawn-at` yourself and check it:

```bash
curl -fsSL https://raw.githubusercontent.com/harshp2008/spawn-at/main/install.sh | bash
spawn-at -V   # must print spawn-at 0.2.4 or newer
```

**On Wayland, a newly installed or updated GNOME extension only loads after you log out and back in.** Do that once after installing or updating `spawn-at` or any of these extensions. With the Quick Install script, a one-time check runs about 20 seconds after you log in and shows a notification, either "Win11Clip is ready" or which extension did not load (details in `~/.local/state/win11clip-installer/firstrun.log`). A manual install has no such check, so use the commands under [Troubleshooting](#-troubleshooting) to look at the extensions yourself.

---

## 🔧 Troubleshooting

- **Flyout Spawning at Screen Center:** Ensure the GNOME Shell session was restarted after initial install so Mutter loads `window-calls` and `win11-clipboard-bridge`. Test with:
  ```bash
  gdbus call --session --dest org.gnome.Shell --object-path /org/gnome/Shell/Extensions/Windows --method org.gnome.Shell.Extensions.Windows.GetCoordinates
  ```
- **Popup appears in the wrong place, or `spawn-at` says the extension does not answer:** check that all three extensions are `ACTIVE` and that `spawn-at` is 0.2.4 or newer, then log out and back in once:
  ```bash
  spawn-at -V
  for e in win11-clipboard-bridge@harshp2008.github.com window-calls@domandoman.xyz spawn-at@harsh.local; do gnome-extensions info $e | grep State; done
  ```
  `OUT OF DATE` means the extension does not list your GNOME Shell version; logging in again will not fix that.
- **Window Focus on Wayland:** If focus is not captured immediately:
  ```bash
  gnome-extensions enable win11-clipboard-bridge@harshp2008.github.com
  gnome-extensions enable window-calls@domandoman.xyz
  ```
- **NVIDIA / Transparency Issues:** Run with the hardware acceleration workaround flag:
  ```bash
  IS_NVIDIA=1 win11clip --clipboard
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

- **Core Base & Visual Concept:** Forked from [gustavosett/Windows-11-Clipboard-History-For-Linux](https://github.com/gustavosett/Windows-11-Clipboard-History-For-Linux) under the MIT License. The upstream copyright notice stays in [LICENSE](LICENSE).
- **Wayland Hardening, Spawn-At Positioning & WebKitGTK 4.1 Migration:** [Harsh P. (harshp2008)](https://github.com/harshp2008).
- **License:** [MIT License](LICENSE)
