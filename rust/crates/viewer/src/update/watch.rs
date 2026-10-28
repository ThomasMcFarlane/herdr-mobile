//! Noticing, in a running session, that its program file was replaced by a newer one.

use std::path::{Path, PathBuf};

use super::release::named_version;
use super::tools::version_said;

/// What [`Watch::poll`] found.
#[derive(Debug, PartialEq, Eq)]
pub enum Change {
    /// The file is as it was when last asked.
    Unchanged,
    /// The file was replaced by a herdr-tui of this other version.
    Offer(String),
    /// The file changed, and holds nothing to offer now: it is the running version, it does not
    /// run, or it is gone. An earlier offer no longer stands.
    Withdraw,
}

/// What identifies a file's contents without reading them: a replaced file has a new inode, and
/// one written in place a new time or size.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Stamp {
    dev: u64,
    ino: u64,
    mtime: i64,
    mtime_nsec: i64,
    len: u64,
}

fn stamp_of(path: &Path) -> Option<Stamp> {
    use std::os::unix::fs::MetadataExt;
    let m = std::fs::metadata(path).ok()?;
    Some(Stamp {
        dev: m.dev(),
        ino: m.ino(),
        mtime: m.mtime(),
        mtime_nsec: m.mtime_nsec(),
        len: m.len(),
    })
}

/// Notices that the file this program was started from has been replaced (by `herdr-tui update`,
/// the install script, or the app), so a running session can offer to load the new one. It looks
/// at the file's identity, size and time, and runs the new file with `--version` once per change
/// (given a few seconds to answer); nothing is polled on a timer (the caller asks when
/// something already woke the screen).
#[derive(Debug)]
pub struct Watch {
    path: PathBuf,
    stamp: Option<Stamp>,
    current: String,
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

    /// Looks at the file: [`Change::Offer`] when it changed since last asked and now holds a
    /// herdr-tui of a different version, [`Change::Withdraw`] when it changed and holds nothing to
    /// offer, so a banner for an earlier change does not outlive it.
    pub fn poll(&mut self) -> Change {
        let now = stamp_of(&self.path);
        if now == self.stamp {
            return Change::Unchanged;
        }
        self.stamp = now;
        let said = now.and_then(|_| version_said(&self.path).ok());
        match said.as_deref().and_then(named_version) {
            Some(v) if v != self.current => Change::Offer(v.to_string()),
            _ => Change::Withdraw,
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_replaced_file_is_offered_once_and_the_offer_is_withdrawn_when_it_stops_standing() {
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
        assert_eq!(w.poll(), Change::Unchanged);
        write("0.1.37");
        assert_eq!(
            w.poll(),
            Change::Withdraw,
            "replaced by the running version: nothing to offer"
        );
        write("0.1.38");
        assert_eq!(w.poll(), Change::Offer("0.1.38".into()));
        assert_eq!(w.poll(), Change::Unchanged, "said once, not on every look");
        write("0.1.37");
        assert_eq!(
            w.poll(),
            Change::Withdraw,
            "rolled back to the running version: the banner must go"
        );
        write("0.1.38");
        assert_eq!(w.poll(), Change::Offer("0.1.38".into()));
        std::fs::write(&exe, "not a program").expect("break it");
        assert_eq!(
            w.poll(),
            Change::Withdraw,
            "a file that will not run is not offered"
        );
        std::fs::remove_file(&exe).expect("remove");
        assert_eq!(w.poll(), Change::Withdraw, "a file that is gone neither");
    }
}
