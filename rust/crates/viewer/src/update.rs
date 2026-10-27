//! `herdr-tui update`: replaces this program with the latest release, the way
//! `tool/install-tui.sh` installs one: the file and the release's `herdr-tui-SHA256SUMS` are
//! downloaded (with `curl`, else `wget`), the file is checked against the sums (`sha256sum`, else
//! `shasum`) and run once with `--version`, and only then put in place by a rename, so a
//! `herdr-tui` that is open keeps running. Nothing is trusted that was not checked, and a failure
//! at any step leaves the installed file as it was.
//!
//! The decisions are pure functions, so they are tested without a network; the steps that touch
//! the machine are small.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

/// Where releases are downloaded from: the latest one, unless `HERDR_TUI_BASE_URL` names a mirror
/// (or a folder, as `file:///path`, which is what the tests use).
const LATEST: &str = "https://github.com/tuan3w/herdr-mobile/releases/latest/download";
const RELEASES: &str = "https://github.com/tuan3w/herdr-mobile/releases/download";

/// The release file for a platform, as `std::env::consts` names it, or `None` where there is none.
#[must_use]
pub fn asset_for(os: &str, arch: &str) -> Option<&'static str> {
    match (os, arch) {
        ("linux", "x86_64") => Some("herdr-tui-linux-x86_64"),
        ("linux", "aarch64") => Some("herdr-tui-linux-aarch64"),
        ("macos", "aarch64") => Some("herdr-tui-macos-arm64"),
        ("macos", "x86_64") => Some("herdr-tui-macos-x86_64"),
        _ => None,
    }
}

/// The release file for this computer.
#[must_use]
pub fn asset() -> Option<&'static str> {
    asset_for(std::env::consts::OS, std::env::consts::ARCH)
}

/// The checksum a `SHA256SUMS` text lists for `asset` (`<hex>  <name>`, or `<hex> *<name>`).
#[must_use]
pub fn wanted_sum(sums: &str, asset: &str) -> Option<String> {
    sums.lines().find_map(|l| {
        let mut parts = l.split_whitespace();
        let (sum, name) = (parts.next()?, parts.next()?);
        let ok = sum.len() == 64 && sum.bytes().all(|b| b.is_ascii_hexdigit());
        (ok && name.trim_start_matches('*') == asset).then(|| sum.to_ascii_lowercase())
    })
}

/// `x.y.z` out of `herdr-tui 0.1.37` (what `--version` prints) or a bare `0.1.37`.
#[must_use]
pub fn version_of(text: &str) -> Option<(u64, u64, u64)> {
    let v = text.split_whitespace().last()?.trim_start_matches('v');
    let mut n = v.split('.').map(|p| p.parse::<u64>());
    Some((n.next()?.ok()?, n.next()?.ok()?, n.next()?.ok()?))
}

/// What to do about a downloaded, checked release.
#[derive(Debug, PartialEq, Eq)]
pub enum Step {
    /// It is this program's own file already.
    Current,
    /// Put it in place.
    Install,
    /// It is older than this program: never a downgrade.
    Older,
}

/// `own`/`new` are the sums of the installed file and the release's; the versions are what each
/// says it is. `pinned`: the person named this version, so going back to it is what they asked
/// for; only the latest release is never allowed to be a downgrade.
#[must_use]
pub fn decide(
    own: &str,
    new: &str,
    have: (u64, u64, u64),
    got: Option<(u64, u64, u64)>,
    pinned: bool,
) -> Step {
    if own.eq_ignore_ascii_case(new) {
        return Step::Current;
    }
    match got {
        Some(g) if g < have && !pinned => Step::Older,
        _ => Step::Install,
    }
}

fn have(cmd: &str) -> bool {
    Command::new(cmd)
        .arg("--version")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok()
}

/// Downloads `url` to `to` with curl, else wget.
fn fetch(url: &str, to: &Path) -> Result<(), String> {
    let status = if have("curl") {
        Command::new("curl")
            .args(["-fsSL", "--max-time", "120", "-o"])
            .arg(to)
            .arg(url)
            .stdin(Stdio::null())
            .status()
    } else if have("wget") {
        Command::new("wget")
            .args(["-q", "-T", "120", "-O"])
            .arg(to)
            .arg(url)
            .stdin(Stdio::null())
            .status()
    } else {
        return Err("needs curl or wget to download the release".to_string());
    };
    match status {
        Ok(s) if s.success() => Ok(()),
        _ => Err(format!(
            "could not download {url} (a release has a desk client from 0.1.30 on; check the version and the network)"
        )),
    }
}

