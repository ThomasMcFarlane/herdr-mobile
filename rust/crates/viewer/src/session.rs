//! The client side of one keeper session: handshake, load or create, prompts
//! and permission requests. Pure: events and the time go in, [`Effect`]s come
//! out, and the I/O layer carries them out. That keeps every rule here testable
//! without a socket, a thread or a clock.

use crate::transcript::Transcript;
use acp::{code, method, Id, Message, PermissionRequest, RpcError, SessionUpdate};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::time::Duration;

/// A request is not answered by a key pressed this soon after it appeared: that
/// key was meant for what was on screen before (the composer).
pub const ANSWER_GUARD_MS: u64 = 400;
/// How long to wait before asking again for a session the phone has not opened yet.
const RETRY_AFTER: Duration = Duration::from_secs(1);

/// How the session starts.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Start {
    /// The keeper already has (or will soon have) a session: load it.
    Attach,
    /// A new keeper with no session yet: create one in this folder.
    Create { cwd: String },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Phase {
    /// Waiting for the keeper to answer `initialize`.
    Initializing,
    /// Waiting for the keeper's record to name a session.
    WaitingForSession,
    /// `session/load` (replay) or `session/new` is in flight.
    Opening,
    Ready,
    /// Over, with the reason in words.
    Ended(String),
}

/// What the I/O layer should do.
#[derive(Clone, Debug, PartialEq)]
pub enum Effect {
    Send(Message),
    /// Read the keeper's record and answer with [`Event::Record`].
    ReadRecord,
    /// Answer with [`Event::Retry`] after this long.
    RetryIn(Duration),
    /// Put this text back in the composer: it was not sent.
    RestoreInput(String),
}

/// What reached the session.
#[derive(Clone, Debug, PartialEq)]
pub enum Event {
    Message(Message),
    /// The keeper's record, or `None` when it cannot be read.
    Record(Option<Record>),
    Retry,
    /// The connection closed.
    Closed,
}

/// The parts of the keeper's record the session needs.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Record {
    pub session_id: Option<String>,
    pub cwd: String,
    /// The reason, when the keeper's agent has exited.
    pub exited: Option<String>,
}

/// A permission request waiting for the person.
#[derive(Clone, Debug, PartialEq)]
pub struct Waiting {
    pub id: Id,
    pub request: PermissionRequest,
    pub arrived_ms: u64,
}

/// Why the person's action did nothing.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Refused {
    NotReady,
    /// A prompt is already in flight.
    Busy,
    /// A key came too soon after the request appeared.
    TooSoon,
    NoSuchOption,
    NothingWaiting,
    /// The request on the person's screen is no longer the one that waits: their key was meant
    /// for another.
    Changed,
    /// The session is over; nothing can reach the agent.
    Ended,
}

#[derive(Debug)]
enum Call {
    Init,
    Load,
    New,
    Prompt(String),
}

#[derive(Debug)]
pub struct Session {
    start: Start,
    phase: Phase,
    sid: Option<String>,
    next_id: i64,
    calls: HashMap<i64, Call>,
    waiting: Vec<Waiting>,
    /// The `_meta.herdr.pane` the keeper is told about, when run inside a herdr pane.
    pane: Option<String>,
}

impl Session {
    /// A session and the effects that begin it.
    #[must_use]
    pub fn begin(start: Start, pane: Option<String>) -> (Session, Vec<Effect>) {
        let mut s = Session {
            start,
            phase: Phase::Initializing,
            sid: None,
            next_id: 0,
            calls: HashMap::new(),
            waiting: Vec::new(),
            pane,
        };
        let mut meta = json!({"viewer": true});
        if let Some(p) = &s.pane {
            meta["pane"] = json!(p);
        }
        let init = s.call(
            Call::Init,
            method::INITIALIZE,
            json!({"protocolVersion": 1, "clientCapabilities": {},
                   "clientInfo": {"name": "herdr-tui", "title": format!("Terminal on {}", crate::host::short_host()), "version": crate::cli::VERSION},
                   "_meta": {"herdr": meta}}),
        );
        (s, vec![init])
    }

