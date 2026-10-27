//! The keeper: a small process that owns one agent process, so the agent
//! outlives the client (phone or terminal) that started it. See
//! `docs/AGENT_SESSIONS.md`.
//!
//! The Python keeper (`app/lib/data/services/keeper_script.dart`) is the
//! reference. This crate must read and write the same files and speak the same
//! wire, because both implementations share `~/.herdr-mobile/keepers/`.

pub mod records;
pub mod replay_log;
pub mod routes;
pub mod search;

/// Exit codes of the keeper commands, shared with the app (`keeper_command.dart`).
pub mod exit {
    pub const USAGE: i32 = 64;
    /// The folder does not exist, or no such keeper.
    pub const GONE: i32 = 66;
    /// The keeper's agent has exited.
    pub const EXITED: i32 = 67;
    /// The agent is not installed on this host.
    pub const MISSING: i32 = 69;
    /// The agent failed `initialize`, or the keeper did not start.
    pub const FAILED: i32 = 70;
}