/// What [`run`] tells the screen as it goes.
pub enum Event<'a> {
    /// A step begins.
    Step(&'a str),
    /// A file is arriving: bytes so far, the whole size when the server said it, bytes a second.
    Bytes {
        label: &'a str,
        done: u64,
        total: Option<u64>,
        per_sec: f64,
    },
    /// The file has arrived.
    Finished,
}

/// A size as a person reads it: `812 KB`, `2.5 MB`.
#[must_use]
pub fn human(bytes: u64) -> String {
    #[allow(clippy::cast_precision_loss)]
    let b = bytes as f64;
    if b >= 1_000_000.0 {
        format!("{:.1} MB", b / 1_000_000.0)
    } else if b >= 1_000.0 {
        format!("{:.0} KB", b / 1_000.0)
    } else {
        format!("{bytes} B")
    }
}

/// A bar `width` cells wide, filled to `frac` (0 to 1) in eighths of a cell, so it grows smoothly
/// rather than a cell at a time.
#[must_use]
pub fn bar(frac: f64, width: usize) -> String {
    const EIGHTHS: [char; 8] = [
        ' ', '\u{258f}', '\u{258e}', '\u{258d}', '\u{258c}', '\u{258b}', '\u{258a}', '\u{2589}',
    ];
    #[allow(
        clippy::cast_precision_loss,
        clippy::cast_possible_truncation,
        clippy::cast_sign_loss
    )]
    let eighths = (frac.clamp(0.0, 1.0) * (width * 8) as f64).round() as usize;
    let (full, part) = (eighths / 8, eighths % 8);
    let mut out = "\u{2588}".repeat(full);
    if full < width {
        out.push(EIGHTHS[part]);
        out.push_str(&" ".repeat(width - full - 1));
    }
    out
}

/// The progress line: what, a bar, the share, the sizes and the speed. Without a known total the
/// bar is left out and only what has arrived is said.
#[must_use]
pub fn progress_line(label: &str, done: u64, total: Option<u64>, per_sec: f64) -> String {
    #[allow(
        clippy::cast_precision_loss,
        clippy::cast_possible_truncation,
        clippy::cast_sign_loss
    )]
    let speed = if per_sec >= 1.0 {
        format!("  {}/s", human(per_sec as u64))
    } else {
        String::new()
    };
    match total.filter(|t| *t > 0) {
        Some(t) => {
            #[allow(clippy::cast_precision_loss)]
            let frac = (done as f64 / t as f64).min(1.0);
            #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
            let pct = (frac * 100.0).round() as u32;
            format!(
                "{label}  \u{2595}{}\u{258f} {pct:>3}%  {} / {}{speed}",
                bar(frac, 28),
                human(done),
                human(t)
            )
        }
        None => format!("{label}  {}{speed}", human(done)),
    }
}

/// Draws [`Event`]s on stderr: on a terminal one line that is redrawn as the download grows, else
/// one plain line per step (a log or a pipe gets no control characters).
pub struct Console {
    tty: bool,
    colour: bool,
    drawn: bool,
}

impl Console {
    #[must_use]
    pub fn new(tty: bool, colour: bool) -> Console {
        Console {
            tty,
            colour: tty && colour,
            drawn: false,
        }
    }

    pub fn event(&mut self, e: &Event) {
        use std::io::Write;
        let mut err = std::io::stderr();
        match e {
            Event::Step(what) => {
                let _ = writeln!(err, "herdr-tui: {what}");
            }
            Event::Bytes {
                label,
                done,
                total,
                per_sec,
            } if self.tty => {
                let line = progress_line(label, *done, *total, *per_sec);
                let (on, off) = if self.colour {
                    ("\x1b[36m", "\x1b[0m")
                } else {
                    ("", "")
                };
                let _ = write!(err, "\r\x1b[2K{on}{line}{off}");
                let _ = err.flush();
                self.drawn = true;
            }
            Event::Bytes { .. } => {}
            Event::Finished => {
                if std::mem::take(&mut self.drawn) {
                    let _ = writeln!(err);
                }
            }
        }
    }
}

