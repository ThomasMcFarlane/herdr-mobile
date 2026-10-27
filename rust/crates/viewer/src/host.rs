//! Starting a keeper on this machine. The keeper is the python script the app
//! installs on hosts (`keeper_command.dart`); the desktop client runs it as a
//! command. A Rust keeper will replace this behind the same function.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

/// Why a keeper did not start, in words, with the exit code the command should end with.
#[derive(Debug, PartialEq, Eq)]
pub struct StartError {
    pub code: i32,
    pub message: String,
}

/// The keeper script to run: `$HERDR_KEEPER_SCRIPT`, else the one `tool/install-keeper.sh`
/// installed, else the newest one the app installed.
#[must_use]
pub fn find_script(home: &Path) -> Option<PathBuf> {
    if std::env::var_os("HERDR_KEEPER_SCRIPT").is_none() {
        if let Ok(path) = ensure_script(home) {
            return Some(path);
        }
    }
    find_installed(home)
}

/// The keeper this binary carries (python, agent table filled in at build time).
const EMBEDDED_KEEPER: &str = include_str!(concat!(env!("OUT_DIR"), "/keeper.py"));

/// Writes the embedded keeper to `~/.herdr-mobile/desktop/keeper-desktop.py` unless that file
/// already holds exactly it, and returns the path. Atomic (a rename), 0700, so a session being
/// started never runs a half-written file. A separate path from the phone's `keeper-<hash>.py`,
/// which the app deletes when it installs another version.
///
/// # Errors
/// When the folder or file cannot be written.
pub fn ensure_script(home: &Path) -> std::io::Result<PathBuf> {
    use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
    let dir = home.join(".herdr-mobile/desktop");
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(&dir)?;
    let path = dir.join("keeper-desktop.py");
    if std::fs::read_to_string(&path).is_ok_and(|have| have == EMBEDDED_KEEPER) {
        return Ok(path);
    }
    let tmp = dir.join(format!("keeper-desktop.py.{}.tmp", std::process::id()));
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o700)
        .open(&tmp)?;
    std::io::Write::write_all(&mut file, EMBEDDED_KEEPER.as_bytes())?;
    drop(file);
    std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o700))?;
    std::fs::rename(&tmp, &path)?;
    Ok(path)
}

/// A keeper that something else installed: the phone's, or `tool/install-keeper.sh`'s.
fn find_installed(home: &Path) -> Option<PathBuf> {
    if let Some(p) = std::env::var_os("HERDR_KEEPER_SCRIPT")
        .map(PathBuf::from)
        .filter(|p| p.is_file())
    {
        return Some(p);
    }
    let base = home.join(".herdr-mobile");
    let desktop = base.join("desktop/keeper-desktop.py");
    if desktop.is_file() {
        return Some(desktop);
    }
    let mut found: Vec<(std::time::SystemTime, PathBuf)> = std::fs::read_dir(&base)
        .ok()?
        .filter_map(Result::ok)
        .filter(|e| {
            let n = e.file_name();
            let n = n.to_string_lossy();
            n.starts_with("keeper-") && n.ends_with(".py")
        })
        .filter_map(|e| Some((e.metadata().ok()?.modified().ok()?, e.path())))
        .collect();
    found.sort();
    found.pop().map(|(_, p)| p)
}

/// Ends keeper `id` for good: its agent, its socket and, in herdr, its tab. The keeper's own `kill`
/// does it, so the checks that protect a recycled pid stay in one place.
///
/// # Errors
/// When python3 cannot run, or the keeper says no (no such session).
pub fn kill(script: &Path, id: &str) -> Result<(), StartError> {
    let out = Command::new("python3")
        .arg(script)
        .args(["kill", id])
        .stdin(Stdio::null())
        .output()
        .map_err(|e| StartError {
            code: keeper::exit::FAILED,
            message: format!("python3 could not run: {e}"),
        })?;
    if out.status.success() {
        return Ok(());
    }
    let said = String::from_utf8_lossy(&out.stderr);
    let said = said.trim().trim_start_matches("herdr-mobile: ");
    Err(StartError {
        code: out.status.code().unwrap_or(keeper::exit::FAILED),
        message: if said.is_empty() {
            "the keeper did not stop".to_string()
        } else {
            said.to_string()
        },
    })
}

