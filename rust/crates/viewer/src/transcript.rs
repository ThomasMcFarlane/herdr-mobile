//! The conversation as the person sees it, kept small.
//!
//! Pure: no I/O and no clock. Memory is bounded here, in one place: the store
//! holds at most a byte budget, dropping the oldest items first (and counting
//! them, so the screen can say so), and a tool call keeps only the head and the
//! tail of its output. The keeper still has everything.

use acp::{AgentState, Chunk, Content, SessionUpdate, ToolCall, ToolContent, ToolStatus};
use std::collections::{BTreeSet, HashMap, VecDeque};

/// Bytes the store may hold before it drops its oldest items.
pub const DEFAULT_BUDGET: usize = 8 << 20;
/// Lines of a tool's output kept from its start and from its end.
const OUTPUT_HEAD: usize = 12;
const OUTPUT_TAIL: usize = 12;
/// A diff keeps at most this much text per side, and a call at most this many diffs.
const DIFF_SIDE_MAX: usize = 16 * 1024;
const DIFFS_PER_CALL: usize = 3;
/// How far back a chunk looks for the message it continues.
const LOOKBACK: usize = 64;
/// What an item costs besides its text.
const ITEM_OVERHEAD: usize = 64;

/// What a turn did, counted from its tool calls.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Stats {
    pub files: usize,
    pub added: usize,
    pub removed: usize,
    pub tools: usize,
    pub failed: usize,
    /// The last tool call of the turn failed: nothing came after to put it right.
    pub ended_failed: bool,
}