    #[must_use]
    pub fn phase(&self) -> &Phase {
        &self.phase
    }
    #[must_use]
    pub fn session_id(&self) -> Option<&str> {
        self.sid.as_deref()
    }
    /// The oldest request waiting, and how many wait in all.
    #[must_use]
    pub fn waiting(&self) -> &[Waiting] {
        &self.waiting
    }
    #[must_use]
    pub fn ready(&self) -> bool {
        self.phase == Phase::Ready
    }
    /// Whether a prompt is in flight.
    #[must_use]
    pub fn prompting(&self) -> bool {
        self.calls.values().any(|c| matches!(c, Call::Prompt(_)))
    }

    fn call(&mut self, call: Call, method: &str, params: Value) -> Effect {
        self.next_id += 1;
        self.calls.insert(self.next_id, call);
        Effect::Send(Message::request(self.next_id, method, params))
    }

    fn is_ended(&self) -> bool {
        matches!(self.phase, Phase::Ended(_))
    }

    fn end(&mut self, reason: impl Into<String>) {
        if !matches!(self.phase, Phase::Ended(_)) {
            self.phase = Phase::Ended(reason.into());
            // A request can no longer be answered: do not leave it asking.
            self.waiting.clear();
        }
    }

    /// Handles one event.
    pub fn handle(&mut self, ev: Event, now_ms: u64, tr: &mut Transcript) -> Vec<Effect> {
        match ev {
            Event::Closed => {
                self.end("the keeper closed the connection");
                Vec::new()
            }
            // Once over, it stays over: a late answer to an old call must not bring it back.
            Event::Retry | Event::Record(_) | Event::Message(Message::Response { .. })
                if self.is_ended() =>
            {
                Vec::new()
            }
            Event::Retry => self.read_record_if_waiting(),
            Event::Record(rec) => self.record(rec),
            Event::Message(Message::Response {
                id: Id::Num(n),
                outcome,
            }) => self.response(n, outcome, tr),
            Event::Message(Message::Response { .. }) => Vec::new(),
            Event::Message(Message::Notification { method, params }) => {
                self.notification(&method, &params, now_ms, tr);
                Vec::new()
            }
            Event::Message(Message::Request { id, method, params }) => {
                self.request(id, &method, &params, now_ms, tr)
            }
        }
    }

    fn read_record_if_waiting(&self) -> Vec<Effect> {
        if self.phase == Phase::WaitingForSession {
            vec![Effect::ReadRecord]
        } else {
            Vec::new()
        }
    }

    fn record(&mut self, rec: Option<Record>) -> Vec<Effect> {
        if self.phase != Phase::WaitingForSession {
            return Vec::new();
        }
        let Some(rec) = rec else {
            self.end("the keeper's record cannot be read");
            return Vec::new();
        };
        if let Some(reason) = rec.exited {
            self.end(reason);
            return Vec::new();
        }
        match rec.session_id {
            Some(sid) => {
                self.sid = Some(sid.clone());
                self.phase = Phase::Opening;
                vec![self.call(
                    Call::Load,
                    method::SESSION_LOAD,
                    json!({"sessionId": sid, "cwd": rec.cwd, "mcpServers": []}),
                )]
            }
            // The phone opens the session just after the start: ask again shortly.
            None => vec![Effect::RetryIn(RETRY_AFTER)],
        }
    }

    fn response(
        &mut self,
        n: i64,
        outcome: Result<Value, RpcError>,
        tr: &mut Transcript,
    ) -> Vec<Effect> {
        let Some(call) = self.calls.remove(&n) else {
            return Vec::new();
        };
        match (call, outcome) {
            (Call::Init, Err(e)) => {
                self.end(format!("the keeper refused this terminal ({})", e.message));
                Vec::new()
            }
            (Call::Init, Ok(_)) => match self.start.clone() {
                Start::Attach => {
                    self.phase = Phase::WaitingForSession;
                    vec![Effect::ReadRecord]
                }
                Start::Create { cwd } => {
                    self.phase = Phase::Opening;
                    vec![self.call(
                        Call::New,
                        method::SESSION_NEW,
                        json!({"cwd": cwd, "mcpServers": []}),
                    )]
                }
            },
            (Call::Load, Err(e)) | (Call::New, Err(e)) => {
                self.end(format!("the session did not open ({})", e.message));
                Vec::new()
            }
            (Call::Load, Ok(result)) => {
                self.phase = Phase::Ready;
                Self::config_from(&result, tr);
                Vec::new()
            }
            (Call::New, Ok(result)) => {
                Self::config_from(&result, tr);
                match result.get("sessionId").and_then(Value::as_str) {
                    Some(sid) => {
                        self.sid = Some(sid.to_string());
                        self.phase = Phase::Ready;
                    }
                    None => self.end("the agent opened no session"),
                }
                Vec::new()
            }
            (Call::Prompt(sent), Err(e)) => {
                tr.note(if e.code == code::SESSION_BUSY {
                    "The agent is busy; not sent".to_string()
                } else {
                    format!("Not sent: {}", e.message)
                });
                vec![Effect::RestoreInput(sent)]
            }
            (Call::Prompt(_), Ok(result)) => {
                tr.turn_end(result.get("stopReason").and_then(Value::as_str));
                Vec::new()
            }
        }
    }

