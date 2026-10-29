//! The renderable core of herdr-tui: the session, the transcript and the
//! screen. The binary (`main.rs`) carries out the I/O this core asks for;
//! the benchmark (`benches/scroll.rs`) drives the same screen with no
//! terminal at all.

#![doc(hidden)]

pub mod attach;
pub mod clip;
pub mod composer;
pub mod diff;
pub mod elapsed;
pub mod fold;
pub mod herdr;
pub mod highlight;
pub mod host;
pub mod input;
pub mod lines;
pub mod md;
pub mod question;
pub mod queue;
pub mod risk;
pub mod select;
pub mod session;
pub mod sessions;
pub mod shell;
pub mod slash;
pub mod termbg;
pub mod theme;
pub mod transcript;
pub mod ui;
pub mod update;
pub mod width;

#[cfg(test)]
pub mod shots;

pub mod cli;