/// This computer's name up to the first dot (`dev-box` for `dev-box.lan`), as the keeper tells other
/// clients which terminal is attached; `this computer` when it cannot be read.
#[must_use]
pub fn short_host() -> String {
    let raw = std::fs::read_to_string("/proc/sys/kernel/hostname")
        .ok()
        .or_else(|| std::env::var("HOSTNAME").ok())
        .unwrap_or_default();
    let short = crate::md::one_line(raw.trim().split('.').next().unwrap_or(""), 64);
    if short.is_empty() {
        "this computer".to_string()
    } else {
        short
    }
}

/// Starts a keeper for `agent` in `cwd` and returns its id. The keeper outlives this process.
///
/// # Errors
/// When there is no script, python3 is missing, or the keeper refuses (agent not installed,
/// folder missing, the agent failing `initialize`).
pub fn start(script: &Path, agent: &str, cwd: &Path) -> Result<String, StartError> {
    let out = Command::new("python3")
        .arg(script)
        .args(["start", "--agent", agent, "--cwd"])
        .arg(cwd)
        .stdin(Stdio::null())
        // The viewer is the pane: the keeper must not open a second herdr tab running the python
        // `view` of the same session (this client reports to herdr itself, see herdr.rs).
        .env("HERDR_MOBILE_NO_PANE", "1")
        .output()
        .map_err(|e| StartError {
            code: keeper::exit::FAILED,
            message: format!("python3 could not run: {e}"),
        })?;
    if !out.status.success() {
        let said = String::from_utf8_lossy(&out.stderr);
        let said = said.trim().trim_start_matches("herdr-mobile: ");
        return Err(StartError {
            code: out.status.code().unwrap_or(keeper::exit::FAILED),
            message: if said.is_empty() {
                "the keeper did not start".to_string()
            } else {
                said.to_string()
            },
        });
    }
    let line = String::from_utf8_lossy(&out.stdout);
    let info: serde_json::Value =
        serde_json::from_str(line.lines().next().unwrap_or("")).map_err(|_| StartError {
            code: keeper::exit::FAILED,
            message: "the keeper started but its answer could not be read".to_string(),
        })?;
    info.get("id")
        .and_then(serde_json::Value::as_str)
        .filter(|id| keeper::records::is_valid_id(id))
        .map(str::to_string)
        .ok_or(StartError {
            code: keeper::exit::FAILED,
            message: "the keeper named no session".to_string(),
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_desktop_install_wins_over_the_apps_and_the_newest_app_script_is_next() {
        let home = tempfile::tempdir().expect("tempdir");
        let base = home.path().join(".herdr-mobile");
        std::fs::create_dir_all(base.join("desktop")).expect("mkdir");
        assert_eq!(find_installed(home.path()), None);
        std::fs::write(base.join("keeper-aaa.py"), "x").expect("write");
        std::thread::sleep(std::time::Duration::from_millis(20));
        std::fs::write(base.join("keeper-bbb.py"), "x").expect("write");
        std::fs::write(base.join("other.py"), "x").expect("write");
        assert_eq!(
            find_installed(home.path()),
            Some(base.join("keeper-bbb.py"))
        );
        std::fs::write(base.join("desktop/keeper-desktop.py"), "x").expect("write");
        assert_eq!(
            find_installed(home.path()),
            Some(base.join("desktop/keeper-desktop.py"))
        );
    }

    #[test]
    fn the_binary_carries_a_keeper_and_installs_it_once_private_and_whole() {
        use std::os::unix::fs::PermissionsExt;
        let home = tempfile::tempdir().expect("tempdir");
        let path = ensure_script(home.path()).expect("installs");
        assert_eq!(
            path,
            home.path().join(".herdr-mobile/desktop/keeper-desktop.py")
        );
        let text = std::fs::read_to_string(&path).expect("read");
        assert!(
            text.contains("herdr-keeper") && !text.contains("@@ROUTES@@"),
            "the agent table is filled in"
        );
        assert_eq!(
            std::fs::metadata(&path).expect("meta").permissions().mode() & 0o777,
            0o700
        );
        std::fs::write(&path, "stale").expect("write");
        assert_eq!(ensure_script(home.path()).expect("again"), path);
        assert_eq!(
            std::fs::read_to_string(&path).expect("read"),
            text,
            "a stale copy is replaced"
        );
        let leftovers = std::fs::read_dir(path.parent().expect("dir"))
            .expect("ls")
            .count();
        assert_eq!(leftovers, 1, "no temp file is left behind");
    }

    #[test]
    fn a_keeper_that_refuses_gives_its_words_and_its_exit_code() {
        let dir = tempfile::tempdir().expect("tempdir");
        let script = dir.path().join("k.py");
        std::fs::write(&script, "import sys\nsys.stderr.write('herdr-mobile: omp is not installed on this host\\n')\nsys.exit(69)\n").expect("write");
        let err = start(&script, "omp", dir.path()).expect_err("refused");
        assert_eq!(
            err,
            StartError {
                code: 69,
                message: "omp is not installed on this host".into()
            }
        );
    }

    #[test]
    fn the_keeper_is_told_not_to_open_a_second_pane_for_a_session_the_person_is_looking_at() {
        let dir = tempfile::tempdir().expect("tempdir");
        let script = dir.path().join("k.py");
        // Answers with a valid id only when it was told.
        std::fs::write(&script, "import os\nprint('{\"id\":\"abc123\"}' if os.environ.get('HERDR_MOBILE_NO_PANE') == '1' else '{\"id\":\"BAD\"}')\n").expect("write");
        assert_eq!(start(&script, "omp", dir.path()), Ok("abc123".to_string()));
    }

    #[test]
    fn killing_reports_what_the_keeper_says_and_succeeds_quietly() {
        let dir = tempfile::tempdir().expect("tempdir");
        let ok = dir.path().join("ok.py");
        std::fs::write(
            &ok,
            "import sys\nsys.exit(0 if sys.argv[1:] == ['kill', 'abc123'] else 9)\n",
        )
        .expect("write");
        assert_eq!(kill(&ok, "abc123"), Ok(()), "it is asked to `kill abc123`");
        let no = dir.path().join("no.py");
        std::fs::write(&no, "import sys\nsys.stderr.write('herdr-mobile: no such keeper: zzz999\\n')\nsys.exit(66)\n").expect("write");
        assert_eq!(
            kill(&no, "zzz999"),
            Err(StartError {
                code: 66,
                message: "no such keeper: zzz999".into()
            })
        );
    }

    #[test]
    fn the_host_name_is_short_one_line_and_never_empty() {
        let h = short_host();
        assert!(
            !h.is_empty() && !h.contains('.') && !h.chars().any(char::is_control),
            "{h:?}"
        );
    }

    #[test]
    fn a_started_keeper_gives_its_id_and_nonsense_is_not_an_id() {
        let dir = tempfile::tempdir().expect("tempdir");
        let ok = dir.path().join("ok.py");
        std::fs::write(&ok, "print('{\"id\":\"abc123\",\"agent\":\"omp\"}')\n").expect("write");
        assert_eq!(start(&ok, "omp", dir.path()), Ok("abc123".to_string()));
        let bad = dir.path().join("bad.py");
        std::fs::write(&bad, "print('{\"id\":\"../x\"}')\n").expect("write");
        assert!(start(&bad, "omp", dir.path()).is_err());
    }
}
