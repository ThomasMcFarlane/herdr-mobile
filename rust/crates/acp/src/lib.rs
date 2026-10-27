//! The wire between a client, the keeper and an agent: JSON-RPC 2.0 lines and
//! the parts of the Agent Client Protocol (ACP) herdr uses.
//!
//! Pure and synchronous: no sockets, no threads, no terminal. Agents differ in
//! what they send, so parsing is tolerant. A field that is missing or of an
//! unexpected type is absent, never an error, and an unknown update kind is kept
//! as [`SessionUpdate::Other`]. Only a line that is not a JSON-RPC message at
//! all is rejected.

mod config;
mod permission;
mod rpc;
mod update;

pub use config::{legacy_models, parse_config_options, ConfigOption};
pub use permission::{outcome_cancelled, outcome_selected, PermissionOption, PermissionRequest};
pub use rpc::{Id, Message, ParseError, RpcError};
pub use update::{
    is_unsafe_control, AgentState, Chunk, Content, SessionUpdate, ToolCall, ToolContent, ToolStatus,
};

/// Method names the keeper and clients exchange.
pub mod method {
    pub const INITIALIZE: &str = "initialize";
    pub const SESSION_NEW: &str = "session/new";
    pub const SESSION_LOAD: &str = "session/load";
    pub const SESSION_PROMPT: &str = "session/prompt";
    pub const SESSION_CANCEL: &str = "session/cancel";
    pub const SESSION_UPDATE: &str = "session/update";
    pub const REQUEST_PERMISSION: &str = "session/request_permission";
    pub const ELICITATION_CREATE: &str = "elicitation/create";
    pub const CANCEL_REQUEST: &str = "$/cancel_request";
    /// Keeper to client: another client answered a request.
    pub const HERDR_RESOLVED: &str = "_herdr/resolved";
    /// Keeper to client: the agent process is gone.
    pub const HERDR_AGENT_EXITED: &str = "_herdr/agent_exited";
}

/// JSON-RPC and keeper error codes.
pub mod code {
    pub const METHOD_NOT_FOUND: i64 = -32601;
    /// A prompt arrived while the session is already working on one.
    pub const SESSION_BUSY: i64 = -32003;
}
