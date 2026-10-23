//! Fails when the names of the app drift apart.
//!
//! The app has one set of names (`win11clip_lib::app_id`) and a lot of files that cannot import them:
//! the Tauri config, Cargo.toml, the desktop files, the launcher, both shell scripts, the Makefile,
//! the AUR files, the release workflow, the README and the Setup Wizard. This test reads those files
//! and checks every one of them against the constants, and scans the repository for the old names
//! so that a new use of one has to be added to the allowlist below, with a reason, on purpose.

use serde_json::Value;
use std::fs;
use std::path::{Path, PathBuf};
use win11clip_lib::app_id::{
    APP_ID, BINARY_NAME, COMMAND_NAME, DATA_DIR_NAME, DISPLAY_NAME, LEGACY_APP_IDS,
    LEGACY_BINARY_NAME, LEGACY_COMMAND_NAME, LEGACY_DATA_DIR_NAME, LEGACY_DISPLAY_NAME,
    UPSTREAM_APP_ID,
};

const OWNER: &str = "harshp2008";
const REPO_URL: &str = "https://github.com/harshp2008/Win11Clip";
const UPSTREAM_REPO: &str = "gustavosett/Windows-11-Clipboard-History-For-Linux";

fn src_tauri() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

fn repo_root() -> PathBuf {
    src_tauri().parent().unwrap().to_path_buf()
}

fn read(rel: &str) -> String {
    let path = repo_root().join(rel);
    fs::read_to_string(&path).unwrap_or_else(|e| panic!("cannot read {}: {e}", path.display()))
}

fn json(rel: &str) -> Value {
    serde_json::from_str(&read(rel)).unwrap_or_else(|e| panic!("{rel} is not JSON: {e}"))
}

/// The value of `key = "value"` (or `key: value`) on the first line of `text` that starts with `key`.
fn assignment(text: &str, key: &str) -> String {
    text.lines()
        .map(str::trim)
        .find_map(|l| {
            let rest = l.strip_prefix(key)?.trim_start();
            let rest = rest
                .strip_prefix('=')
                .or_else(|| rest.strip_prefix(":="))?
                .trim();
            Some(rest.trim_matches(['"', '\'']).to_string())
        })
        .unwrap_or_else(|| panic!("no `{key}` line"))
}

fn strings(v: &Value) -> Vec<String> {
    v.as_array()
        .unwrap_or_else(|| panic!("expected an array, got {v}"))
        .iter()
        .map(|s| s.as_str().unwrap().to_string())
        .collect()
}

// ------------------------------------------------------------------------------------------------
// The constants themselves
// ------------------------------------------------------------------------------------------------

#[test]
fn the_names_are_what_the_owner_asked_for() {
    assert_eq!(DISPLAY_NAME, "Win11Clip");
    assert_eq!(COMMAND_NAME, "win11clip");
    assert_eq!(BINARY_NAME, "win11clip-bin");
    assert_eq!(DATA_DIR_NAME, "win11clip");
    assert_eq!(APP_ID, "io.github.harshp2008.win11clip");
    assert_eq!(LEGACY_COMMAND_NAME, "win11-clipboard-history");
    assert_eq!(LEGACY_BINARY_NAME, "win11-clipboard-history-bin");
    assert_eq!(LEGACY_DATA_DIR_NAME, "win11-clipboard-history");
    assert_eq!(LEGACY_DISPLAY_NAME, "Clipboard History");
    assert_eq!(UPSTREAM_APP_ID, "dev.gustavosett.clipboard-history");
    // Everything derived from the command name follows it.
    assert_eq!(BINARY_NAME, format!("{COMMAND_NAME}-bin"));
    assert_eq!(DATA_DIR_NAME, COMMAND_NAME);
    assert!(APP_ID.ends_with(&format!(".{COMMAND_NAME}")));
    assert!(!LEGACY_APP_IDS.contains(&APP_ID));
}

// ------------------------------------------------------------------------------------------------
// Tauri config, Cargo.toml, package.json
// ------------------------------------------------------------------------------------------------

