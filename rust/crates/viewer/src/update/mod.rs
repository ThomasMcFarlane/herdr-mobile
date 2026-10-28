//! `herdr-tui update`: replaces this program with the latest release, the way
//! `tool/install-tui.sh` installs one: the file and the release's `herdr-tui-SHA256SUMS` are
//! downloaded (with `curl`, else `wget`), the file is checked against the sums (`sha256sum`, else
//! `shasum`) and run once with `--version`, and only then put in place by a rename, so a
//! `herdr-tui` that is open keeps running. Nothing is trusted that was not checked, and a failure
//! at any step leaves the installed file as it was.
//!
//! One file per job, and what each may depend on:
//! - `release`: pure facts about releases (file names, sums, versions, URLs); depends on nothing.
//! - `progress`: what the person sees as it goes; depends on nothing.
//! - `tools`: the programs it runs (`curl`, `sha256sum`, the new file); reports to `progress`.
//! - `install`: the steps in order; uses all of the above.
//! - `watch`: a running session noticing its file was replaced; uses `release` and `tools`.

mod install;
mod progress;
mod release;
mod tools;
mod watch;

pub use install::{request, run, Action, Plan, Request};
pub use progress::{progress_line, Console, Event, Output};
pub use release::{asset, base_url, version_of, Target, Version};
pub use watch::{Change, Watch};