/// The size the server says `url` has (after redirects), when it says.
fn content_length(url: &str) -> Option<u64> {
    let out = Command::new("curl")
        .args(["-fsSIL", "--max-time", "20", url])
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .filter_map(|l| {
            let (k, v) = l.split_once(':')?;
            k.eq_ignore_ascii_case("content-length")
                .then(|| v.trim().parse::<u64>().ok())
                .flatten()
        })
        .next_back()
}

/// Downloads `url` to `to`, telling `report` how far it has got: curl runs on its own and the file
/// it is writing is measured, so the screen never waits on the network. Without curl (wget) there
/// is no measure, and it says so.
fn download(
    url: &str,
    to: &Path,
    label: &str,
    report: &mut dyn FnMut(Event),
) -> Result<(), String> {
    if !have("curl") {
        report(Event::Step(&format!(
            "downloading {label} (no progress without curl)"
        )));
        return fetch(url, to);
    }
    let total = content_length(url);
    let started = std::time::Instant::now();
    let mut child = Command::new("curl")
        .args(["-fsSL", "--max-time", "300", "-o"])
        .arg(to)
        .arg(url)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| format!("could not start curl ({e})"))?;
    let measure = |done: u64| {
        #[allow(clippy::cast_precision_loss)]
        let per_sec = done as f64 / started.elapsed().as_secs_f64().max(0.001);
        (done, per_sec)
    };
    let status = loop {
        match child.try_wait() {
            Ok(Some(s)) => break s,
            Ok(None) => {
                let (done, per_sec) = measure(std::fs::metadata(to).map_or(0, |m| m.len()));
                report(Event::Bytes {
                    label,
                    done,
                    total,
                    per_sec,
                });
                std::thread::sleep(std::time::Duration::from_millis(60));
            }
            Err(e) => return Err(format!("could not wait for curl ({e})")),
        }
    };
    if !status.success() {
        report(Event::Finished);
        return Err(format!(
            "could not download {url} (a release has a desk client from 0.1.30 on; check the version and the network)"
        ));
    }
    let size = std::fs::metadata(to).map_or(0, |m| m.len());
    let (done, per_sec) = measure(size);
    report(Event::Bytes {
        label,
        done,
        total: Some(size),
        per_sec,
    });
    report(Event::Finished);
    Ok(())
}

/// The SHA-256 of a file, as lower-case hex, by `sha256sum` or `shasum`.
fn sha256(file: &Path) -> Result<String, String> {
    let out = if have("sha256sum") {
        Command::new("sha256sum").arg(file).output()
    } else if have("shasum") {
        Command::new("shasum")
            .args(["-a", "256"])
            .arg(file)
            .output()
    } else {
        return Err("needs sha256sum or shasum to check the download".to_string());
    }
    .map_err(|e| format!("could not check {}: {e}", file.display()))?;
    String::from_utf8_lossy(&out.stdout)
        .split_whitespace()
        .next()
        .filter(|s| s.len() == 64)
        .map(str::to_ascii_lowercase)
        .ok_or_else(|| format!("could not check {}", file.display()))
}

/// A private folder next to the program being replaced (the same file system, so the last step is
/// a rename), removed when dropped.
struct Scratch(PathBuf);

