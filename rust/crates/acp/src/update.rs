use serde_json::Value;

/// The part of a message chunk a client can show.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Content {
    Text(String),
    /// A non-text block (`image`, `audio`, `resource`, ...), by its `type`.
    Other(String),
}

/// One streamed piece of a message. Chunks with the same `message_id` join.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Chunk {
    pub message_id: Option<String>,
    pub content: Content,
}

/// What the agent is doing, from `state_update`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AgentState {
    Running,
    Idle,
    Other,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum ToolStatus {
    #[default]
    Pending,
    InProgress,
    Completed,
    Failed,
}

/// Something a tool call produced.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ToolContent {
    Text(String),
    Diff {
        path: String,
        old_text: Option<String>,
        new_text: String,
    },
}

/// A tool call, or an update to one: every field but the id may be absent in an
/// update, and a client merges what is present into what it has.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ToolCall {
    pub id: String,
    pub title: Option<String>,
    pub kind: Option<String>,
    pub status: Option<ToolStatus>,
    pub raw_input: Option<Value>,
    pub content: Vec<ToolContent>,
}

/// A `session/update` payload.
#[derive(Clone, Debug, PartialEq)]
pub enum SessionUpdate {
    AgentMessage(Chunk),
    UserMessage(Chunk),
    AgentThought(Chunk),
    ToolCall(ToolCall),
    ToolCallUpdate(ToolCall),
    State {
        state: AgentState,
        stop_reason: Option<String>,
    },
    /// `Some(None)` is a title that was cleared.
    SessionInfo {
        title: Option<Option<String>>,
    },
    /// The agent's mode changed (`plan`, `act`, ...).
    Mode(String),
    /// The session's config options changed (the model, the mode, the thinking level).
    Config(Vec<crate::ConfigOption>),
    /// How much of the context window is used.
    Usage {
        used: u64,
        size: u64,
    },
    /// Plans, command lists and anything newer, by `sessionUpdate`.
    Other(String),
}

impl SessionUpdate {
    /// Reads the `update` member of a `session/update` notification. `None`
    /// when it names no kind at all.
    #[must_use]
    pub fn from_value(u: &Value) -> Option<SessionUpdate> {
        let kind = u.get("sessionUpdate")?.as_str()?;
        Some(match kind {
            "agent_message_chunk" => SessionUpdate::AgentMessage(chunk(u)?),
            "user_message_chunk" => SessionUpdate::UserMessage(chunk(u)?),
            "agent_thought_chunk" => SessionUpdate::AgentThought(chunk(u)?),
            "tool_call" => SessionUpdate::ToolCall(ToolCall::from_value(u)?),
            "tool_call_update" => SessionUpdate::ToolCallUpdate(ToolCall::from_value(u)?),
            "state_update" => SessionUpdate::State {
                state: match str_of(u, "state") {
                    Some("running") => AgentState::Running,
                    Some("idle") => AgentState::Idle,
                    _ => AgentState::Other,
                },
                stop_reason: str_of(u, "stopReason").map(str::to_string),
            },
            "session_info_update" => SessionUpdate::SessionInfo {
                title: u.get("title").map(|t| {
                    t.as_str()
                        .filter(|s| !s.trim().is_empty())
                        .map(str::to_string)
                }),
            },
            "current_mode_update" => {
                match str_of(u, "currentModeId").or_else(|| str_of(u, "modeId")) {
                    Some(id) => SessionUpdate::Mode(id.to_string()),
                    None => SessionUpdate::Other(kind.to_string()),
                }
            }
            "config_option_update" => SessionUpdate::Config(crate::parse_config_options(
                u.get("configOptions").unwrap_or(&Value::Null),
            )),
            "usage_update" => match (
                u.get("used").and_then(Value::as_u64),
                u.get("size").and_then(Value::as_u64),
            ) {
                (Some(used), Some(size)) if size > 0 => SessionUpdate::Usage { used, size },
                _ => SessionUpdate::Other(kind.to_string()),
            },
            other => SessionUpdate::Other(other.to_string()),
        })
    }
}

fn str_of<'v>(v: &'v Value, key: &str) -> Option<&'v str> {
    v.get(key)?.as_str()
}

fn chunk(u: &Value) -> Option<Chunk> {
    let c = u.get("content")?;
    let content = match str_of(c, "type")? {
        "text" => Content::Text(str_of(c, "text").unwrap_or("").to_string()),
        other => Content::Other(other.to_string()),
    };
    Some(Chunk {
        message_id: str_of(u, "messageId").map(str::to_string),
        content,
    })
}