impl Stats {
    /// `Done in 41s · 1 file +6 −2 · 4 tools · 1 failed`.
    #[must_use]
    pub fn summary(&self, secs: u64) -> String {
        let mut parts = vec![format!("Done in {}", crate::delight::duration(secs))];
        if self.files > 0 {
            parts.push(format!(
                "{} file{} +{} −{}",
                self.files,
                if self.files == 1 { "" } else { "s" },
                self.added,
                self.removed
            ));
        }
        if self.tools > 0 {
            parts.push(format!(
                "{} tool{}",
                self.tools,
                if self.tools == 1 { "" } else { "s" }
            ));
        }
        if self.failed > 0 {
            parts.push(format!("{} failed", self.failed));
        }
        parts.join(" · ")
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Role {
    User,
    Agent,
    Thought,
}

/// The head and tail of what a tool printed, and how many lines lie between.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Output {
    pub head: Vec<String>,
    pub tail: Vec<String>,
    pub omitted: usize,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Diff {
    pub path: String,
    pub old: Option<String>,
    pub new: String,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Tool {
    pub id: String,
    pub title: String,
    pub kind: Option<String>,
    pub status: ToolStatus,
    /// The command or path, whole.
    pub subject: Option<String>,
    pub output: Output,
    pub diffs: Vec<Diff>,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Entry {
    Message {
        role: Role,
        message_id: Option<String>,
        text: String,
    },
    Tool(Tool),
    Note(String),
    /// The end of a turn, said once: how long, and what changed.
    Done {
        text: String,
        ok: bool,
    },
}

/// An entry with a stable id (a cache key) and a revision (bumped on change).
#[derive(Clone, Debug)]
pub struct Item {
    pub id: u64,
    pub rev: u64,
    pub entry: Entry,
    size: usize,
}

#[derive(Debug)]
pub struct Transcript {
    items: VecDeque<Item>,
    bytes: usize,
    budget: usize,
    next_id: u64,
    dropped: usize,
    running: bool,
    title: Option<String>,
    mode: Option<String>,
    context: Option<u8>,
    config: Vec<acp::ConfigOption>,
    /// Tool call id -> the id of the item that shows it, however long ago it began.
    tool_at: HashMap<String, u64>,
    /// Items whose tool call has not finished: the ones a turn's end must close.
    open_tools: BTreeSet<u64>,
}

impl Default for Transcript {
    fn default() -> Self {
        Transcript::new(DEFAULT_BUDGET)
    }
}

impl Transcript {
    #[must_use]
    pub fn new(budget: usize) -> Transcript {
        Transcript {
            items: VecDeque::new(),
            bytes: 0,
            budget,
            next_id: 0,
            dropped: 0,
            running: false,
            title: None,
            mode: None,
            context: None,
            config: Vec::new(),
            tool_at: HashMap::new(),
            open_tools: BTreeSet::new(),
        }
    }

    #[must_use]
    pub fn items(&self) -> &VecDeque<Item> {
        &self.items
    }
    /// Items dropped from the start to stay in budget.
    #[must_use]
    pub fn dropped(&self) -> usize {
        self.dropped
    }
    #[must_use]
    #[cfg_attr(
        not(test),
        expect(
            dead_code,
            reason = "the memory check in the verification step reads it"
        )
    )]
    pub fn bytes(&self) -> usize {
        self.bytes
    }
    /// Whether the agent is working on a turn.
    #[must_use]
    pub fn running(&self) -> bool {
        self.running
    }
    /// The agent's current mode, when it has said.
    #[must_use]
    pub fn mode(&self) -> Option<&str> {
        self.config_value("mode").or(self.mode.as_deref())
    }
    /// The model, by name, when the agent has said.
    #[must_use]
    pub fn model(&self) -> Option<&str> {
        self.config_value("model")
    }
    /// The thinking level, when the agent has said.
    #[must_use]
    pub fn thinking(&self) -> Option<&str> {
        self.config_value("thought_level")
            .or_else(|| self.config_value("thinking"))
    }
    fn config_value(&self, what: &str) -> Option<&str> {
        self.config
            .iter()
            .find(|o| o.is(what))
            .and_then(acp::ConfigOption::current_name)
    }
    /// Percent of the context window used, when the agent has said.
    #[must_use]
    pub fn context(&self) -> Option<u8> {
        self.context
    }
    #[must_use]
    pub fn title(&self) -> Option<&str> {
        self.title.as_deref()
    }

    /// Says what the turn just ended did.
    pub fn done(&mut self, secs: u64) {
        let stats = self.turn_stats();
        self.push(Entry::Done {
            text: stats.summary(secs),
            ok: !stats.ended_failed,
        });
    }

    /// What the turn since the person's last message did.
    #[must_use]
    pub fn turn_stats(&self) -> Stats {
        let mut stats = Stats::default();
        let mut paths: Vec<&str> = Vec::new();
        for item in self.items.iter().rev() {
            match &item.entry {
                Entry::Message {
                    role: Role::User, ..
                } => break,
                Entry::Tool(t) => {
                    if stats.tools == 0 {
                        stats.ended_failed = t.status == ToolStatus::Failed;
                    }
                    stats.tools += 1;
                    stats.failed += usize::from(t.status == ToolStatus::Failed);
                    for d in &t.diffs {
                        let h = crate::diff::hunk(d);
                        stats.added += h.added;
                        stats.removed += h.removed;
                        if !paths.contains(&d.path.as_str()) {
                            paths.push(&d.path);
                        }
                    }
                }
                _ => {}
            }
        }
        stats.files = paths.len();
        stats
    }

    pub fn note(&mut self, text: impl Into<String>) {
        self.push(Entry::Note(text.into()));
    }

    /// The person's own message, shown at once (the keeper does not echo a
    /// prompt back to the client that sent it).
    pub fn user(&mut self, text: impl Into<String>) {
        self.push(Entry::Message {
            role: Role::User,
            message_id: None,
            text: text.into(),
        });
    }

    pub fn apply(&mut self, update: SessionUpdate) {
        match update {
            SessionUpdate::AgentMessage(c) => self.chunk(Role::Agent, c),
            SessionUpdate::UserMessage(c) => self.chunk(Role::User, c),
            SessionUpdate::AgentThought(c) => self.chunk(Role::Thought, c),
            SessionUpdate::ToolCall(call) | SessionUpdate::ToolCallUpdate(call) => self.tool(&call),
            SessionUpdate::State {
                state: AgentState::Running,
                ..
            } => self.running = true,
            SessionUpdate::State {
                state: AgentState::Idle,
                stop_reason,
            } => self.turn_end(stop_reason.as_deref()),
            SessionUpdate::Mode(m) => self.mode = Some(m),
            SessionUpdate::Config(opts) => self.config = opts,
            SessionUpdate::Usage { used, size } => {
                self.context =
                    Some(u8::try_from((used.saturating_mul(100) / size).min(100)).unwrap_or(100));
            }
            SessionUpdate::State { .. } | SessionUpdate::Other(_) => {}
            SessionUpdate::SessionInfo { title } => {
                if let Some(t) = title {
                    self.title = t;
                }
            }
        }
    }

    /// The turn is over: a call still marked running will never finish.
    pub fn turn_end(&mut self, stop_reason: Option<&str>) {
        self.running = false;
        // A call still open will never finish. Items are found by id each time: closing one can
        // drop others off the front to stay in budget, so positions do not hold still.
        let open: Vec<u64> = std::mem::take(&mut self.open_tools).into_iter().collect();
        for id in open {
            let Some(i) = self.index_of(id) else { continue };
            if let Entry::Tool(t) = &mut self.items[i].entry {
                t.status = ToolStatus::Failed;
                t.title.push_str(" · no result");
            }
            self.touch(i);
        }
        if let Some(reason) = stop_reason.filter(|r| *r != "end_turn") {
            self.note(format!("Turn ended: {}", reason.replace('_', " ")));
        }
    }

    /// Where the item with this id sits now. Ids are handed out in order and only the oldest are
    /// dropped, so the position is the distance from the first.
    fn index_of(&self, item_id: u64) -> Option<usize> {
        let first = self.items.front()?.id;
        let i = usize::try_from(item_id.checked_sub(first)?).ok()?;
        (self.items.get(i)?.id == item_id).then_some(i)
    }

    fn chunk(&mut self, role: Role, c: Chunk) {
        let text = match c.content {
            Content::Text(t) => t,
            Content::Other(kind) => format!("[{kind}]"),
        };
        // With an id the chunk continues the latest message of that role and id, wherever the
        // agent left off; without one it continues the message just before it, if that is its role.
        let target = match &c.message_id {
            Some(id) => self
                .items
                .iter()
                .enumerate()
                .rev()
                .take(LOOKBACK)
                .find_map(|(i, it)| match &it.entry {
                    Entry::Message {
                        role: r,
                        message_id: Some(m),
                        ..
                    } if *r == role && m == id => Some(i),
                    _ => None,
                }),
            None => self.items.len().checked_sub(1).filter(
                |i| matches!(&self.items[*i].entry, Entry::Message { role: r, .. } if *r == role),
            ),
        };
        if let Some(i) = target {
            if let Entry::Message { text: existing, .. } = &mut self.items[i].entry {
                existing.push_str(&text);
            }
            self.touch(i);
            return;
        }
        self.push(Entry::Message {
            role,
            message_id: c.message_id,
            text,
        });
    }

    fn tool(&mut self, call: &ToolCall) {
        let found = self.tool_at.get(&call.id).and_then(|id| self.index_of(*id));
        match found {
            Some(i) => {
                let item_id = self.items[i].id;
                if let Entry::Tool(t) = &mut self.items[i].entry {
                    merge_tool(t, call);
                    if !matches!(t.status, ToolStatus::Pending | ToolStatus::InProgress) {
                        self.open_tools.remove(&item_id);
                    }
                }
                self.touch(i);
            }
            None => {
                let mut t = Tool {
                    id: call.id.clone(),
                    title: String::new(),
                    kind: None,
                    status: ToolStatus::Pending,
                    subject: None,
                    output: Output::default(),
                    diffs: Vec::new(),
                };
                merge_tool(&mut t, call);
                if t.title.is_empty() {
                    t.title = t.kind.clone().unwrap_or_else(|| "tool".to_string());
                }
                self.push(Entry::Tool(t));
            }
        }
    }

    fn push(&mut self, entry: Entry) {
        let size = size_of(&entry);
        if let Entry::Tool(t) = &entry {
            self.tool_at.insert(t.id.clone(), self.next_id);
            if matches!(t.status, ToolStatus::Pending | ToolStatus::InProgress) {
                self.open_tools.insert(self.next_id);
            }
        }
        self.items.push_back(Item {
            id: self.next_id,
            rev: 0,
            entry,
            size,
        });
        self.next_id += 1;
        self.bytes += size;
        self.enforce();
    }

    /// Item `i` changed: bump its revision and re-measure it.
    fn touch(&mut self, i: usize) {
        let size = size_of(&self.items[i].entry);
        let item = &mut self.items[i];
        self.bytes = self.bytes - item.size + size;
        item.size = size;
        item.rev += 1;
        self.enforce();
    }

    fn enforce(&mut self) {
        // Never the newest item: it is what is being written.
        while self.bytes > self.budget && self.items.len() > 1 {
            if let Some(gone) = self.items.pop_front() {
                self.bytes -= gone.size;
                self.dropped += 1;
                if let Entry::Tool(t) = &gone.entry {
                    if self.tool_at.get(&t.id) == Some(&gone.id) {
                        self.tool_at.remove(&t.id);
                    }
                }
                self.open_tools.remove(&gone.id);
            }
        }
    }
}

fn merge_tool(t: &mut Tool, call: &ToolCall) {
    if let Some(title) = &call.title {
        t.title.clone_from(title);
    }
    if call.kind.is_some() {
        t.kind.clone_from(&call.kind);
    }
    // A late "running" never undoes a finished call.
    if let Some(s) = call.status {
        if matches!(t.status, ToolStatus::Pending | ToolStatus::InProgress) {
            t.status = s;
        }
    }
    if let Some(subject) = call.subject() {
        t.subject = Some(subject);
    }
    if !call.content.is_empty() {
        let text: Vec<&str> = call
            .content
            .iter()
            .filter_map(|c| {
                if let ToolContent::Text(s) = c {
                    Some(s.as_str())
                } else {
                    None
                }
            })
            .collect();
        if !text.is_empty() {
            t.output = trim_output(&text.join("\n"));
        }
        let diffs: Vec<Diff> = call
            .content
            .iter()
            .filter_map(|c| match c {
                ToolContent::Diff {
                    path,
                    old_text,
                    new_text,
                } => Some(Diff {
                    path: path.clone(),
                    old: old_text.as_deref().map(|s| cut(s, DIFF_SIDE_MAX)),
                    new: cut(new_text, DIFF_SIDE_MAX),
                }),
                ToolContent::Text(_) => None,
            })
            .take(DIFFS_PER_CALL)
            .collect();
        if !diffs.is_empty() {
            t.diffs = diffs;
        }
    }
}

/// Keeps the head and the tail of `text`, line by line.
fn trim_output(text: &str) -> Output {
    let lines: Vec<&str> = text.lines().collect();
    if lines.len() <= OUTPUT_HEAD + OUTPUT_TAIL {
        return Output {
            head: lines.iter().map(|l| (*l).to_string()).collect(),
            tail: Vec::new(),
            omitted: 0,
        };
    }
    Output {
        head: lines[..OUTPUT_HEAD]
            .iter()
            .map(|l| (*l).to_string())
            .collect(),
        tail: lines[lines.len() - OUTPUT_TAIL..]
            .iter()
            .map(|l| (*l).to_string())
            .collect(),
        omitted: lines.len() - OUTPUT_HEAD - OUTPUT_TAIL,
    }
}

/// `s` cut to at most `max` bytes, on a character boundary.
fn cut(s: &str, max: usize) -> String {
    if s.len() <= max {
        return s.to_string();
    }
    let mut end = max;
    while !s.is_char_boundary(end) {
        end -= 1;
    }
    s[..end].to_string()
}

fn size_of(entry: &Entry) -> usize {
    ITEM_OVERHEAD
        + match entry {
            Entry::Message { text, .. } => text.len(),
            Entry::Note(t) => t.len(),
            Entry::Done { text, .. } => text.len(),
            Entry::Tool(t) => {
                t.title.len()
                    + t.subject.as_ref().map_or(0, String::len)
                    + t.output
                        .head
                        .iter()
                        .chain(&t.output.tail)
                        .map(String::len)
                        .sum::<usize>()
                    + t.diffs
                        .iter()
                        .map(|d| d.path.len() + d.new.len() + d.old.as_ref().map_or(0, String::len))
                        .sum::<usize>()
            }
        }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn update(v: serde_json::Value) -> SessionUpdate {
        SessionUpdate::from_value(&v).expect("a valid update")
    }

    fn chunk(kind: &str, id: &str, text: &str) -> SessionUpdate {
        update(
            json!({"sessionUpdate": kind, "messageId": id, "content": {"type": "text", "text": text}}),
        )
    }

    fn tool(id: &str, status: &str) -> SessionUpdate {
        update(
            json!({"sessionUpdate": "tool_call_update", "toolCallId": id, "title": "ls", "status": status}),
        )
    }

    #[test]
    fn chunks_of_one_message_join_and_a_new_id_starts_a_new_item() {
        let mut t = Transcript::default();
        t.apply(chunk("agent_message_chunk", "a", "he"));
        t.apply(chunk("agent_message_chunk", "a", "llo"));
        t.apply(chunk("agent_message_chunk", "b", "next"));
        assert_eq!(t.items().len(), 2);
        assert!(matches!(&t.items()[0].entry, Entry::Message { text, .. } if text == "hello"));
        assert_eq!(t.items()[0].rev, 1);
    }

    #[test]
    fn a_late_running_update_does_not_reopen_a_finished_call() {
        let mut t = Transcript::default();
        t.apply(tool("1", "completed"));
        t.apply(tool("1", "in_progress"));
        assert!(matches!(&t.items()[0].entry, Entry::Tool(x) if x.status == ToolStatus::Completed));
    }

    #[test]
    fn a_turn_that_ends_with_a_call_open_marks_it_and_says_why_the_turn_ended() {
        let mut t = Transcript::default();
        t.apply(update(
            json!({"sessionUpdate": "state_update", "state": "running"}),
        ));
        assert!(t.running());
        t.apply(tool("1", "in_progress"));
        t.apply(update(
            json!({"sessionUpdate": "state_update", "state": "idle", "stopReason": "max_tokens"}),
        ));
        assert!(!t.running());
        assert!(
            matches!(&t.items()[0].entry, Entry::Tool(x) if x.status == ToolStatus::Failed && x.title.ends_with("no result"))
        );
        assert!(matches!(&t.items()[1].entry, Entry::Note(n) if n == "Turn ended: max tokens"));
    }

    #[test]
    fn a_normal_end_of_turn_says_nothing() {
        let mut t = Transcript::default();
        t.turn_end(Some("end_turn"));
        assert!(t.items().is_empty());
    }

    #[test]
    fn the_oldest_items_go_first_and_are_counted_and_the_newest_always_stays() {
        let mut t = Transcript::new(1000);
        for i in 0..20 {
            t.note(format!("{i:0>100}"));
        }
        assert!(t.bytes() <= 1000 + 200);
        assert!(t.dropped() > 0);
        assert_eq!(t.items().len() + t.dropped(), 20);
        let mut tiny = Transcript::new(1);
        tiny.note("x".repeat(500));
        assert_eq!(
            tiny.items().len(),
            1,
            "one item is never dropped for being too big"
        );
    }

    #[test]
    fn a_tool_keeps_the_head_and_tail_of_a_long_output() {
        let mut t = Transcript::default();
        let long: Vec<String> = (0..1000).map(|i| format!("line {i}")).collect();
        t.apply(update(json!({"sessionUpdate": "tool_call", "toolCallId": "1", "title": "make",
            "content": [{"type": "content", "content": {"type": "text", "text": long.join("\n")}}]})));
        let Entry::Tool(tool) = &t.items()[0].entry else {
            panic!("not a tool")
        };
        assert_eq!(
            (
                tool.output.head.len(),
                tool.output.tail.len(),
                tool.output.omitted
            ),
            (12, 12, 976)
        );
        assert_eq!(
            tool.output.tail.last().map(String::as_str),
            Some("line 999")
        );
        assert!(
            t.bytes() < 1000,
            "the full output is not held: {}",
            t.bytes()
        );
    }

    #[test]
    fn an_update_that_only_changes_the_status_keeps_the_output() {
        let mut t = Transcript::default();
        t.apply(update(
            json!({"sessionUpdate": "tool_call", "toolCallId": "1", "title": "ls",
            "content": [{"type": "content", "content": {"type": "text", "text": "a\nb"}}]}),
        ));
        t.apply(tool("1", "completed"));
        let Entry::Tool(x) = &t.items()[0].entry else {
            panic!("not a tool")
        };
        assert_eq!(x.output.head, ["a", "b"]);
        assert_eq!(x.status, ToolStatus::Completed);
    }

    #[test]
    fn the_subject_is_kept_whole_and_diffs_are_capped() {
        let mut t = Transcript::default();
        t.apply(update(
            json!({"sessionUpdate": "tool_call", "toolCallId": "1", "title": "edit",
            "rawInput": {"command": "git commit -m 'a long message'"},
            "content": [{"type": "diff", "path": "a.rs", "newText": "é".repeat(50_000)}]}),
        ));
        let Entry::Tool(x) = &t.items()[0].entry else {
            panic!("not a tool")
        };
        assert_eq!(x.subject.as_deref(), Some("git commit -m 'a long message'"));
        assert_eq!(x.diffs[0].new.len(), 16 * 1024);
        assert!(x.diffs[0].new.is_char_boundary(x.diffs[0].new.len()));
    }

    #[test]
    fn a_turns_summary_counts_files_lines_tools_and_failures_since_the_last_message() {
        let mut t = Transcript::default();
        t.user("earlier");
        t.apply(update(json!({"sessionUpdate": "tool_call", "toolCallId": "old", "title": "x", "status": "failed"})));
        t.user("fix it");
        t.apply(update(json!({"sessionUpdate": "tool_call", "toolCallId": "1", "title": "Edit", "status": "completed",
            "content": [{"type": "diff", "path": "a.rs", "oldText": "a\nb", "newText": "a\nc\nd"}]})));
        t.apply(update(json!({"sessionUpdate": "tool_call", "toolCallId": "2", "title": "Edit again", "status": "completed",
            "content": [{"type": "diff", "path": "a.rs", "oldText": "x", "newText": "y"}]})));
        t.apply(update(json!({"sessionUpdate": "tool_call", "toolCallId": "3", "title": "Test", "status": "failed"})));
        let s = t.turn_stats();
        assert_eq!(
            (s.files, s.added, s.removed, s.tools, s.failed),
            (1, 3, 2, 3, 1)
        );
        assert_eq!(
            s.summary(72),
            "Done in 1m 12s · 1 file +3 −2 · 3 tools · 1 failed"
        );
    }

    #[test]
    fn a_failure_the_agent_recovered_from_is_counted_but_the_turn_still_ends_well() {
        let mut t = Transcript::default();
        t.user("go");
        t.apply(update(json!({"sessionUpdate": "tool_call", "toolCallId": "1", "title": "Test", "status": "failed"})));
        t.apply(update(json!({"sessionUpdate": "tool_call", "toolCallId": "2", "title": "Test", "status": "completed"})));
        let s = t.turn_stats();
        assert_eq!((s.failed, s.ended_failed), (1, false));
        t.done(5);
        assert!(
            matches!(t.items().back().map(|i| &i.entry), Some(Entry::Done { ok: true, text }) if text.contains("1 failed"))
        );
    }

    #[test]
    fn a_turn_that_only_talked_says_only_how_long_and_singular_is_singular() {
        assert_eq!(Stats::default().summary(8), "Done in 8s");
        assert_eq!(
            Stats {
                files: 2,
                tools: 1,
                ..Stats::default()
            }
            .summary(1),
            "Done in 1s · 2 files +0 −0 · 1 tool"
        );
    }

    #[test]
    fn the_model_and_thinking_level_come_from_the_config_options_and_follow_an_update() {
        let mut t = Transcript::default();
        let opts = |model: &str| {
            json!({"sessionUpdate": "config_option_update", "configOptions": [
            {"id": "model", "category": "model", "type": "select", "currentValue": model, "options": [{"value": "a", "name": "Model A"}, {"value": "b", "name": "Model B"}]},
            {"id": "thinking", "category": "thought_level", "type": "select", "currentValue": "hi", "options": [{"value": "hi", "name": "high"}]},
            {"id": "mode", "category": "mode", "type": "select", "currentValue": "act", "options": [{"value": "act", "name": "act"}]}]})
        };
        t.apply(update(opts("a")));
        assert_eq!(
            (t.model(), t.thinking(), t.mode()),
            (Some("Model A"), Some("high"), Some("act"))
        );
        t.apply(update(opts("b")));
        assert_eq!(t.model(), Some("Model B"));
        assert!(t.items().is_empty(), "state, not conversation");
    }

    #[test]
    fn the_mode_and_the_context_percent_are_kept_and_capped() {
        let mut t = Transcript::default();
        t.apply(update(
            json!({"sessionUpdate": "current_mode_update", "currentModeId": "plan"}),
        ));
        t.apply(update(
            json!({"sessionUpdate": "usage_update", "used": 47, "size": 100}),
        ));
        assert_eq!((t.mode(), t.context()), (Some("plan"), Some(47)));
        t.apply(update(
            json!({"sessionUpdate": "usage_update", "used": 900, "size": 100}),
        ));
        assert_eq!(t.context(), Some(100));
        assert!(t.items().is_empty(), "state, not conversation");
    }

    fn bare_chunk(kind: &str, text: &str) -> SessionUpdate {
        update(json!({"sessionUpdate": kind, "content": {"type": "text", "text": text}}))
    }

    #[test]
    fn chunks_without_an_id_continue_the_message_before_them() {
        let mut t = Transcript::default();
        for w in ["Hel", "lo ", "wor", "ld"] {
            t.apply(bare_chunk("agent_message_chunk", w));
        }
        assert_eq!(t.items().len(), 1);
        assert!(
            matches!(&t.items()[0].entry, Entry::Message { text, .. } if text == "Hello world")
        );
        // A different role starts its own message.
        t.apply(bare_chunk("agent_thought_chunk", "hmm"));
        assert_eq!(t.items().len(), 2);
    }

    #[test]
    fn a_message_continues_where_it_left_off_even_after_a_thought_in_between() {
        let mut t = Transcript::default();
        t.apply(chunk("agent_thought_chunk", "m", "a"));
        t.apply(chunk("agent_message_chunk", "m", "b"));
        t.apply(chunk("agent_thought_chunk", "m", "c"));
        assert_eq!(t.items().len(), 2, "the thought is one thought");
        assert!(matches!(&t.items()[0].entry, Entry::Message { text, .. } if text == "ac"));
    }

    #[test]
    fn a_call_that_finishes_long_after_it_began_still_updates_its_own_row() {
        let mut t = Transcript::default();
        let call = |kind: &str, status: &str| {
            update(
                json!({"sessionUpdate": kind, "toolCallId": "long", "title": "npm test", "status": status}),
            )
        };
        t.apply(call("tool_call", "in_progress"));
        for i in 0..200 {
            t.apply(chunk("agent_message_chunk", &format!("m{i}"), "x"));
        }
        t.apply(call("tool_call_update", "completed"));
        let rows: Vec<_> = t
            .items()
            .iter()
            .filter_map(|i| {
                if let Entry::Tool(x) = &i.entry {
                    Some((x.id.clone(), x.status))
                } else {
                    None
                }
            })
            .collect();
        assert_eq!(
            rows,
            [("long".to_string(), ToolStatus::Completed)],
            "one row, finished"
        );
    }

    #[test]
    fn a_turn_that_ends_closes_every_call_still_open_however_far_back_and_only_those() {
        let mut t = Transcript::default();
        let call = |id: &str, status: &str| {
            update(
                json!({"sessionUpdate": "tool_call", "toolCallId": id, "title": id, "status": status}),
            )
        };
        t.apply(call("old", "in_progress"));
        for i in 0..100 {
            t.apply(chunk("agent_message_chunk", &format!("m{i}"), "x"));
        }
        t.apply(call("done", "completed"));
        t.turn_end(Some("end_turn"));
        let marked: Vec<String> = t
            .items()
            .iter()
            .filter_map(|i| {
                if let Entry::Tool(x) = &i.entry {
                    x.title.ends_with("no result").then(|| x.id.clone())
                } else {
                    None
                }
            })
            .collect();
        assert_eq!(marked, ["old"]);
    }

    #[test]
    fn closing_calls_at_the_byte_budget_marks_the_right_ones_even_as_old_items_drop() {
        let mut t = Transcript::new(2000);
        let call = |id: &str, status: &str| {
            update(
                json!({"sessionUpdate": "tool_call", "toolCallId": id, "title": "cmd", "status": status}),
            )
        };
        for i in 0..40 {
            t.apply(call(&format!("d{i}"), "completed"));
        }
        t.apply(call("p1", "in_progress"));
        t.apply(call("p2", "in_progress"));
        t.apply(call("ok", "completed"));
        t.turn_end(Some("end_turn"));
        let marked: Vec<String> = t
            .items()
            .iter()
            .filter_map(|i| {
                if let Entry::Tool(x) = &i.entry {
                    x.title.ends_with("no result").then(|| x.id.clone())
                } else {
                    None
                }
            })
            .collect();
        assert_eq!(marked, ["p1", "p2"], "never a finished call");
    }

    #[test]
    fn dropping_an_old_call_forgets_it_so_the_index_stays_bounded() {
        let mut t = Transcript::new(1500);
        for i in 0..500 {
            t.apply(update(json!({"sessionUpdate": "tool_call", "toolCallId": format!("c{i}"), "title": "x", "status": "in_progress"})));
        }
        assert!(
            t.tool_at.len() <= t.items().len() && t.open_tools.len() <= t.items().len(),
            "{} / {} for {} items",
            t.tool_at.len(),
            t.open_tools.len(),
            t.items().len()
        );
    }

    #[test]
    fn the_title_can_be_set_and_cleared() {
        let mut t = Transcript::default();
        t.apply(update(
            json!({"sessionUpdate": "session_info_update", "title": "Fix the bug"}),
        ));
        assert_eq!(t.title(), Some("Fix the bug"));
        t.apply(update(
            json!({"sessionUpdate": "session_info_update", "title": null}),
        ));
        assert_eq!(t.title(), None);
    }

    #[test]
    fn the_byte_count_always_matches_what_is_held() {
        let mut t = Transcript::new(4000);
        for i in 0..200 {
            t.apply(chunk(
                "agent_message_chunk",
                &format!("m{}", i / 3),
                &"w".repeat(i % 50),
            ));
            t.apply(tool(
                &format!("t{i}"),
                if i % 2 == 0 {
                    "completed"
                } else {
                    "in_progress"
                },
            ));
            let held: usize = t.items().iter().map(|it| it.size).sum();
            assert_eq!(held, t.bytes(), "after {i}");
        }
    }
}
