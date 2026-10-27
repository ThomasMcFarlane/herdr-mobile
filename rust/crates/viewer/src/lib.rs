//! The renderable core of herdr-tui: the session, the transcript and the
//! screen. The binary (`main.rs`) carries out the I/O this core asks for;
//! the benchmark (`benches/scroll.rs`) drives the same screen with no
//! terminal at all.

#![doc(hidden)]

pub mod composer;
pub mod delight;
pub mod diff;
pub mod fold;
pub mod herdr;
pub mod host;
pub mod input;
pub mod lines;
pub mod md;
pub mod session;
pub mod sessions;
pub mod shell;
pub mod termbg;
pub mod theme;
pub mod transcript;
pub mod ui;

pub mod cli;