#[test]
fn tauri_conf_uses_the_names() {
    let conf = json("src-tauri/tauri.conf.json");
    assert_eq!(
        conf["productName"], COMMAND_NAME,
        "the package, deb and AppImage names derive from it"
    );
    assert_eq!(conf["identifier"], APP_ID);

    let windows = conf["app"]["windows"].as_array().unwrap();
    let title = |label: &str| {
        windows
            .iter()
            .find(|w| w["label"] == label)
            .unwrap_or_else(|| panic!("no {label} window"))["title"]
            .as_str()
            .unwrap()
            .to_string()
    };
    assert_eq!(title("main"), DISPLAY_NAME);
    assert_eq!(title("setup"), format!("Setup - {DISPLAY_NAME}"));
    assert_eq!(title("settings"), format!("Settings - {DISPLAY_NAME}"));

    let bundle = &conf["bundle"];
    assert_eq!(bundle["publisher"], OWNER);
    assert_eq!(bundle["homepage"], REPO_URL);
    let copyright = bundle["copyright"].as_str().unwrap();
    assert!(
        copyright.contains("Windows 11 Clipboard History For Linux Contributors"),
        "the upstream copyright stays"
    );
    assert!(copyright.contains(OWNER), "and the owner's is added");
}

#[test]
fn deb_and_rpm_replace_the_old_package_name() {
    let conf = json("src-tauri/tauri.conf.json");
    let deb = &conf["bundle"]["linux"]["deb"];
    for key in ["provides", "conflicts", "replaces"] {
        assert_eq!(strings(&deb[key]), [LEGACY_COMMAND_NAME], "deb.{key}");
    }
    let rpm = &conf["bundle"]["linux"]["rpm"];
    for key in ["provides", "conflicts", "obsoletes"] {
        assert_eq!(strings(&rpm[key]), [LEGACY_COMMAND_NAME], "rpm.{key}");
    }
}

#[test]
fn packages_install_the_launcher_desktop_file_and_icons_under_the_names() {
    let conf = json("src-tauri/tauri.conf.json");
    let launcher = format!("/usr/bin/{COMMAND_NAME}");
    let desktop = format!("/usr/share/applications/{APP_ID}.desktop");
    let metainfo = format!("/usr/share/metainfo/{APP_ID}.metainfo.xml");
    let icons = [
        format!("/usr/share/icons/hicolor/128x128/apps/{APP_ID}.png"),
        format!("/usr/share/icons/hicolor/256x256/apps/{APP_ID}.png"),
        format!("/usr/share/icons/hicolor/scalable/apps/{APP_ID}.svg"),
    ];
    for format_name in ["deb", "rpm"] {
        let files = conf["bundle"]["linux"][format_name]["files"]
            .as_object()
            .unwrap();
        assert_eq!(files[&launcher], "bundle/linux/wrapper.sh", "{format_name}");
        assert_eq!(
            files[&desktop],
            format!("bundle/linux/{APP_ID}.desktop"),
            "{format_name}"
        );
        assert_eq!(
            files[&metainfo],
            format!("bundle/linux/{APP_ID}.metainfo.xml"),
            "{format_name}"
        );
        for icon in &icons {
            assert!(files.contains_key(icon), "{format_name} lacks {icon}");
        }
        // every file named exists, and no path of the old name is installed
        for (dest, src) in files {
            assert!(
                src_tauri().join(src.as_str().unwrap()).is_file(),
                "{format_name}: {src} is missing"
            );
            assert!(
                !dest.contains(LEGACY_COMMAND_NAME),
                "{format_name} installs {dest}, a path of the old name"
            );
        }
    }
    // Tauri always writes <productName>.desktop; the deb ships it hidden so the menu shows one entry.
    let deb_files = conf["bundle"]["linux"]["deb"]["files"].as_object().unwrap();
    assert_eq!(
        deb_files[&format!("/usr/share/applications/{COMMAND_NAME}.desktop")],
        "bundle/linux/win11clip-hidden.desktop"
    );
    assert_eq!(
        conf["bundle"]["linux"]["rpm"]["desktopTemplate"],
        "bundle/linux/win11clip-hidden.desktop"
    );
    assert_eq!(
        conf["bundle"]["linux"]["deb"]["desktopTemplate"],
        "bundle/linux/appimage.desktop"
    );
}