    /// The model, mode and thinking level an agent reports in its answer to `session/new` or `load`.
    fn config_from(result: &Value, tr: &mut Transcript) {
        let mut opts =
            acp::parse_config_options(result.get("configOptions").unwrap_or(&Value::Null));
        if !opts.iter().any(|o| o.is("model")) {
            opts.extend(acp::legacy_models(result));
        }
        if !opts.is_empty() {
            tr.apply(SessionUpdate::Config(opts));
        }
    }

    fn notification(&mut self, name: &str, p: &Value, now_ms: u64, tr: &mut Transcript) {
        match name {
            method::SESSION_UPDATE
                if p.get("sessionId").and_then(Value::as_str) == self.sid.as_deref() =>
            {
                if let Some(u) = p.get("update").and_then(SessionUpdate::from_value) {
                    tr.apply(u);
                }
            }
            method::HERDR_RESOLVED => {
                self.forget(p.get("requestId"), now_ms);
                let by = p
                    .get("by")
                    .and_then(Value::as_str)
                    .unwrap_or("another client");
                let answer = p.get("answer").and_then(Value::as_str).unwrap_or("?");
                tr.note(format!("Answered in {by}: {answer}"));
            }
            method::CANCEL_REQUEST => self.forget(p.get("requestId"), now_ms),
            method::HERDR_AGENT_EXITED => self.end(
                p.get("reason")
                    .and_then(Value::as_str)
                    .unwrap_or("the agent exited"),
            ),
            _ => {}
        }
    }

    fn forget(&mut self, request_id: Option<&Value>, now_ms: u64) {
        if let Some(id) = request_id.and_then(|v| serde_json::from_value::<Id>(v.clone()).ok()) {
            let head = self.waiting.first().map(|w| w.id.clone());
            self.waiting.retain(|w| w.id != id);
            self.promote(head, now_ms);
        }
    }

    /// A request that becomes the head was not on screen until now, so its guard window starts now:
    /// a key aimed at the one before it must not answer it.
    fn promote(&mut self, was_head: Option<Id>, now_ms: u64) {
        if let Some(head) = self.waiting.first_mut() {
            if Some(&head.id) != was_head.as_ref() {
                head.arrived_ms = now_ms;
            }
        }
    }

    fn request(
        &mut self,
        id: Id,
        name: &str,
        p: &Value,
        now_ms: u64,
        tr: &mut Transcript,
    ) -> Vec<Effect> {
        match name {
            method::REQUEST_PERMISSION => {
                if !self.waiting.iter().any(|w| w.id == id) {
                    self.waiting.push(Waiting {
                        id,
                        request: PermissionRequest::from_params(p),
                        arrived_ms: now_ms,
                    });
                }
                Vec::new()
            }
            method::ELICITATION_CREATE => {
                let q = p.get("message").and_then(Value::as_str).unwrap_or("");
                tr.note(format!("Question: {q} (answer it on the phone)"));
                Vec::new()
            }
            other => vec![Effect::Send(Message::error(
                id,
                RpcError::new(
                    code::METHOD_NOT_FOUND,
                    format!("A terminal view does not answer {other}."),
                ),
            ))],
        }
    }

