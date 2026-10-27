//! `herdr-tui ls` and `kill` against an empty, private HOME: no agent is ever started here.

use std::process::{Command, Output};

fn run(home: &std::path::Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_herdr-tui"))
        .args(args)
        .env_clear()
        .env("HOME", home)
        .env("PATH", "/usr/bin:/bin")
        .env("HERDR_MOBILE_NO_PANE", "1")
        .output()
        .expect("run herdr-tui")
}

#[test]
fn ls_on_a_machine_with_no_sessions_says_how_to_start() {
    let home = tempfile::tempdir().expect("tempdir");
    let out = run(home.path(), &["ls"]);
    assert!(out.status.success(), "{out:?}");
    assert!(String::from_utf8_lossy(&out.stdout).contains("Start one with `herdr-tui`"));
}

#[test]
fn killing_a_session_that_does_not_exist_fails_and_says_which() {
    let home = tempfile::tempdir().expect("tempdir");
    let out = run(home.path(), &["kill", "zzz999"]);
    assert!(!out.status.success(), "{out:?}");
    assert!(
        String::from_utf8_lossy(&out.stderr).contains("zzz999"),
        "{out:?}"
    );
}

#[test]
fn kill_without_an_id_is_a_usage_error_not_a_bulk_kill() {
    let home = tempfile::tempdir().expect("tempdir");
    let out = run(home.path(), &["kill"]);
    assert_eq!(out.status.code(), Some(64), "{out:?}");
}

/// `update` against a folder standing in for a release: the installed file is a copy of the real
/// binary in a private folder, the "release" is a script that says its version.
mod update {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    use std::path::{Path, PathBuf};

    fn sha(file: &Path) -> Option<String> {
        let out = Command::new("sha256sum").arg(file).output().ok()?;
        Some(
            String::from_utf8_lossy(&out.stdout)
                .split_whitespace()
                .next()?
                .to_string(),
        )
    }

    struct Rig {
        _dir: tempfile::TempDir,
        installed: PathBuf,
        mirror: PathBuf,
        home: PathBuf,
    }

    /// `None` where curl or sha256sum is missing (the command needs them, as the installer does).
    fn rig(release_says: &str) -> Option<Rig> {
        Command::new("curl").arg("--version").output().ok()?;
        let dir = tempfile::tempdir().expect("tempdir");
        let (bin, mirror, home) = (
            dir.path().join("bin"),
            dir.path().join("mirror"),
            dir.path().join("home"),
        );
        for d in [&bin, &mirror, &home] {
            std::fs::create_dir_all(d).expect("mkdir");
        }
        let installed = bin.join("herdr-tui");
        std::fs::copy(env!("CARGO_BIN_EXE_herdr-tui"), &installed).expect("copy");
        let asset = herdr_tui::update::asset()?;
        let file = mirror.join(asset);
        std::fs::write(
            &file,
            format!("#!/bin/sh\necho 'herdr-tui {release_says}' >&2\n"),
        )
        .expect("asset");
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o755)).expect("chmod");
        std::fs::write(
            mirror.join("herdr-tui-SHA256SUMS"),
            format!("{}  {asset}\n", sha(&file)?),
        )
        .expect("sums");
        Some(Rig {
            _dir: dir,
            installed,
            mirror,
            home,
        })
    }

    fn update(r: &Rig, args: &[&str]) -> Output {
        Command::new(&r.installed)
            .arg("update")
            .args(args)
            .env_clear()
            .env("HOME", &r.home)
            .env("PATH", "/usr/bin:/bin")
            .env(
                "HERDR_TUI_BASE_URL",
                format!("file://{}", r.mirror.display()),
            )
            .output()
            .expect("run update")
    }

    fn version(file: &Path) -> String {
        let out = Command::new(file).arg("--version").output().expect("run");
        String::from_utf8_lossy(&out.stderr).trim().to_string()
    }

    #[test]
    fn a_newer_release_replaces_the_file_and_an_open_copy_is_not_needed() {
        let Some(r) = rig("99.0.0") else { return };
        let out = update(&r, &[]);
        assert!(out.status.success(), "{out:?}");
        assert_eq!(version(&r.installed), "herdr-tui 99.0.0");
        assert!(
            std::fs::read_dir(r.installed.parent().expect("a folder"))
                .expect("readable")
                .all(|e| {
                    let n = e.expect("an entry").file_name();
                    !n.to_string_lossy().starts_with(".herdr-tui-update")
                }),
            "nothing is left beside it"
        );
    }

    #[test]
    fn check_says_so_and_changes_nothing() {
        let Some(r) = rig("99.0.0") else { return };
        let before = version(&r.installed);
        let out = update(&r, &["--check"]);
        assert!(out.status.success(), "{out:?}");
        assert!(
            String::from_utf8_lossy(&out.stdout).contains("differs"),
            "{out:?}"
        );
        assert_eq!(version(&r.installed), before);
    }

    #[test]
    fn a_download_that_does_not_match_its_checksum_is_never_installed() {
        let Some(r) = rig("99.0.0") else { return };
        let before = version(&r.installed);
        let asset = herdr_tui::update::asset().expect("asset");
        std::fs::write(
            r.mirror.join(asset),
            "#!/bin/sh\necho 'herdr-tui 98.0.0' >&2\n",
        )
        .expect("tamper");
        let out = update(&r, &[]);
        assert!(!out.status.success(), "{out:?}");
        assert!(
            String::from_utf8_lossy(&out.stderr).contains("checksum mismatch"),
            "{out:?}"
        );
        assert_eq!(version(&r.installed), before);
    }

    #[test]
    fn the_latest_is_never_a_downgrade_but_a_named_version_is_installed_even_if_older() {
        let Some(r) = rig("0.0.1") else { return };
        let before = version(&r.installed);
        let out = update(&r, &[]);
        assert!(!out.status.success(), "{out:?}");
        assert!(
            String::from_utf8_lossy(&out.stderr).contains("older"),
            "{out:?}"
        );
        assert_eq!(version(&r.installed), before);
        // Asked for by name: the mirror stands in for that release.
        let out = update(&r, &["0.0.1"]);
        assert!(out.status.success(), "{out:?}");
        assert_eq!(version(&r.installed), "herdr-tui 0.0.1");
    }
}