#[test]
fn cargo_toml_and_package_json_use_the_names_and_the_owner() {
    let cargo = read("src-tauri/Cargo.toml");
    let section = |name: &str| {
        let start = cargo
            .find(name)
            .unwrap_or_else(|| panic!("no {name} in Cargo.toml"));
        cargo[start..]
            .lines()
            .skip(1)
            .take_while(|l| !l.starts_with('['))
            .collect::<Vec<_>>()
            .join("\n")
    };
    let package = section("[package]");
    assert_eq!(assignment(&package, "name"), COMMAND_NAME);
    assert_eq!(assignment(&package, "authors"), format!("[\"{OWNER}\"]"));
    assert_eq!(assignment(&package, "homepage"), REPO_URL);
    assert_eq!(assignment(&package, "repository"), REPO_URL);
    assert_eq!(
        assignment(&section("[lib]"), "name"),
        format!("{COMMAND_NAME}_lib")
    );
    assert_eq!(assignment(&section("[[bin]]"), "name"), BINARY_NAME);

    let pkg = json("package.json");
    assert_eq!(pkg["name"], COMMAND_NAME);
    assert_eq!(pkg["author"], OWNER);
    assert_eq!(pkg["homepage"], REPO_URL);
    assert_eq!(pkg["repository"]["url"], format!("{REPO_URL}.git"));
    let lock = json("package-lock.json");
    assert_eq!(lock["name"], COMMAND_NAME);
    assert_eq!(lock["packages"][""]["name"], COMMAND_NAME);
}

// ------------------------------------------------------------------------------------------------
// Desktop files, launcher, AppStream
// ------------------------------------------------------------------------------------------------

fn desktop_value(text: &str, key: &str) -> Option<String> {
    text.lines()
        .find_map(|l| l.strip_prefix(&format!("{key}=")))
        .map(str::to_string)
}

#[test]
fn the_desktop_files_use_the_names() {
    let real = read(&format!("src-tauri/bundle/linux/{APP_ID}.desktop"));
    assert_eq!(desktop_value(&real, "Name").as_deref(), Some(DISPLAY_NAME));
    assert_eq!(desktop_value(&real, "Exec").as_deref(), Some(COMMAND_NAME));
    assert_eq!(desktop_value(&real, "Icon").as_deref(), Some(APP_ID));
    assert_eq!(
        desktop_value(&real, "StartupWMClass").as_deref(),
        Some(APP_ID)
    );
    assert!(desktop_value(&real, "Hidden").is_none());

    let hidden = read("src-tauri/bundle/linux/win11clip-hidden.desktop");
    assert_eq!(
        desktop_value(&hidden, "Hidden").as_deref(),
        Some("true"),
        "only one entry may show in the menu"
    );
    assert_eq!(
        desktop_value(&hidden, "Name").as_deref(),
        Some(DISPLAY_NAME)
    );

    let appimage = read("src-tauri/bundle/linux/appimage.desktop");
    assert_eq!(
        desktop_value(&appimage, "Name").as_deref(),
        Some(DISPLAY_NAME)
    );
    assert_eq!(
        desktop_value(&appimage, "StartupWMClass").as_deref(),
        Some(APP_ID)
    );
    assert!(desktop_value(&appimage, "Hidden").is_none());
    assert!(appimage.contains("Exec={{exec}}") && appimage.contains("Icon={{icon}}"));
}

#[test]
fn the_launcher_runs_the_binary_of_the_new_name() {
    let wrapper = read("src-tauri/bundle/linux/wrapper.sh");
    for loc in [
        format!("\"/usr/bin/{BINARY_NAME}\""),
        format!("\"/usr/lib/{COMMAND_NAME}/{BINARY_NAME}\""),
        format!("\"/usr/local/lib/{COMMAND_NAME}/{BINARY_NAME}\""),
    ] {
        assert!(wrapper.contains(&loc), "wrapper.sh does not look for {loc}");
    }
    assert!(!wrapper.contains(LEGACY_COMMAND_NAME));
}

