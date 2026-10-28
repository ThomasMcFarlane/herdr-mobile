//! The update itself, step by step: look up the sums, download, check, try the file, and only then
//! rename it over the installed one. A failure or a signal at any step leaves the installed file as
//! it was.

use std::io;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};

use super::progress::Event;
use super::release::{asset, decide, named_version, version_of, wanted_sum, Step, Target, SUMS};
use super::tools::{download, fetch, sha256, version_said, CANCELLED};

/// What to do with it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Action {
    /// Download, check and install it.
    Install,
    /// Only say whether installing would change anything.
    Check,
}

/// What [`run`] is asked to do, besides the program to replace and the screen to tell.
#[derive(Debug)]
pub struct Plan<'a> {
    /// Where the release files are (see [`super::base_url`]).
    pub base: &'a str,
    pub target: Target,
    pub action: Action,
    /// Set by a signal handler: the update stops at its next step and removes what it made.
    pub cancel: &'a AtomicBool,
}

/// `result`, unless a signal asked the update to stop (curl dies with it, and its failure is not
/// what the person needs told).
fn unless_cancelled<T>(result: Result<T, String>, cancel: &AtomicBool) -> Result<T, String> {
    if cancel.load(Ordering::Relaxed) {
        Err(CANCELLED.to_string())
    } else {
        result
    }
}

/// A private folder next to the program being replaced (the same file system, so the last step is
/// a rename), removed when dropped.
struct Scratch(PathBuf);

impl Scratch {
    fn beside(exe: &Path) -> Result<Scratch, String> {
        let dir = exe.parent().ok_or("this program has no folder")?;
        let path = dir.join(format!(".herdr-tui-update-{}", std::process::id()));
        let denied = |e: io::Error| {
            format!(
                "cannot write to {} ({e}); run it as a user who can, or install by hand with tool/install-tui.sh",
                dir.display()
            )
        };
        match std::fs::create_dir(&path) {
            Ok(()) => {}
            // The name holds this process's id, so a folder already there is what an earlier run
            // with the same id left when it was killed mid-way.
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {
                let _ = std::fs::remove_dir_all(&path);
                std::fs::create_dir(&path).map_err(denied)?;
            }
            Err(e) => return Err(denied(e)),
        }
        Ok(Scratch(path))
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// Updates the program at `exe` (version `current`) as `plan` says; with [`Action::Check`], only
/// says whether that would change anything. The sentence to print.
///
/// # Errors
/// A sentence saying what went wrong; the installed file is untouched.
pub fn run(
    exe: &Path,
    current: &str,
    plan: &Plan,
    report: &mut dyn FnMut(Event),
) -> Result<String, String> {
    let cancel = plan.cancel;
    let asset = asset().ok_or_else(|| {
        format!(
            "no release build for {} {}",
            std::env::consts::OS,
            std::env::consts::ARCH
        )
    })?;
    let have_version = version_of(current).ok_or("this program does not know its own version")?;
    let scratch = Scratch::beside(exe)?;
    report(Event::Step(match plan.target {
        Target::Pinned => "looking up that release",
        Target::Latest => "looking up the latest release",
    }));
    let sums_file = scratch.0.join("sums");
    unless_cancelled(fetch(&format!("{}/{SUMS}", plan.base), &sums_file), cancel)?;
    let sums = std::fs::read_to_string(&sums_file)
        .map_err(|e| format!("could not read the downloaded checksums ({e})"))?;
    let want = wanted_sum(&sums, asset)
        .ok_or_else(|| format!("the release's checksums do not list {asset}"))?;
    let own = sha256(exe)?;
    let which = which(plan.target);
    if own == want {
        return Ok(format!("herdr-tui {current} is {which}."));
    }
    if plan.action == Action::Check {
        return Ok(format!(
            "This herdr-tui ({current}) differs from {which}. Run `herdr-tui update` to install it."
        ));
    }
    let file = scratch.0.join(asset);
    unless_cancelled(
        download(
            &format!("{}/{asset}", plan.base),
            &file,
            asset,
            cancel,
            report,
        ),
        cancel,
    )?;
    report(Event::Step("checking the download"));
    let got = sha256(&file)?;
    if got != want {
        return Err(format!(
            "checksum mismatch for {asset} (wanted {want}, got {got}); nothing was installed"
        ));
    }
    set_executable(&file)?;
    let said = version_said(&file).map_err(|e| {
        format!("the download does not run on this computer ({e}); nothing was installed")
    })?;
    match decide(have_version, version_of(&said), plan.target) {
        Step::Older => Err(format!(
            "the latest release ({}) is older than this herdr-tui ({current}); nothing was changed",
            said.trim()
        )),
        Step::Install => {
            unless_cancelled(Ok(()), cancel)?;
            report(Event::Step("installing"));
            // Renamed over the program, so one that is open keeps running its old file.
            std::fs::rename(&file, exe).map_err(|e| {
                format!(
                    "could not replace {} ({e}); nothing was changed",
                    exe.display()
                )
            })?;
            let now = named_version(&said).unwrap_or_else(|| said.trim());
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

fn set_executable(file: &Path) -> Result<(), String> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(file, std::fs::Permissions::from_mode(0o755))
        .map_err(|e| format!("could not make {} executable ({e})", file.display()))
}

fn which(target: Target) -> &'static str {
    match target {
        Target::Pinned => "that release",
        Target::Latest => "the latest release",
    }
}