    /// The person sends a message.
    ///
    /// # Errors
    /// [`Refused::NotReady`] before the session is open, [`Refused::Busy`] while a prompt is in flight.
    /// The text is then still the caller's to keep.
    pub fn send(&mut self, text: &str, tr: &mut Transcript) -> Result<Vec<Effect>, Refused> {
        if !self.ready() {
            return Err(Refused::NotReady);
        }
        if self.prompting() {
            return Err(Refused::Busy);
        }
        let sid = self.sid.clone().ok_or(Refused::NotReady)?;
        tr.user(text);
        Ok(vec![self.call(
            Call::Prompt(text.to_string()),
            method::SESSION_PROMPT,
            json!({"sessionId": sid, "prompt": [{"type": "text", "text": text}]}),
        )])
    }

    /// The person asks the agent to stop.
    pub fn cancel(&mut self, tr: &mut Transcript) -> Vec<Effect> {
        let Some(sid) = &self.sid else {
            return Vec::new();
        };
        tr.note("Asked the agent to stop");
        // ACP: a client that cancels a turn answers every permission request still open as
        // cancelled. Left asking, they could be approved after the person said stop.
        let mut effects: Vec<Effect> = self
            .waiting
            .drain(..)
            .map(|w| Effect::Send(Message::result(w.id, acp::outcome_cancelled())))
            .collect();
        effects.push(Effect::Send(Message::notification(
            method::SESSION_CANCEL,
            json!({"sessionId": sid}),
        )));
        effects
    }

    /// The person answers the oldest waiting request with option `index`.
    ///
    /// # Errors
    /// [`Refused::NothingWaiting`], [`Refused::TooSoon`] within [`ANSWER_GUARD_MS`] of
    /// the request appearing, or [`Refused::NoSuchOption`].
    pub fn answer(
        &mut self,
        index: usize,
        now_ms: u64,
        tr: &mut Transcript,
    ) -> Result<Vec<Effect>, Refused> {
        if self.is_ended() {
            return Err(Refused::Ended);
        }
        let w = self.waiting.first().ok_or(Refused::NothingWaiting)?;
        if now_ms.saturating_sub(w.arrived_ms) < ANSWER_GUARD_MS {
            return Err(Refused::TooSoon);
        }
        let option = w.request.options.get(index).ok_or(Refused::NoSuchOption)?;
        let reply = Message::result(w.id.clone(), acp::outcome_selected(&option.id));
        tr.note(format!("Answered: {}", option.name));
        self.waiting.remove(0);
        self.promote(None, now_ms);
        Ok(vec![Effect::Send(reply)])
    }

    /// Answers the request `shown`, the one the person's screen last drew, and refuses when it is
    /// no longer the one that waits (it was answered elsewhere, and another took its place).
    ///
    /// # Errors
    /// [`Refused::Changed`] on a different request, else as [`Session::answer`].
    pub fn answer_for(
        &mut self,
        shown: &Id,
        index: usize,
        now_ms: u64,
        tr: &mut Transcript,
    ) -> Result<Vec<Effect>, Refused> {
        self.check_shown(shown)?;
        self.answer(index, now_ms, tr)
    }

    /// Withdraws the request on screen: the agent is told `cancelled`. The way out of a request
    /// that offers nothing to choose.
    ///
    /// # Errors
    /// As [`Session::answer_for`].
    pub fn dismiss_for(
        &mut self,
        shown: &Id,
        now_ms: u64,
        tr: &mut Transcript,
    ) -> Result<Vec<Effect>, Refused> {
        self.check_shown(shown)?;
        let w = self.waiting.first().ok_or(Refused::NothingWaiting)?;
        if now_ms.saturating_sub(w.arrived_ms) < ANSWER_GUARD_MS {
            return Err(Refused::TooSoon);
        }
        let reply = Message::result(w.id.clone(), acp::outcome_cancelled());
        tr.note("Cancelled the request");
        self.waiting.remove(0);
        self.promote(None, now_ms);
        Ok(vec![Effect::Send(reply)])
    }