#[test]
fn the_appstream_file_names_the_app_and_its_owner() {
    let xml = read(&format!("src-tauri/bundle/linux/{APP_ID}.metainfo.xml"));
    assert!(xml.contains(&format!("<id>{APP_ID}</id>")));
    assert!(xml.contains(&format!("<name>{DISPLAY_NAME}</name>")));
    assert!(xml.contains(&format!(
        "<launchable type=\"desktop-id\">{APP_ID}.desktop</launchable>"
    )));
    assert!(
        xml.contains(&format!("<name>{OWNER}</name>")),
        "the developer"
    );
    assert!(xml.contains(&format!("<binary>{COMMAND_NAME}</binary>")));
    assert!(xml.contains(REPO_URL));
}

#[test]
fn the_gnome_extension_is_shown_as_win11clip() {
    let dir = "extensions/win11-clipboard-bridge@harshp2008.github.com";
    let meta = json(&format!("{dir}/metadata.json"));
    // The uuid is the id of installed extensions and stays; the name people see does not.
    assert_eq!(meta["uuid"], "win11-clipboard-bridge@harshp2008.github.com");
    assert!(meta["name"].as_str().unwrap().starts_with(DISPLAY_NAME));
    assert_eq!(meta["url"], REPO_URL);
}

// ------------------------------------------------------------------------------------------------
// Scripts and Makefile
// ------------------------------------------------------------------------------------------------

#[test]
fn install_and_uninstall_scripts_hold_the_same_names() {
    let expected = [
        ("APP_ID", APP_ID),
        ("APP_DISPLAY_NAME", DISPLAY_NAME),
        ("APP_CMD", COMMAND_NAME),
        ("APP_BIN", BINARY_NAME),
        ("PKG_NAME", COMMAND_NAME),
        ("UNINSTALL_CMD", "win11clip-uninstall"),
        ("OLD_CMD", LEGACY_COMMAND_NAME),
        ("OLD_BIN", LEGACY_BINARY_NAME),
        ("OLD_PKG_NAME", LEGACY_COMMAND_NAME),
        ("OLD_UNINSTALL_CMD", "win11-clipboard-uninstall"),
    ];
    for script in ["scripts/install.sh", "scripts/uninstall.sh"] {
        let text = read(script);
        for (var, value) in expected {
            assert_eq!(assignment(&text, var), value, "{script}: {var}");
        }
    }
    let install = read("scripts/install.sh");
    assert!(install.contains("StartupWMClass=$APP_ID"));
    assert!(install.contains("-c $APP_ID $APP_CMD --clipboard"));
    assert!(install.contains("-c $APP_ID $APP_CMD --emoji"));
}

#[test]
fn the_makefile_uses_the_names() {
    let make = read("Makefile");
    assert_eq!(assignment(&make, "APP_NAME"), COMMAND_NAME);
    assert_eq!(assignment(&make, "APP_ID"), APP_ID);
    assert_eq!(assignment(&make, "APP_DISPLAY_NAME"), DISPLAY_NAME);
    assert_eq!(assignment(&make, "OLD_NAME"), LEGACY_COMMAND_NAME);
    assert!(make.contains("src-tauri/bundle/linux/$(APP_ID).desktop"));
    assert!(make.contains("hicolor/128x128/apps/$(APP_ID).png"));
    assert!(make.contains("remove-old-name"));
}

#[test]
fn the_setup_wizard_and_the_manual_instructions_show_the_same_command() {
    let command = format!(
        "spawn-at spawn --anchor cursor -o -15 -15 -m 10 -c {APP_ID} {COMMAND_NAME} --clipboard"
    );
    assert!(
        read("src/components/SetupWizard.tsx").contains(&command),
        "SetupWizard.tsx"
    );
    assert!(read("README.md").contains(&command), "README.md");
    assert!(
        win11clip_lib::shortcut_manager::get_manual_instructions("GNOME").contains(&command),
        "the instructions the app shows"
    );
    assert!(read("src/components/SetupWizard.tsx").contains(&format!("Welcome to {DISPLAY_NAME}")));
    assert!(read("index.html").contains(&format!("<title>{DISPLAY_NAME}</title>")));
}