impl ToolCall {
    /// Reads a `tool_call` / `tool_call_update` (or a permission request's
    /// `toolCall`). `None` when it has no `toolCallId`.
    #[must_use]
    pub fn from_value(v: &Value) -> Option<ToolCall> {
        Some(ToolCall {
            id: str_of(v, "toolCallId")?.to_string(),
            title: str_of(v, "title")
                .filter(|t| !t.is_empty())
                .map(str::to_string),
            kind: str_of(v, "kind").map(str::to_string),
            status: str_of(v, "status").map(|s| match s {
                "completed" => ToolStatus::Completed,
                "failed" => ToolStatus::Failed,
                "in_progress" => ToolStatus::InProgress,
                _ => ToolStatus::Pending,
            }),
            raw_input: v.get("rawInput").cloned(),
            content: v
                .get("content")
                .and_then(Value::as_array)
                .map(|a| a.iter().filter_map(tool_content).collect())
                .unwrap_or_default(),
        })
    }

    /// What the call will run or touch, whole, as the agent sent it: its
    /// command (a string, or argv words), else its path. `None` when it names
    /// neither. Control characters are removed; newlines and tabs stay.
    ///
    /// Codex wraps a shell command as `[bash, -lc, script]`: the script is the
    /// command. Any other argv is shown shell-quoted, so what the person reads
    /// is what would be typed.
    #[must_use]
    pub fn subject(&self) -> Option<String> {
        let raw = self.raw_input.as_ref()?.as_object()?;
        let command = ["command", "cmd"]
            .iter()
            .find_map(|k| command_text(raw.get(*k)?));
        let text = command.or_else(|| {
            ["file_path", "path"]
                .iter()
                .find_map(|k| raw.get(*k)?.as_str().map(str::to_string))
        })?;
        let clean: String = text
            .replace('\t', "    ")
            .chars()
            .filter(|c| !is_unsafe_control(*c))
            .collect();
        let clean = clean.trim_matches('\n').to_string();
        (!clean.is_empty()).then_some(clean)
    }
}

fn tool_content(v: &Value) -> Option<ToolContent> {
    match str_of(v, "type")? {
        "diff" => Some(ToolContent::Diff {
            path: str_of(v, "path")?.to_string(),
            old_text: str_of(v, "oldText").map(str::to_string),
            new_text: str_of(v, "newText").unwrap_or("").to_string(),
        }),
        "content" => {
            let inner = v.get("content")?;
            (str_of(inner, "type") == Some("text"))
                .then(|| ToolContent::Text(str_of(inner, "text").unwrap_or("").to_string()))
        }
        _ => None,
    }
}

fn command_text(v: &Value) -> Option<String> {
    match v {
        Value::String(s) if !s.trim().is_empty() => Some(s.clone()),
        Value::Array(words) if !words.is_empty() => {
            let words: Vec<&str> = words.iter().map(Value::as_str).collect::<Option<_>>()?;
            if words.len() == 3 && matches!(words[1], "-c" | "-lc") {
                Some(words[2].to_string())
            } else {
                Some(
                    words
                        .iter()
                        .map(|w| shell_quote(w))
                        .collect::<Vec<_>>()
                        .join(" "),
                )
            }
        }
        _ => None,
    }
}