impl Scratch {
    fn beside(exe: &Path) -> Result<Scratch, String> {
        let dir = exe.parent().ok_or("this program has no folder")?;
        let path = dir.join(format!(".herdr-tui-update-{}", std::process::id()));
        std::fs::create_dir(&path).map_err(|e| {
            format!(
                "cannot write to {} ({e}); run it as a user who can, or install by hand with tool/install-tui.sh",
                dir.display()
            )
        })?;
        Ok(Scratch(path))
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// Updates the program at `exe` (version `current`) from `base` (the latest release, or the one
/// the person named: `pinned`); with `check_only`, only says whether that would change anything.
/// The sentence to print.
///
/// # Errors
/// A sentence saying what went wrong; the installed file is untouched.
pub fn run(
    exe: &Path,
    current: &str,
    base: &str,
    pinned: bool,
    check_only: bool,
    report: &mut dyn FnMut(Event),
) -> Result<String, String> {
    let asset = asset().ok_or_else(|| {
        format!(
            "no release build for {} {}",
            std::env::consts::OS,
            std::env::consts::ARCH
        )
    })?;
    let have_version = version_of(current).ok_or("this program does not know its own version")?;
    let scratch = Scratch::beside(exe)?;
    report(Event::Step(if pinned {
        "looking up that release"
    } else {
        "looking up the latest release"
    }));
    let sums_file = scratch.0.join("sums");
    fetch(&format!("{base}/herdr-tui-SHA256SUMS"), &sums_file)?;
    let sums = std::fs::read_to_string(&sums_file).map_err(|e| e.to_string())?;
    let want = wanted_sum(&sums, asset)
        .ok_or_else(|| format!("the release's checksums do not list {asset}"))?;
    let own = sha256(exe)?;
    if own == want {
        return Ok(format!("herdr-tui {current} is {}.", which(pinned)));
    }
    if check_only {
        return Ok(format!(
            "This herdr-tui ({current}) differs from {}. Run `herdr-tui update` to install it.",
            which(pinned)
        ));
    }
    let file = scratch.0.join(asset);
    download(&format!("{base}/{asset}"), &file, asset, report)?;
    report(Event::Step("checking the download"));
    let got = sha256(&file)?;
    if got != want {
        return Err(format!(
            "checksum mismatch for {asset} (wanted {want}, got {got}); nothing was installed"
        ));
    }
    set_executable(&file)?;
    let said = Command::new(&file)
        .arg("--version")
        .stdin(Stdio::null())
        .output()
        .map_err(|e| {
            format!("the download does not run on this computer ({e}); nothing was installed")
        })?;
    let said =
        String::from_utf8_lossy(&said.stderr).to_string() + &String::from_utf8_lossy(&said.stdout);
    let new_version = version_of(&said);
    match decide(&own, &want, have_version, new_version, pinned) {
        Step::Current => Ok(format!("herdr-tui {current} is {}.", which(pinned))),
        Step::Older => Err(format!(
            "the latest release ({}) is older than this herdr-tui ({current}); nothing was changed",
            said.trim()
        )),
        Step::Install => {
            report(Event::Step("installing"));
            // Renamed over the program, so one that is open keeps running its old file.
            std::fs::rename(&file, exe).map_err(|e| {
                format!(
                    "could not replace {} ({e}); nothing was changed",
                    exe.display()
                )
            })?;
            let now = said
                .trim()
                .strip_prefix("herdr-tui ")
                .unwrap_or(said.trim());
            let what = if now == current {
                format!("Replaced this build of herdr-tui {current} with the release's.")
            } else {
                format!("Installed herdr-tui {now} (was {current}).")
            };
            Ok(format!(
                "{what} Sessions that are open keep running the old one until you leave them (`herdr-tui attach ID` reopens one with the new)."
            ))
        }
    }
}

#[cfg(unix)]
fn set_executable(file: &Path) -> Result<(), String> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(file, std::fs::Permissions::from_mode(0o755))
        .map_err(|e| e.to_string())
}

#[cfg(not(unix))]
fn set_executable(_: &Path) -> Result<(), String> {
    Ok(())
}

fn which(pinned: bool) -> &'static str {
    if pinned {
        "that release"
    } else {
        "the latest release"
    }
}

/// The base URL releases are fetched from: a mirror, else the release named (`0.1.30` or
/// `v0.1.30`), else the latest.
#[must_use]
pub fn base_url(env: impl Fn(&str) -> Option<String>, version: Option<&str>) -> String {
    if let Some(b) = env("HERDR_TUI_BASE_URL")
        .map(|b| b.trim_end_matches('/').to_string())
        .filter(|b| !b.is_empty())
    {
        return b;
    }
    match version {
        Some(v) => format!("{RELEASES}/v{}", v.trim_start_matches('v')),
        None => LATEST.to_string(),
    }
}

/// Notices that the file this program was started from has been replaced (by `herdr-tui update`,
/// the install script, or the app), so a running session can offer to load the new one. It only
/// looks at the file's size, owner-visible identity and time, and runs the new file with
/// `--version` once per change; nothing is polled on a timer (the caller asks when something
/// already woke the screen).
pub struct Watch {
    path: PathBuf,
    stamp: Option<(u64, u64, i64, u64)>,
    current: String,
}