// ------------------------------------------------------------------------------------------------
// Packaging: AUR and the release workflow
// ------------------------------------------------------------------------------------------------

/// The words inside `key=( ... )` of a PKGBUILD, without their quotes.
fn pkgbuild_array(text: &str, key: &str) -> Vec<String> {
    let line = text
        .lines()
        .find(|l| l.starts_with(&format!("{key}=(")))
        .unwrap_or_else(|| panic!("no {key}=(...) in PKGBUILD"));
    let inner = line
        .trim_start_matches(&format!("{key}=("))
        .trim_end_matches(')');
    inner
        .split_whitespace()
        .map(|w| w.trim_matches(['\'', '"']).to_string())
        .collect()
}

#[test]
fn the_aur_package_is_win11clip_and_replaces_the_old_name() {
    let pkgbuild = read("aur/PKGBUILD");
    assert_eq!(assignment(&pkgbuild, "pkgname"), COMMAND_NAME);
    for key in ["provides", "conflicts", "replaces"] {
        assert_eq!(
            pkgbuild_array(&pkgbuild, key),
            [LEGACY_COMMAND_NAME],
            "{key}"
        );
    }
    assert_eq!(
        assignment(&pkgbuild, "url"),
        format!("\"{REPO_URL}\"").trim_matches('"')
    );
    assert!(pkgbuild.contains(&format!("{COMMAND_NAME}_${{pkgver}}_amd64.deb")));
    assert!(pkgbuild.contains(&format!("{COMMAND_NAME}_${{pkgver}}_arm64.deb")));
    assert!(pkgbuild.contains(&format!("\"$pkgdir/usr/bin/{COMMAND_NAME}\"")));
    assert!(pkgbuild.contains("Maintainer: Harsh Patel (harshp2008)"));
    assert!(
        pkgbuild.contains("Copyright (c) 2024 Gustavo Sett"),
        "the upstream copyright stays in the packaged license"
    );
    assert!(repo_root()
        .join(format!("aur/{COMMAND_NAME}.install"))
        .is_file());
    assert!(!repo_root()
        .join(format!("aur/{LEGACY_COMMAND_NAME}-bin.install"))
        .exists());
}