/// POSIX single-quoting, only where a word needs it.
fn shell_quote(word: &str) -> String {
    let safe = !word.is_empty()
        && word
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || "_@%+=:,./-".contains(c));
    if safe {
        word.to_string()
    } else {
        format!("'{}'", word.replace('\'', r#"'"'"'"#))
    }
}

/// What a terminal must not be sent from an agent's text: control characters
/// (an escape sequence could rewrite the screen). Newlines and tabs stay.
#[must_use]
pub fn is_unsafe_control(c: char) -> bool {
    // The C0 and C1 controls (an escape sequence could rewrite the screen), and the bidirectional
    // overrides and marks, which can make a command on a permission card read differently from what it is.
    matches!(c, '\u{0}'..='\u{8}' | '\u{b}'..='\u{1f}' | '\u{7f}'..='\u{9f}' | '\u{200e}' | '\u{200f}' | '\u{202a}'..='\u{202e}' | '\u{2066}'..='\u{2069}' | '\u{61c}')
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn tool(raw: Value) -> ToolCall {
        ToolCall {
            id: "t".into(),
            raw_input: Some(raw),
            ..ToolCall::default()
        }
    }

    #[test]
    fn chunks_carry_their_message_id_and_kind_of_content() {
        let u = json!({"sessionUpdate":"agent_message_chunk","messageId":"m1","content":{"type":"text","text":"hi"}});
        assert_eq!(
            SessionUpdate::from_value(&u),
            Some(SessionUpdate::AgentMessage(Chunk {
                message_id: Some("m1".into()),
                content: Content::Text("hi".into())
            }))
        );
        let img = json!({"sessionUpdate":"user_message_chunk","content":{"type":"image"}});
        assert!(matches!(
            SessionUpdate::from_value(&img),
            Some(SessionUpdate::UserMessage(Chunk {
                content: Content::Other(_),
                ..
            }))
        ));
    }

    #[test]
    fn the_mode_and_the_context_use_are_read() {
        let m = json!({"sessionUpdate": "current_mode_update", "currentModeId": "plan"});
        assert_eq!(
            SessionUpdate::from_value(&m),
            Some(SessionUpdate::Mode("plan".into()))
        );
        let u = json!({"sessionUpdate": "usage_update", "used": 47, "size": 100});
        assert_eq!(
            SessionUpdate::from_value(&u),
            Some(SessionUpdate::Usage {
                used: 47,
                size: 100
            })
        );
        // A window of size 0 says nothing: never a division by zero downstream.
        let z = json!({"sessionUpdate": "usage_update", "used": 1, "size": 0});
        assert_eq!(
            SessionUpdate::from_value(&z),
            Some(SessionUpdate::Other("usage_update".into()))
        );
    }

    #[test]
    fn an_unknown_kind_is_kept_and_a_missing_kind_is_none() {
        assert_eq!(
            SessionUpdate::from_value(&json!({"sessionUpdate":"plan"})),
            Some(SessionUpdate::Other("plan".into()))
        );
        assert_eq!(SessionUpdate::from_value(&json!({"foo":1})), None);
    }

    #[test]
    fn a_tool_update_may_carry_only_what_changed() {
        let u = json!({"sessionUpdate":"tool_call_update","toolCallId":"7","status":"completed"});
        let Some(SessionUpdate::ToolCallUpdate(t)) = SessionUpdate::from_value(&u) else {
            panic!("not a tool update")
        };
        assert_eq!(
            (t.id.as_str(), t.status, t.title),
            ("7", Some(ToolStatus::Completed), None)
        );
    }

    #[test]
    fn diffs_and_text_are_read_from_tool_content() {
        let u = json!({"toolCallId":"1","content":[
            {"type":"diff","path":"a.rs","oldText":"x","newText":"y"},
            {"type":"content","content":{"type":"text","text":"ok"}},
            {"type":"terminal","terminalId":"z"}]});
        let t = ToolCall::from_value(&u).expect("has an id");
        assert_eq!(t.content.len(), 2);
    }

    #[test]
    fn the_subject_is_the_command_whole_or_else_the_path() {
        assert_eq!(
            tool(json!({"command":"ls -la"})).subject().as_deref(),
            Some("ls -la")
        );
        assert_eq!(
            tool(json!({"cmd":["bash","-lc","cd x && make"]}))
                .subject()
                .as_deref(),
            Some("cd x && make")
        );
        assert_eq!(
            tool(json!({"command":["git","commit","-m","a b"]}))
                .subject()
                .as_deref(),
            Some("git commit -m 'a b'")
        );
        assert_eq!(
            tool(json!({"file_path":"/etc/hosts"})).subject().as_deref(),
            Some("/etc/hosts")
        );
        assert_eq!(tool(json!({"command":"  "})).subject(), None);
        assert_eq!(tool(json!({"other":1})).subject(), None);
    }

    #[test]
    fn the_subject_cannot_carry_an_escape_sequence() {
        let s = tool(json!({"command":"echo \u{1b}[2J hi\tthere"})).subject();
        assert_eq!(s.as_deref(), Some("echo [2J hi    there"));
    }

    #[test]
    fn a_command_cannot_be_disguised_with_bidirectional_overrides() {
        // U+202E reverses what follows: `rm -rf ~` could be made to read as something harmless.
        let s = tool(json!({"command": "echo \u{202e}txt.elif\u{202c} ; rm -rf ~"}))
            .subject()
            .expect("a subject");
        assert!(!s.chars().any(is_unsafe_control), "{s:?}");
        assert!(
            s.contains("rm -rf ~"),
            "the command itself is untouched: {s:?}"
        );
    }

    #[test]
    fn a_quote_inside_a_word_is_escaped() {
        assert_eq!(shell_quote("it's"), r#"'it'"'"'s'"#);
        assert_eq!(shell_quote(""), "''");
    }
}
