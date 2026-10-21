//! Which `spawn-at` the app writes into shortcuts and login entries.
//!
//! Decided the same way as `scripts/install.sh`: the executable `~/.local/bin/spawn-at` when it
//! exists, otherwise the bare name (looked up on `PATH`). The installer keeps exactly one copy
//! there, and a full path works whatever `PATH` the desktop session started with.

use std::path::{Path, PathBuf};

pub const SPAWN_AT_NAME: &str = "spawn-at";

fn is_executable_file(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(path)
        .map(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
        .unwrap_or(false)
}

/// `~/.local/bin/spawn-at` under `home` when it is an executable file, else `None`.
pub fn user_copy_in(home: &Path) -> Option<PathBuf> {
    let p = home.join(".local/bin").join(SPAWN_AT_NAME);
    is_executable_file(&p).then_some(p)
}

/// The spawn-at command for a shell or a shortcut: the full path of the user copy (in double quotes
/// when it contains whitespace), else the bare name.
pub fn shell_command_in(home: Option<&Path>) -> String {
    match home.and_then(user_copy_in) {
        Some(p) => {
            let s = p.to_string_lossy().into_owned();
            if s.contains(char::is_whitespace) {
                format!("\"{s}\"")
            } else {
                s
            }
        }
        None => SPAWN_AT_NAME.to_string(),
    }
}

pub fn shell_command() -> String {
    shell_command_in(dirs::home_dir().as_deref())
}

/// Like `shell_command_in`, for a desktop-entry `Exec=` line, where quoting is awkward: a path with
/// whitespace, quotes or characters special to desktop entries or the shell falls back to the bare name.
pub fn desktop_exec_in(home: Option<&Path>) -> String {
    let cmd = shell_command_in(home);
    let plain = |c: char| c.is_ascii_alphanumeric() || "/._-+,:@=".contains(c);
    if cmd.chars().all(plain) {
        cmd
    } else {
        SPAWN_AT_NAME.to_string()
    }
}

pub fn desktop_exec() -> String {
    desktop_exec_in(dirs::home_dir().as_deref())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    fn temp_home(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("w11c-test-{}-{}", tag, std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(d.join(".local/bin")).unwrap();
        d
    }

    fn put(home: &Path, mode: u32) -> PathBuf {
        let p = home.join(".local/bin/spawn-at");
        std::fs::write(&p, "#!/bin/sh\n").unwrap();
        std::fs::set_permissions(&p, std::fs::Permissions::from_mode(mode)).unwrap();
        p
    }

    #[test]
    fn bare_name_when_no_user_copy_or_no_home() {
        let h = temp_home("none");
        assert_eq!(shell_command_in(Some(&h)), "spawn-at");
        assert_eq!(shell_command_in(None), "spawn-at");
        let _ = std::fs::remove_dir_all(&h);
    }

    #[test]
    fn full_path_when_executable() {
        let h = temp_home("exec");
        let p = put(&h, 0o755);
        assert_eq!(shell_command_in(Some(&h)), p.to_string_lossy());
        assert_eq!(desktop_exec_in(Some(&h)), p.to_string_lossy());
        let _ = std::fs::remove_dir_all(&h);
    }

    #[test]
    fn non_executable_file_is_ignored() {
        let h = temp_home("noexec");
        put(&h, 0o644);
        assert_eq!(shell_command_in(Some(&h)), "spawn-at");
        let _ = std::fs::remove_dir_all(&h);
    }

    #[test]
    fn path_with_space_is_quoted_for_shortcuts_and_bare_for_desktop_entries() {
        let h = temp_home("sp ace");
        let p = put(&h, 0o755);
        assert_eq!(shell_command_in(Some(&h)), format!("\"{}\"", p.display()));
        assert_eq!(desktop_exec_in(Some(&h)), "spawn-at");
        let _ = std::fs::remove_dir_all(&h);
    }
}