    fn check_shown(&self, shown: &Id) -> Result<(), Refused> {
        if self.is_ended() {
            return Err(Refused::Ended);
        }
        match self.waiting.first() {
            None => Err(Refused::NothingWaiting),
            Some(w) if &w.id != shown => Err(Refused::Changed),
            Some(_) => Ok(()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ok(n: i64, result: Value) -> Event {
        Event::Message(Message::result(Id::Num(n), result))
    }

    fn note(m: &str, params: Value) -> Event {
        Event::Message(Message::notification(m, params))
    }

    fn record(sid: Option<&str>) -> Event {
        Event::Record(Some(Record {
            session_id: sid.map(str::to_string),
            cwd: "/w".into(),
            exited: None,
        }))
    }

    /// A session attached and loaded, with its transcript.
    fn ready() -> (Session, Transcript) {
        let mut tr = Transcript::default();
        let (mut s, _) = Session::begin(Start::Attach, None);
        s.handle(ok(1, json!({})), 0, &mut tr);
        s.handle(record(Some("sess")), 0, &mut tr);
        s.handle(ok(2, json!({})), 0, &mut tr);
        assert!(s.ready());
        (s, tr)
    }

    fn permission(id: &str) -> Event {
        Event::Message(Message::request(
            id,
            method::REQUEST_PERMISSION,
            json!({"toolCall": {"toolCallId": "t", "title": "Run ls"}, "options": [{"optionId": "a", "name": "Allow once", "kind": "allow_once"}, {"optionId": "r", "name": "Reject"}]}),
        ))
    }

    #[test]
    fn it_announces_itself_as_a_viewer_in_its_pane() {
        let (_, effects) = Session::begin(Start::Attach, Some("w1:p2".into()));
        let [Effect::Send(Message::Request { method, params, .. })] = effects.as_slice() else {
            panic!("one request")
        };
        assert_eq!(method, "initialize");
        assert_eq!(
            params["_meta"]["herdr"],
            json!({"viewer": true, "pane": "w1:p2"})
        );
    }

    #[test]
    fn attaching_reads_the_record_then_loads_the_session_in_its_folder() {
        let mut tr = Transcript::default();
        let (mut s, _) = Session::begin(Start::Attach, None);
        assert_eq!(s.handle(ok(1, json!({})), 0, &mut tr), [Effect::ReadRecord]);
        let fx = s.handle(record(Some("sess")), 0, &mut tr);
        let [Effect::Send(Message::Request { method, params, .. })] = fx.as_slice() else {
            panic!("one request")
        };
        assert_eq!(
            (
                method.as_str(),
                params["sessionId"].as_str(),
                params["cwd"].as_str()
            ),
            ("session/load", Some("sess"), Some("/w"))
        );
        assert_eq!(s.phase(), &Phase::Opening);
    }

    #[test]
    fn a_session_the_phone_has_not_opened_yet_is_asked_for_again() {
        let mut tr = Transcript::default();
        let (mut s, _) = Session::begin(Start::Attach, None);
        s.handle(ok(1, json!({})), 0, &mut tr);
        assert_eq!(
            s.handle(record(None), 0, &mut tr),
            [Effect::RetryIn(RETRY_AFTER)]
        );
        assert_eq!(s.handle(Event::Retry, 0, &mut tr), [Effect::ReadRecord]);
        assert_eq!(s.phase(), &Phase::WaitingForSession);
    }

    #[test]
    fn the_model_the_agent_reports_when_it_opens_the_session_reaches_the_transcript() {
        let mut tr = Transcript::default();
        let (mut s, _) = Session::begin(Start::Create { cwd: "/p".into() }, None);
        s.handle(ok(1, json!({})), 0, &mut tr);
        s.handle(ok(2, json!({"sessionId": "x", "configOptions": [{"id": "model", "category": "model", "type": "select", "currentValue": "m", "options": [{"value": "m", "name": "Big Model"}]}]})), 0, &mut tr);
        assert_eq!(tr.model(), Some("Big Model"));
        // The older shape works too.
        let mut tr2 = Transcript::default();
        let (mut s2, _) = Session::begin(Start::Create { cwd: "/p".into() }, None);
        s2.handle(ok(1, json!({})), 0, &mut tr2);
        s2.handle(ok(2, json!({"sessionId": "x", "models": {"currentModelId": "q", "availableModels": [{"modelId": "q", "name": "Quick"}]}})), 0, &mut tr2);
        assert_eq!(tr2.model(), Some("Quick"));
    }

    #[test]
    fn creating_makes_a_session_in_the_folder_and_is_ready_when_it_answers() {
        let mut tr = Transcript::default();
        let (mut s, _) = Session::begin(
            Start::Create {
                cwd: "/proj".into(),
            },
            None,
        );
        let fx = s.handle(ok(1, json!({})), 0, &mut tr);
        let [Effect::Send(Message::Request { method, params, .. })] = fx.as_slice() else {
            panic!("one request")
        };
        assert_eq!(
            (method.as_str(), params["cwd"].as_str()),
            ("session/new", Some("/proj"))
        );
        s.handle(ok(2, json!({"sessionId": "fresh"})), 0, &mut tr);
        assert!(s.ready());
        assert_eq!(s.session_id(), Some("fresh"));
    }

    #[test]
    fn a_keeper_whose_agent_exited_ends_the_session_with_its_reason() {
        let mut tr = Transcript::default();
        let (mut s, _) = Session::begin(Start::Attach, None);
        s.handle(ok(1, json!({})), 0, &mut tr);
        s.handle(
            Event::Record(Some(Record {
                session_id: Some("x".into()),
                cwd: "/".into(),
                exited: Some("exit 3".into()),
            })),
            0,
            &mut tr,
        );
        assert_eq!(s.phase(), &Phase::Ended("exit 3".into()));
    }

    #[test]
    fn updates_for_another_session_are_ignored() {
        let (mut s, mut tr) = ready();
        let upd = |sid: &str| {
            note(
                "session/update",
                json!({"sessionId": sid, "update": {"sessionUpdate": "agent_message_chunk", "messageId": "m", "content": {"type": "text", "text": "hi"}}}),
            )
        };
        s.handle(upd("other"), 0, &mut tr);
        assert!(tr.items().is_empty());
        s.handle(upd("sess"), 0, &mut tr);
        assert_eq!(tr.items().len(), 1);
    }

    #[test]
    fn sending_shows_the_message_and_only_one_prompt_is_in_flight() {
        let (mut s, mut tr) = ready();
        let fx = s.send("hello", &mut tr).expect("sent");
        let [Effect::Send(Message::Request { method, params, .. })] = fx.as_slice() else {
            panic!("one request")
        };
        assert_eq!(
            (method.as_str(), params["prompt"][0]["text"].as_str()),
            ("session/prompt", Some("hello"))
        );
        assert_eq!(tr.items().len(), 1);
        assert_eq!(s.send("again", &mut tr), Err(Refused::Busy));
        assert_eq!(
            tr.items().len(),
            1,
            "a refused message is not shown as sent"
        );
    }

    #[test]
    fn a_prompt_in_flight_counts_as_working_even_when_the_agent_never_says_so() {
        let (mut s, mut tr) = ready();
        assert!(!s.prompting());
        s.send("hello", &mut tr).expect("sent");
        assert!(s.prompting() && !tr.running());
        s.handle(ok(3, json!({"stopReason": "cancelled"})), 0, &mut tr);
        assert!(!s.prompting());
    }

    #[test]
    fn nothing_is_sent_before_the_session_is_open() {
        let mut tr = Transcript::default();
        let (mut s, _) = Session::begin(Start::Attach, None);
        assert_eq!(s.send("hi", &mut tr), Err(Refused::NotReady));
    }

    #[test]
    fn a_refused_prompt_gives_its_text_back_and_says_why() {
        let (mut s, mut tr) = ready();
        s.send("hello", &mut tr).expect("sent");
        let busy = Event::Message(Message::error(
            Id::Num(3),
            RpcError::new(code::SESSION_BUSY, "busy"),
        ));
        assert_eq!(
            s.handle(busy, 0, &mut tr),
            [Effect::RestoreInput("hello".into())]
        );
        assert!(!s.prompting());
        assert!(
            matches!(&tr.items().back().expect("a note").entry, crate::transcript::Entry::Note(n) if n.contains("busy"))
        );
    }

    #[test]
    fn a_finished_prompt_ends_the_turn_and_frees_the_next_send() {
        let (mut s, mut tr) = ready();
        s.send("one", &mut tr).expect("sent");
        s.handle(ok(3, json!({"stopReason": "end_turn"})), 0, &mut tr);
        assert!(s.send("two", &mut tr).is_ok());
    }

    #[test]
    fn a_permission_cannot_be_answered_the_instant_it_appears() {
        let (mut s, mut tr) = ready();
        s.handle(permission("kp1"), 10_000, &mut tr);
        assert_eq!(
            s.answer(0, 10_000 + ANSWER_GUARD_MS - 1, &mut tr),
            Err(Refused::TooSoon)
        );
        assert_eq!(s.waiting().len(), 1);
        let fx = s
            .answer(0, 10_000 + ANSWER_GUARD_MS, &mut tr)
            .expect("answered");
        let [Effect::Send(Message::Response { id, outcome: Ok(r) })] = fx.as_slice() else {
            panic!("a result")
        };
        assert_eq!(
            (id, r["outcome"]["optionId"].as_str()),
            (&Id::from("kp1"), Some("a"))
        );
        assert!(s.waiting().is_empty());
    }

    #[test]
    fn requests_are_answered_in_order_and_a_repeated_one_is_not_queued_twice() {
        let (mut s, mut tr) = ready();
        s.handle(permission("kp1"), 0, &mut tr);
        s.handle(permission("kp1"), 0, &mut tr);
        s.handle(permission("kp2"), 0, &mut tr);
        assert_eq!(s.waiting().len(), 2);
        assert_eq!(s.answer(9, 1000, &mut tr), Err(Refused::NoSuchOption));
        s.answer(1, 1000, &mut tr).expect("answered");
        assert_eq!(s.waiting()[0].id, Id::from("kp2"));
    }

    #[test]
    fn a_request_answered_elsewhere_or_withdrawn_leaves_the_queue() {
        let (mut s, mut tr) = ready();
        s.handle(permission("kp1"), 0, &mut tr);
        s.handle(permission("kp2"), 0, &mut tr);
        s.handle(
            note(
                "_herdr/resolved",
                json!({"requestId": "kp1", "by": "herdr mobile", "answer": "Allow once"}),
            ),
            0,
            &mut tr,
        );
        assert_eq!(s.waiting().len(), 1);
        s.handle(
            note("$/cancel_request", json!({"requestId": "kp2"})),
            0,
            &mut tr,
        );
        assert!(s.waiting().is_empty());
        assert!(tr.items().iter().any(|i| matches!(&i.entry, crate::transcript::Entry::Note(n) if n == "Answered in herdr mobile: Allow once")));
    }

    #[test]
    fn a_request_it_cannot_answer_is_refused_with_an_error() {
        let (mut s, mut tr) = ready();
        let fx = s.handle(
            Event::Message(Message::request("kp9", "fs/read_text_file", json!({}))),
            0,
            &mut tr,
        );
        assert!(
            matches!(fx.as_slice(), [Effect::Send(Message::Response { outcome: Err(e), .. })] if e.code == code::METHOD_NOT_FOUND)
        );
    }

    #[test]
    fn closing_or_the_agent_exiting_ends_it_once_with_the_first_reason() {
        let (mut s, mut tr) = ready();
        s.handle(
            note("_herdr/agent_exited", json!({"reason": "exit 3"})),
            0,
            &mut tr,
        );
        s.handle(Event::Closed, 0, &mut tr);
        assert_eq!(s.phase(), &Phase::Ended("exit 3".into()));
    }

    fn two_options() -> Value {
        json!([{"optionId": "a", "name": "Allow once", "kind": "allow_once"}, {"optionId": "r", "name": "Reject", "kind": "reject_once"}])
    }

    fn ask_with(id: &str, options: Value) -> Event {
        Event::Message(Message::request(
            id,
            method::REQUEST_PERMISSION,
            json!({"toolCall": {"toolCallId": "t", "title": "x"}, "options": options}),
        ))
    }

    #[test]
    fn a_late_answer_to_an_old_call_cannot_bring_an_ended_session_back() {
        let mut tr = Transcript::default();
        let (mut s, _) = Session::begin(Start::Attach, None);
        s.handle(ok(1, json!({})), 0, &mut tr);
        s.handle(record(Some("sess")), 0, &mut tr);
        s.handle(
            note("_herdr/agent_exited", json!({"reason": "exit 3"})),
            0,
            &mut tr,
        );
        s.handle(ok(2, json!({})), 0, &mut tr);
        s.handle(Event::Retry, 0, &mut tr);
        assert_eq!(s.phase(), &Phase::Ended("exit 3".into()));
        assert_eq!(s.send("x", &mut tr), Err(Refused::NotReady));
    }

    #[test]
    fn a_key_meant_for_one_request_cannot_answer_the_one_that_took_its_place() {
        let (mut s, mut tr) = ready();
        s.handle(ask_with("A", two_options()), 0, &mut tr);
        s.handle(ask_with("B", json!([{"optionId": "a", "name": "Allow once", "kind": "allow_once"}, {"optionId": "ALWAYS", "name": "Always", "kind": "allow_always"}])), 100, &mut tr);
        // A is answered on the phone and B moves up; the person's key, aimed at A, lands a moment later.
        s.handle(
            note(
                "_herdr/resolved",
                json!({"requestId": "A", "by": "phone", "answer": "x"}),
            ),
            9000,
            &mut tr,
        );
        assert_eq!(
            s.answer_for(&Id::from("A"), 1, 9001, &mut tr),
            Err(Refused::Changed),
            "the screen showed A"
        );
        assert_eq!(
            s.answer_for(&Id::from("B"), 1, 9001, &mut tr),
            Err(Refused::TooSoon),
            "B has only just appeared"
        );
        assert!(
            s.answer_for(&Id::from("B"), 1, 9000 + ANSWER_GUARD_MS, &mut tr)
                .is_ok(),
            "once B has been on screen long enough"
        );
    }

    #[test]
    fn answering_the_head_starts_the_next_requests_guard_window() {
        let (mut s, mut tr) = ready();
        s.handle(ask_with("A", two_options()), 0, &mut tr);
        s.handle(ask_with("B", two_options()), 0, &mut tr);
        s.answer_for(&Id::from("A"), 0, 5000, &mut tr)
            .expect("answered");
        assert_eq!(
            s.answer_for(&Id::from("B"), 0, 5000 + ANSWER_GUARD_MS - 1, &mut tr),
            Err(Refused::TooSoon)
        );
    }

    #[test]
    fn a_request_that_offers_nothing_to_choose_can_be_withdrawn() {
        let (mut s, mut tr) = ready();
        s.handle(ask_with("Z", json!([])), 0, &mut tr);
        assert_eq!(s.answer(0, 99_999, &mut tr), Err(Refused::NoSuchOption));
        let fx = s
            .dismiss_for(&Id::from("Z"), 99_999, &mut tr)
            .expect("withdrawn");
        assert!(
            matches!(fx.as_slice(), [Effect::Send(Message::Response { id, outcome: Ok(r) })] if id == &Id::from("Z") && r["outcome"]["outcome"] == "cancelled")
        );
        assert!(s.waiting().is_empty());
        assert_eq!(
            s.dismiss_for(&Id::from("Z"), 99_999, &mut tr),
            Err(Refused::NothingWaiting)
        );
    }

    #[test]
    fn stopping_the_turn_answers_every_open_request_as_cancelled() {
        let (mut s, mut tr) = ready();
        s.handle(ask_with("A", two_options()), 0, &mut tr);
        s.handle(ask_with("B", two_options()), 0, &mut tr);
        let fx = s.cancel(&mut tr);
        let cancelled = fx.iter().filter(|e| matches!(e, Effect::Send(Message::Response { outcome: Ok(r), .. }) if r["outcome"]["outcome"] == "cancelled")).count();
        assert_eq!(cancelled, 2, "{fx:?}");
        assert!(
            matches!(fx.last(), Some(Effect::Send(Message::Notification { method, .. })) if method == "session/cancel")
        );
        assert!(s.waiting().is_empty(), "nothing left to approve after stop");
    }

    #[test]
    fn a_session_that_ended_asks_nothing_and_answers_nothing() {
        let (mut s, mut tr) = ready();
        s.handle(ask_with("A", two_options()), 0, &mut tr);
        s.handle(Event::Closed, 0, &mut tr);
        assert!(s.waiting().is_empty(), "the panel goes with the link");
        s.handle(ask_with("B", two_options()), 0, &mut tr);
        assert_eq!(s.answer(0, 99_999, &mut tr), Err(Refused::Ended));
        assert_eq!(
            s.answer_for(&Id::from("B"), 0, 99_999, &mut tr),
            Err(Refused::Ended)
        );
        assert!(!tr.items().iter().any(|i| matches!(&i.entry, crate::transcript::Entry::Note(n) if n.starts_with("Answered"))), "no claim of an answer that went nowhere");
    }

    #[test]
    fn cancel_names_the_session() {
        let (mut s, mut tr) = ready();
        let fx = s.cancel(&mut tr);
        assert!(
            matches!(fx.as_slice(), [Effect::Send(Message::Notification { method, params })] if method == "session/cancel" && params["sessionId"] == "sess")
        );
    }
}