#[cfg(unix)]
fn stamp_of(path: &Path) -> Option<(u64, u64, i64, u64)> {
    use std::os::unix::fs::MetadataExt;
    let m = std::fs::metadata(path).ok()?;
    Some((m.dev(), m.ino(), m.mtime(), m.len()))
}

#[cfg(not(unix))]
fn stamp_of(_: &Path) -> Option<(u64, u64, i64, u64)> {
    None
}

impl Watch {
    /// Watches `exe`, which is `current` (the version this program is) as it stands now. A path
    /// the system reports as `... (deleted)` (a file already replaced) is read as the path it was.
    #[must_use]
    pub fn new(exe: &Path, current: &str) -> Watch {
        let shown = exe.to_string_lossy();
        let path = shown
            .strip_suffix(" (deleted)")
            .map_or_else(|| exe.to_path_buf(), PathBuf::from);
        Watch {
            stamp: stamp_of(&path),
            path,
            current: current.to_string(),
        }
    }

    /// The program to run to load the new version.
    #[must_use]
    pub fn path(&self) -> &Path {
        &self.path
    }

    /// `Some(version)` when the file changed since last asked and now holds a herdr-tui of a
    /// different version; `None` otherwise (nothing changed, it does not run, or it is the same
    /// version).
    pub fn poll(&mut self) -> Option<String> {
        let now = stamp_of(&self.path);
        if now == self.stamp {
            return None;
        }
        self.stamp = now;
        now?;
        let out = Command::new(&self.path)
            .arg("--version")
            .stdin(Stdio::null())
            .output()
            .ok()?;
        let said = String::from_utf8_lossy(&out.stderr).to_string()
            + &String::from_utf8_lossy(&out.stdout);
        version_of(&said)?;
        let v = said.trim().strip_prefix("herdr-tui ")?.to_string();
        (v != self.current).then_some(v)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SUM_A: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const SUM_B: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

    #[test]
    fn every_platform_the_release_builds_has_its_file_and_the_rest_none() {
        assert_eq!(asset_for("linux", "x86_64"), Some("herdr-tui-linux-x86_64"));
        assert_eq!(
            asset_for("linux", "aarch64"),
            Some("herdr-tui-linux-aarch64")
        );
        assert_eq!(asset_for("macos", "aarch64"), Some("herdr-tui-macos-arm64"));
        assert_eq!(asset_for("macos", "x86_64"), Some("herdr-tui-macos-x86_64"));
        assert_eq!(asset_for("windows", "x86_64"), None);
        assert_eq!(asset_for("linux", "riscv64"), None);
    }

    #[test]
    fn the_sum_of_a_file_is_found_by_its_exact_name_in_either_format() {
        let sums = format!("{SUM_A}  herdr-tui-linux-x86_64\n{SUM_B} *herdr-tui-macos-arm64\nnot a sum  herdr-tui-linux-aarch64\n");
        assert_eq!(
            wanted_sum(&sums, "herdr-tui-linux-x86_64").as_deref(),
            Some(SUM_A)
        );
        assert_eq!(
            wanted_sum(&sums, "herdr-tui-macos-arm64").as_deref(),
            Some(SUM_B)
        );
        assert_eq!(wanted_sum(&sums, "herdr-tui-linux-aarch64"), None);
        assert_eq!(wanted_sum(&sums, "herdr-tui-linux"), None);
    }

    #[test]
    fn a_version_is_read_from_what_the_program_prints() {
        assert_eq!(version_of("herdr-tui 0.1.37\n"), Some((0, 1, 37)));
        assert_eq!(version_of("0.1.9"), Some((0, 1, 9)));
        assert_eq!(version_of("herdr-tui nightly"), None);
        assert!(version_of("herdr-tui 0.1.10") > version_of("herdr-tui 0.1.9"));
    }

    #[test]
    fn the_same_file_is_current_a_newer_one_installs_and_an_older_one_never_does() {
        let have = (0, 1, 37);
        assert_eq!(decide(SUM_A, SUM_A, have, Some(have), false), Step::Current);
        assert_eq!(
            decide(SUM_A, SUM_B, have, Some((0, 1, 38)), false),
            Step::Install
        );
        assert_eq!(
            decide(SUM_A, SUM_B, have, Some((0, 1, 30)), false),
            Step::Older
        );
        // Asked for by name, an older release is installed: that is how a person goes back.
        assert_eq!(
            decide(SUM_A, SUM_B, have, Some((0, 1, 30)), true),
            Step::Install
        );
        // A local build of this very version is replaced by the release's.
        assert_eq!(decide(SUM_A, SUM_B, have, Some(have), false), Step::Install);
        // A download that will not say its version is still checked and installed.
        assert_eq!(decide(SUM_A, SUM_B, have, None, false), Step::Install);
    }

    #[cfg(unix)]
    #[test]
    fn a_replaced_file_that_says_a_new_version_is_noticed_once() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().expect("tempdir");
        let exe = dir.path().join("herdr-tui");
        let write = |v: &str| {
            let tmp = dir.path().join("next");
            std::fs::write(&tmp, format!("#!/bin/sh\necho 'herdr-tui {v}' >&2\n")).expect("write");
            std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o755)).expect("chmod");
            std::fs::rename(&tmp, &exe).expect("rename over");
        };
        write("0.1.37");
        let mut w = Watch::new(&exe, "0.1.37");
        assert_eq!(w.poll(), None, "nothing changed");
        write("0.1.37");
        assert_eq!(
            w.poll(),
            None,
            "replaced by the same version: nothing to offer"
        );
        write("0.1.38");
        assert_eq!(w.poll().as_deref(), Some("0.1.38"));
        assert_eq!(w.poll(), None, "said once, not on every look");
        std::fs::write(&exe, "not a program").expect("break it");
        assert_eq!(w.poll(), None, "a file that will not run is not offered");
    }

    #[test]
    fn sizes_read_as_a_person_says_them() {
        assert_eq!(human(812), "812 B");
        assert_eq!(human(812_345), "812 KB");
        assert_eq!(human(2_527_000), "2.5 MB");
    }

    #[test]
    fn the_bar_fills_in_eighths_never_past_its_width_and_keeps_its_width() {
        for width in [1, 10, 28] {
            for step in 0..=40 {
                let b = bar(f64::from(step) / 40.0, width);
                assert_eq!(b.chars().count(), width, "{step}/40 of {width}: {b:?}");
            }
        }
        assert_eq!(bar(0.0, 4), "    ");
        assert_eq!(bar(1.0, 4), "\u{2588}\u{2588}\u{2588}\u{2588}");
        assert_eq!(bar(0.5, 4), "\u{2588}\u{2588}  ");
        assert_eq!(bar(0.375, 4), "\u{2588}\u{258c}  ");
        assert_eq!(bar(7.0, 4), bar(1.0, 4), "over is full");
        assert_eq!(bar(-1.0, 4), bar(0.0, 4));
    }

    #[test]
    fn a_progress_line_says_the_share_the_sizes_and_the_speed_and_copes_without_a_total() {
        let l = progress_line(
            "herdr-tui-linux-x86_64",
            1_300_000,
            Some(2_600_000),
            1_200_000.0,
        );
        assert!(
            l.contains(" 50%") && l.contains("1.3 MB / 2.6 MB") && l.contains("1.2 MB/s"),
            "{l}"
        );
        let done = progress_line("x", 9, Some(5), 0.0);
        assert!(done.contains("100%"), "never past 100%: {done}");
        let unknown = progress_line("x", 2_000, None, 0.0);
        assert_eq!(unknown, "x  2 KB");
        assert!(!progress_line("x", 0, Some(0), 0.0).contains("NaN"));
    }

    #[test]
    fn a_mirror_replaces_the_release_and_a_blank_one_does_not() {
        assert_eq!(base_url(|_| None, None), LATEST);
        assert_eq!(base_url(|_| Some(String::new()), None), LATEST);
        assert_eq!(base_url(|_| Some("file:///r/".into()), None), "file:///r");
        assert_eq!(
            base_url(|_| Some("file:///r/".into()), Some("0.1.30")),
            "file:///r"
        );
        assert_eq!(
            base_url(|_| None, Some("0.1.30")),
            format!("{RELEASES}/v0.1.30")
        );
        assert_eq!(
            base_url(|_| None, Some("v0.1.30")),
            base_url(|_| None, Some("0.1.30"))
        );
    }
}
