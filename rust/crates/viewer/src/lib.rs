//! The renderable core of herdr-tui: the session, the transcript and the
//! screen. The binary (`main.rs`) carries out the I/O this core asks for;
//! the benchmark (`benches/scroll.rs`) drives the same screen with no
//! terminal at all.

#![doc(hidden)]

pub mod attach;
pub mod composer;
pub mod delight;
pub mod diff;
pub mod fold;
pub mod herdr;
pub mod highlight;
pub mod host;
pub mod input;
pub mod lines;
pub mod md;
pub mod question;
pub mod risk;
pub mod session;
pub mod sessions;
pub mod shell;
pub mod slash;
pub mod termbg;
pub mod theme;
pub mod transcript;
pub mod ui;
pub mod update;

#[cfg(test)]
pub mod shots;

pub mod cli;