#[test]
fn the_release_workflow_names_the_assets_after_the_package() {
    let release = read(".github/workflows/release.yml");
    for asset in [
        format!("{COMMAND_NAME}_${{{{ steps.get_version.outputs.VERSION }}}}_amd64.deb"),
        format!("{COMMAND_NAME}-${{{{ steps.get_version.outputs.VERSION }}}}-1.x86_64.rpm"),
        format!("{COMMAND_NAME}_${{{{ steps.get_version.outputs.VERSION }}}}_amd64.AppImage"),
        format!("ssh://aur@aur.archlinux.org/{COMMAND_NAME}.git"),
        format!("aur/{COMMAND_NAME}.install"),
        format!("pkgbase = {COMMAND_NAME}"),
        format!("pkgname = {COMMAND_NAME}"),
        format!("{COMMAND_NAME}_${{VERSION}}_amd64.deb"),
    ] {
        assert!(release.contains(&asset), "release.yml lacks {asset}");
    }
    assert!(
        !release.contains(&format!("{LEGACY_COMMAND_NAME}_")),
        "an asset of the old name"
    );
    assert!(
        !release.contains(&format!("{LEGACY_COMMAND_NAME}-$")),
        "an asset of the old name"
    );
    assert!(release.contains(&format!("# {DISPLAY_NAME} ${{{{ github.ref_name }}}}")));
    // The installer picks assets by extension and architecture, not by name.
    let install = read("scripts/install.sh");
    assert!(install.contains(r#"grep "browser_download_url.*\.${ext}\"" | grep -i "${arch}""#));
}

// ------------------------------------------------------------------------------------------------
// Credit and licence
// ------------------------------------------------------------------------------------------------

#[test]
fn the_upstream_credit_and_licence_stay() {
    let license = read("LICENSE");
    assert!(
        license.contains("Copyright (c) 2024 Windows 11 Clipboard History For Linux Contributors")
    );
    assert!(license.contains(&format!("Copyright (c) 2026 {OWNER}")));
    let readme = read("README.md");
    assert!(
        readme.contains(&format!("Forked from [{UPSTREAM_REPO}]")),
        "README credit"
    );
    assert!(readme.contains("MIT"));
    // and the installer still knows the upstream project's apt source and package
    let install = read("scripts/install.sh");
    assert!(install.contains("gustavosett-clipboard-manager.list"));
    assert!(install.contains("old_package_origin"));
}

// ------------------------------------------------------------------------------------------------
// Old names stay out of the repository unless a file is listed here
// ------------------------------------------------------------------------------------------------

/// Files that may contain the old command, package or data-folder name `win11-clipboard-history`,
/// with the reason. Anything else that names it is a place the rename missed.
const MAY_NAME_THE_OLD_COMMAND: &[(&str, &str)] = &[
    ("src-tauri/src/app_id.rs", "the LEGACY_* constants"),
    (
        "src-tauri/src/legacy_data.rs",
        "migrates the old data folders",
    ),
    (
        "src-tauri/src/autostart_manager.rs",
        "migrates the old autostart entry",
    ),
    (
        "src-tauri/src/shortcut_manager.rs",
        "recognises and replaces old shortcut commands; the shortcut ids are stable keys",
    ),
    (
        "src-tauri/src/focus_manager.rs",
        "still recognises the old popup class",
    ),
    (
        "src-tauri/src/adaptive_dock.rs",
        "keeps the Dock Manager's Bypass entries of the old ids",
    ),
    (
        "src-tauri/src/clipboard_manager.rs",
        "history items point into the old GIF cache folder",
    ),
    (
        "src-tauri/tauri.conf.json",
        "provides/conflicts/replaces of the deb and rpm",
    ),
    ("scripts/install.sh", "replaces an old install"),
    ("scripts/uninstall.sh", "removes an old install"),
    ("scripts/test-rename.sh", "tests of the above"),
    ("scripts/test-shortcut-app-id.sh", "tests of the above"),
    (
        "Makefile",
        "OLD_NAME: installs over and uninstalls an old install",
    ),
    ("aur/PKGBUILD", "provides/conflicts/replaces"),
    (".github/workflows/release.yml", "the generated .SRCINFO"),
    ("README.md", "the upgrade section"),
    ("src-tauri/tests/naming.rs", "this test"),
];

/// Files that may say "Clipboard History" as a name: the old window title and menu name.
const MAY_SAY_CLIPBOARD_HISTORY: &[(&str, &str)] = &[
    ("src-tauri/src/app_id.rs", "LEGACY_DISPLAY_NAME"),
    ("src-tauri/src/focus_manager.rs", "still recognises the old popup title"),
    ("src-tauri/src/shortcut_manager.rs", "the old marker comments, and KDE's Klipper"),
    ("src-tauri/src/autostart_manager.rs", "test fixture of the old entry"),
    ("src-tauri/src/legacy_data.rs", "doc comment"),
    ("scripts/install.sh", "comments about the old menu entry"),
    ("scripts/uninstall.sh", "also removes shortcuts that carry the old name"),
    ("scripts/test-rename.sh", "fixtures of the old name"),
    ("scripts/test-shortcut-app-id.sh", "fixtures of the old name"),
    ("README.md", "the upgrade section"),
    ("src-tauri/tests/naming.rs", "this test"),
    ("LICENSE", "the upstream copyright line"),
    ("src/SettingsApp.tsx", "names the feature Super+V opens ('Open Clipboard History', next to 'Open Emoji Picker'), not the app"),
];

fn walk(dir: &Path, out: &mut Vec<PathBuf>) {
    const SKIP: &[&str] = &[
        ".git",
        "node_modules",
        "target",
        "dist",
        "docs",
        "gen",
        "bundled-deps",
        "icons",
        "public",
    ];
    for entry in fs::read_dir(dir).unwrap().flatten() {
        let path = entry.path();
        let name = entry.file_name().to_string_lossy().to_string();
        if path.is_dir() {
            if !SKIP.contains(&name.as_str()) {
                walk(&path, out);
            }
        } else if name != "package-lock.json" && name != "Cargo.lock" {
            out.push(path);
        }
    }
}

/// The repository's text files, as (path relative to the repo root, content).
fn repo_text_files() -> Vec<(String, String)> {
    let root = repo_root();
    let mut paths = Vec::new();
    walk(&root, &mut paths);
    paths
        .into_iter()
        .filter_map(|p| {
            let content = fs::read_to_string(&p).ok()?;
            let rel = p.strip_prefix(&root).unwrap().to_string_lossy().to_string();
            Some((rel, content))
        })
        .collect()
}

fn unexpected(needle: &str, allowed: &[(&str, &str)], strip: &[&str]) -> Vec<String> {
    repo_text_files()
        .into_iter()
        .filter(|(rel, content)| {
            let mut c = content.clone();
            for s in strip {
                c = c.replace(s, "");
            }
            c.contains(needle) && !allowed.iter().any(|(f, _)| f == rel)
        })
        .map(|(rel, _)| rel)
        .collect()
}

#[test]
fn the_old_command_name_appears_only_where_it_is_migrated() {
    // The GNOME extension uuid and the udev/modules files are internal ids that keep their names;
    // none of them contains the old command name, so there is nothing to strip.
    let stray = unexpected(LEGACY_COMMAND_NAME, MAY_NAME_THE_OLD_COMMAND, &[]);
    assert!(
        stray.is_empty(),
        "these files still name `{LEGACY_COMMAND_NAME}`; rename it, or list the file in MAY_NAME_THE_OLD_COMMAND with a reason: {stray:?}"
    );
}

#[test]
fn the_old_display_name_appears_only_where_it_is_recognised() {
    // "Windows 11-style Clipboard History Manager" is the description of the app, not its name, and
    // "Klipper Clipboard History" is KDE's.
    let stray = unexpected(
        LEGACY_DISPLAY_NAME,
        MAY_SAY_CLIPBOARD_HISTORY,
        &[
            "Windows 11-style Clipboard History Manager",
            "Windows 11 Clipboard History For Linux",
            "Windows 11-style Clipboard History",
        ],
    );
    assert!(
        stray.is_empty(),
        "these files still show the name `{LEGACY_DISPLAY_NAME}`; rename it, or list the file in MAY_SAY_CLIPBOARD_HISTORY with a reason: {stray:?}"
    );
}

#[test]
fn the_upstream_project_is_only_credited_and_handled_where_expected() {
    // gustavosett appears in the credit and licence, the upstream-package handling, the old app id,
    // the contributor list and the sponsor button the owner has not decided about.
    let allowed: &[(&str, &str)] = &[
        ("README.md", "credit"),
        ("LICENSE", "upstream copyright"),
        (
            "scripts/install.sh",
            "upstream apt source and package handling",
        ),
        ("scripts/uninstall.sh", "restores the upstream apt source"),
        ("scripts/test-rename.sh", "fixtures"),
        ("scripts/test-shortcut-app-id.sh", "fixtures"),
        ("src-tauri/src/app_id.rs", "UPSTREAM_APP_ID"),
        ("src-tauri/src/shortcut_manager.rs", "older shortcut forms"),
        (
            "src-tauri/src/adaptive_dock.rs",
            "dock entries of the old id",
        ),
        ("src-tauri/src/legacy_data.rs", "doc comment"),
        ("src-tauri/tests/naming.rs", "this test"),
        (
            "aur/PKGBUILD",
            "the upstream copyright in the packaged license, and a note",
        ),
        ("aur/win11clip.install", "none expected"),
        (
            ".github/FUNDING.yml",
            "the sponsor button: the owner's decision",
        ),
        (
            ".all-contributorsrc",
            "the contributors of the upstream project",
        ),
        (".github/workflows/release.yml", "none expected"),
    ];
    let stray = unexpected("gustavosett", allowed, &[]);
    assert!(
        stray.is_empty(),
        "these files name the upstream project; credit it in the README only, or list the file here with a reason: {stray:?}"
    );
}
