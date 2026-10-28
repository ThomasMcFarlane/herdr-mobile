//! Renders the real screens, from scripted conversations, to ANSI text files that
//! `tool/tui-render-png.py` turns into pictures. It draws into a test buffer, so the colours
//! are exactly what the UI produces, whatever terminal or multiplexer would show them.
//!
//!     HERDR_TUI_SHOTS=docs/tui HERDR_TUI_SHOTS_THEME=light \
//!         cargo test -p herdr-tui --release shots -- --ignored
//!
//! Ignored by default: it writes files.

use crate::composer::Composer;
use crate::session::{Event, Record, Session, Start};
use crate::theme::Theme;
use crate::transcript::Transcript;
use crate::ui::{draw, Frame_, Header, View};
use acp::{Id, Message, SessionUpdate};
use ratatui::{
    backend::TestBackend,
    buffer::Buffer,
    style::{Color, Modifier},
    Terminal,
};
use serde_json::{json, Value};
use std::fmt::Write as _;

fn upd(tr: &mut Transcript, v: &Value) {
    tr.apply(SessionUpdate::from_value(v).expect("a valid update"));
}

fn say(tr: &mut Transcript, id: &str, text: &str) {
    upd(
        tr,
        &json!({"sessionUpdate": "agent_message_chunk", "messageId": id, "content": {"type": "text", "text": text}}),
    );
}

fn tool(tr: &mut Transcript, id: &str, title: &str, kind: &str, status: &str, extra: Value) {
    let mut u = json!({"sessionUpdate": "tool_call", "toolCallId": id, "title": title, "kind": kind, "status": status});
    for (k, v) in extra.as_object().into_iter().flatten() {
        u[k] = v.clone();
    }
    upd(tr, &u);
}

fn text(t: &str) -> Value {
    json!([{"type": "content", "content": {"type": "text", "text": t}}])
}

fn ready() -> Session {
    let mut scratch = Transcript::default();
    let (mut s, _) = Session::begin(Start::Attach, None);
    s.handle(
        Event::Message(Message::result(Id::Num(1), json!({}))),
        0,
        &mut scratch,
    );
    s.handle(
        Event::Record(Some(Record {
            session_id: Some("s".into()),
            cwd: "/w".into(),
            exited: None,
        })),
        0,
        &mut scratch,
    );
    s.handle(
        Event::Message(Message::result(Id::Num(2), json!({}))),
        0,
        &mut scratch,
    );
    s
}

fn permission() -> Message {
    Message::request(
        "kp1",
        "session/request_permission",
        json!({"toolCall": {"toolCallId": "t5", "title": "Run rm -rf build/.dart_tool && flutter test", "kind": "execute",
                "rawInput": {"command": "rm -rf build/.dart_tool && flutter test --coverage --no-pub"}},
            "options": [{"optionId": "once", "name": "Yes, proceed", "kind": "allow_once"},
                        {"optionId": "always", "name": "Yes, and don't ask again for `flutter test`", "kind": "allow_always"},
                        {"optionId": "no", "name": "No, and tell the agent what to do differently", "kind": "reject_once"}]}),
    )
}

/// A conversation that fixes a flaky test, up to the point named.
fn conversation(upto: &str) -> Transcript {
    let mut tr = Transcript::default();
    upd(
        &mut tr,
        &json!({"sessionUpdate": "config_option_update", "configOptions": [
        {"id": "model", "category": "model", "type": "select", "currentValue": "s", "options": [{"value": "s", "name": "Sonnet 5.5"}]},
        {"id": "thinking", "category": "thought_level", "type": "select", "currentValue": "h", "options": [{"value": "h", "name": "high"}]}]}),
    );
    if upto == "empty" {
        return tr;
    }
    if upto == "table" {
        tr.user("write a table with data, many columns");
        upd(
            &mut tr,
            &json!({"sessionUpdate": "agent_thought_chunk", "messageId": "th", "content": {"type": "text", "text": "A table with made-up data."}}),
        );
        say(&mut tr, "m", "Here is a sample table with made-up data. The names are illustrative, not read from herdr.\n\n| # | Machine | Agent | Workspace | Status | Needs me | Link | Uptime | Last event | Tokens (k) | Battery cost | Version |\n|--:|:--|:--|:--|:--|:--|:--|--:|:--|--:|--:|:--|\n| 1 | dev-box | claude | herdr-mobile | working | no | live | 3h 12m | edited board.dart | 412 | 1.2% | 0.1.4 |\n| 2 | dev-box | codex | rust-port | blocked | yes (approve cmd) | live | 1h 47m | asked to run cargo test | 188 | 0.8% | 0.1.4 |\n| 3 | nas | omp | backups | error | yes (fatal) | attention | 5d 3h | SSH auth failed | 12 | 0.0% | 0.1.2 |\n\nIf you want something specific, tell me the topic, the columns, the number of rows, or the format.\n");
        tr.turn_end(Some("end_turn"));
        tr.done(7);
        return tr;
    }
    if upto == "narrow-table" {
        tr.user("which machines need me?");
        say(&mut tr, "m", "| machine | agent | status | notes |\n|:--|:--|:--|:--|\n| dev-box | codex | blocked | asked to approve `cargo test`, waiting 4 minutes |\n| nas | omp | error | SSH auth failed, the key was refused |\n| laptop | claude | working | editing DESIGN.md |\n");
        tr.turn_end(Some("end_turn"));
        tr.done(3);
        return tr;
    }
    if upto == "code" {
        tr.user("show me the retry helper and what to check");
        say(&mut tr, "m", "Here is the helper, in `lib/retry.rs`:\n\n```rust\n/// Retries `op` with a doubling delay, at most `tries` times.\npub async fn retry<T, E>(tries: u32, mut op: impl FnMut() -> Result<T, E>) -> Result<T, E> {\n    let mut delay = Duration::from_millis(50);\n    for _ in 1..tries {\n        match op() {\n            Ok(v) => return Ok(v),\n            Err(_) => sleep(delay).await, // back off\n        }\n        delay *= 2;\n    }\n    op()\n}\n```\n\nAnd the same check in Python:\n\n```python\ndef healthy(host: str) -> bool:\n    \"\"\"True when the keeper answers within 2 s.\"\"\"\n    return ping(host, timeout=2.0) is not None\n```\n\n8. Run `cargo test retry`\n9. Check the [retry docs](https://docs.rs/tokio/latest/tokio/time/fn.sleep.html)\n10. Ship it\n");
        tr.turn_end(Some("end_turn"));
        tr.done(5);
        return tr;
    }
    if upto == "streaming" {
        tr.user("which machines need me?");
        upd(
            &mut tr,
            &json!({"sessionUpdate": "state_update", "state": "running"}),
        );
        say(&mut tr, "m", "Two of them. Here is where each stands:\n\n| machine | agent | status | notes |\n|:--|:--|:--|:--|\n| dev-box | codex | blocked | asked to approve `cargo test` |\n| nas | omp | err");
        return tr;
    }
    tr.user("Fix the flaky sync test in test/sync_test.dart");
    upd(
        &mut tr,
        &json!({"sessionUpdate": "state_update", "state": "running"}),
    );
    upd(
        &mut tr,
        &json!({"sessionUpdate": "agent_thought_chunk", "messageId": "th", "content": {"type": "text", "text": "The test is flaky, so it probably races on a timer."}}),
    );
    tool(
        &mut tr,
        "t1",
        "Read test/sync_test.dart",
        "read",
        "completed",
        json!({"content": text("void main() {\n  test('reconnects', () async {")}),
    );
    tool(
        &mut tr,
        "t2",
        "Grep Future.delayed in lib/",
        "search",
        "completed",
        json!({}),
    );
    tool(
        &mut tr,
        "t2b",
        "$ cat lib/sync.dart | head -40",
        "execute",
        "completed",
        json!({"rawInput": {"command": "cat lib/sync.dart | head -40"}}),
    );
    if upto == "working" {
        tool(
            &mut tr,
            "t2c",
            "$ git log --oneline -5 && git status --short",
            "execute",
            "in_progress",
            json!({"rawInput": {"command": "git log --oneline -5 && git status --short"}}),
        );
        return tr;
    }
    say(&mut tr, "m1", "I found the cause. `SyncService` waits a fixed **50 ms** for the reconnect, and the test asserts right after:\n\n- the retry timer fires *after* the assertion on a slow machine\n- the queue is flushed in `onConnected`, which the test never awaits\n\nThe fix is to expose the reconnect as a `Future` and await that.\n");
    let old = "class SyncService {\n  Future<void> connect() async {\n    _socket = await open();\n    await Future.delayed(retryDelay);\n    _flush();\n  }\n}\n";
    let new = "class SyncService {\n  Future<void> connect() async {\n    _socket = await open();\n    await reconnect();\n  }\n\n  /// Completes once the queue is flushed.\n  Future<void> reconnect() async {\n    await _flush();\n  }\n}\n";
    tool(
        &mut tr,
        "t3",
        "Edit lib/sync.dart",
        "edit",
        "completed",
        json!({"content": [{"type": "diff", "path": "lib/sync.dart", "oldText": old, "newText": new}]}),
    );
    tool(
        &mut tr,
        "t4",
        "$ flutter test test/sync_test.dart",
        "execute",
        "failed",
        json!({"content": text("00:01 +3 -1: SyncService reconnects and flushes the queue [E]\n  Expected: <3>\n    Actual: <2>\n  test/sync_test.dart 48:7  main.<fn>.<fn>\n00:01 +3 -1: Some tests failed.")}),
    );
    say(&mut tr, "m2", "Still one failure: the assertion counts `flushed` before `_flush` finishes. I need to clear the stale build output first, then run the whole suite.\n");
    if upto == "permission" {
        return tr;
    }
    tool(
        &mut tr,
        "t5",
        "$ rm -rf build/.dart_tool && flutter test",
        "execute",
        "completed",
        json!({}),
    );
    say(&mut tr, "m3", "## Result\n\nThe suite is green: **214 passed**, 0 failed.\n\n| file | change |\n|:--|--:|\n| `lib/sync.dart` | +6 −2 |\n| `test/sync_test.dart` | await `reconnect()` |\n\n1. `reconnect()` now returns a `Future`\n2. The test awaits it instead of sleeping\n\n> The 50 ms sleep was the whole bug; nothing else needed to change.\n");
    upd(
        &mut tr,
        &json!({"sessionUpdate": "session_info_update", "title": "Fix the flaky sync test"}),
    );
    upd(
        &mut tr,
        &json!({"sessionUpdate": "current_mode_update", "currentModeId": "act"}),
    );
    upd(
        &mut tr,
        &json!({"sessionUpdate": "usage_update", "used": 47, "size": 100}),
    );
    tr.turn_end(Some("end_turn"));
    tr.done(41);
    tr
}

fn ansi(buf: &Buffer) -> String {
    fn code(c: Color, fg: bool) -> Option<String> {
        let base = if fg { 30 } else { 40 };
        let bright = if fg { 90 } else { 100 };
        Some(match c {
            Color::Reset => return None,
            Color::Black => format!("{}", base),
            Color::Red => format!("{}", base + 1),
            Color::Green => format!("{}", base + 2),
            Color::Yellow => format!("{}", base + 3),
            Color::Blue => format!("{}", base + 4),
            Color::Magenta => format!("{}", base + 5),
            Color::Cyan => format!("{}", base + 6),
            Color::Gray => format!("{}", base + 7),
            Color::DarkGray => format!("{}", bright),
            Color::LightRed => format!("{}", bright + 1),
            Color::LightGreen => format!("{}", bright + 2),
            Color::LightYellow => format!("{}", bright + 3),
            Color::LightBlue => format!("{}", bright + 4),
            Color::LightMagenta => format!("{}", bright + 5),
            Color::LightCyan => format!("{}", bright + 6),
            Color::White => format!("{}", bright + 7),
            Color::Indexed(n) => format!("{};5;{n}", if fg { 38 } else { 48 }),
            Color::Rgb(r, g, b) => format!("{};2;{r};{g};{b}", if fg { 38 } else { 48 }),
        })
    }
    let mut out = String::new();
    for y in 0..buf.area.height {
        let mut last = String::new();
        let mut row = String::new();
        for x in 0..buf.area.width {
            let cell = &buf[(x, y)];
            if cell.symbol().is_empty() {
                continue;
            }
            let mut parts = vec!["0".to_string()];
            parts.extend(code(cell.fg, true));
            parts.extend(code(cell.bg, false));
            for (m, c) in [
                (Modifier::BOLD, "1"),
                (Modifier::DIM, "2"),
                (Modifier::ITALIC, "3"),
                (Modifier::UNDERLINED, "4"),
                (Modifier::REVERSED, "7"),
                (Modifier::CROSSED_OUT, "9"),
            ] {
                if cell.modifier.contains(m) {
                    parts.push(c.to_string());
                }
            }
            let sgr = format!("\x1b[{}m", parts.join(";"));
            if sgr != last {
                row.push_str(&sgr);
                last = sgr;
            }
            row.push_str(cell.symbol());
        }
        let _ = writeln!(out, "{row}\x1b[0m");
    }
    out
}

#[expect(
    clippy::too_many_arguments,
    reason = "a picture is drawn from exactly these things"
)]
fn frame(
    tr: &Transcript,
    session: &Session,
    composer: &Composer,
    theme: Theme,
    w: u16,
    h: u16,
    view: &mut View,
    working: Option<u64>,
    hint: Option<&str>,
) -> String {
    let mut term = Terminal::new(TestBackend::new(w, h)).expect("a test terminal");
    let ctx = Frame_ {
        transcript: tr,
        session,
        composer,
        header: Header {
            agent: "omp",
            cwd: "/home/me/workspace/herdr-mobile",
        },
        theme,
        hint,
        working_secs: working,
        turn: 0,
        anim_ms: 0,
        motion: false,
        newer: None,
    };
    term.draw(|f| draw(f, &ctx, view)).expect("drawn");
    ansi(term.backend().buffer())
}

#[test]
#[ignore = "writes files: set HERDR_TUI_SHOTS"]
fn shots() {
    let Ok(dir) = std::env::var("HERDR_TUI_SHOTS") else {
        return;
    };
    let light = std::env::var("HERDR_TUI_SHOTS_THEME").is_ok_and(|t| t == "light");
    let theme = Theme::banded(if light { (255, 255, 255) } else { (26, 27, 38) });
    let suffix = if light { "-light" } else { "" };
    let write = |name: &str, s: String| {
        std::fs::write(format!("{dir}/{name}{suffix}.ansi"), s).expect("writes the shot")
    };
    let new_view = || View::default();
    let none = Composer::default();

    write(
        "01-empty",
        frame(
            &conversation("empty"),
            &ready(),
            &none,
            theme,
            100,
            30,
            &mut new_view(),
            None,
            None,
        ),
    );
    let mut typing = Composer::default();
    "fix the flaky test, then run the whole suite"
        .chars()
        .for_each(|c| typing.insert(c));
    write(
        "02-typing",
        frame(
            &conversation("empty"),
            &ready(),
            &typing,
            theme,
            100,
            30,
            &mut new_view(),
            None,
            None,
        ),
    );
    write(
        "03-working",
        frame(
            &conversation("working"),
            &ready(),
            &none,
            theme,
            100,
            30,
            &mut new_view(),
            Some(12),
            None,
        ),
    );

    let mut asking = ready();
    let mut scratch = Transcript::default();
    asking.handle(Event::Message(permission()), 0, &mut scratch);
    write(
        "04-permission",
        frame(
            &conversation("permission"),
            &asking,
            &none,
            theme,
            100,
            36,
            &mut new_view(),
            None,
            None,
        ),
    );
    let mut questioned = ready();
    let mut scratch = Transcript::default();
    questioned.handle(
        Event::Message(Message::request(
            "kq1",
            "elicitation/create",
            json!({"mode": "form", "message": "Where should the test results go?", "requestedSchema": {"type": "object",
                "properties": {
                    "target": {"type": "string", "title": "Report to", "oneOf": [
                        {"const": "pr", "title": "A comment on the pull request"},
                        {"const": "file", "title": "test-report.md in the repo"},
                        {"const": "none", "title": "Nowhere, just tell me"}]},
                    "notify": {"type": "boolean", "title": "Ping me when done"}},
                "required": ["target"]}}),
        )),
        0,
        &mut scratch,
    );
    write(
        "14-question",
        frame(
            &conversation("permission"),
            &questioned,
            &none,
            theme,
            100,
            36,
            &mut new_view(),
            None,
            None,
        ),
    );
    let mut second = new_view();
    second.sel = 1;
    write(
        "05-confirm-always",
        frame(
            &conversation("permission"),
            &asking,
            &none,
            theme,
            100,
            36,
            &mut second,
            None,
            Some("This stays allowed. Press 2 again to confirm"),
        ),
    );
    write(
        "06-narrow",
        frame(
            &conversation("permission"),
            &asking,
            &none,
            theme,
            58,
            36,
            &mut new_view(),
            None,
            None,
        ),
    );
    write(
        "07-done",
        frame(
            &conversation("done"),
            &ready(),
            &none,
            theme,
            100,
            36,
            &mut new_view(),
            None,
            None,
        ),
    );
    write(
        "09-wide-table",
        frame(
            &conversation("table"),
            &ready(),
            &none,
            theme,
            100,
            36,
            &mut new_view(),
            None,
            None,
        ),
    );
    write(
        "10-table-wraps",
        frame(
            &conversation("narrow-table"),
            &ready(),
            &none,
            theme,
            62,
            24,
            &mut new_view(),
            None,
            None,
        ),
    );
    // Browse mode: the run of tool calls opened and in focus.
    let done = conversation("done");
    let first_tool = done
        .items()
        .iter()
        .find(|i| matches!(i.entry, crate::transcript::Entry::Tool(_)))
        .expect("a tool call")
        .id;
    let mut browsing = new_view();
    let run = first_tool | (1 << 63);
    browsing.expanded.insert(run);
    browsing.focus = Some(run);
    write(
        "11-browse",
        frame(
            &done,
            &ready(),
            &none,
            theme,
            100,
            36,
            &mut browsing,
            None,
            None,
        ),
    );
    let mut up = new_view();
    up.scroll = 14;
    write(
        "08-scrolled",
        frame(
            &conversation("done"),
            &ready(),
            &none,
            theme,
            100,
            36,
            &mut up,
            None,
            None,
        ),
    );
    write(
        "12-code",
        frame(
            &conversation("code"),
            &ready(),
            &none,
            theme,
            100,
            36,
            &mut new_view(),
            None,
            None,
        ),
    );
    write(
        "13-streaming",
        frame(
            &conversation("streaming"),
            &ready(),
            &none,
            theme,
            80,
            18,
            &mut new_view(),
            Some(4),
            None,
        ),
    );
    // A drag over the code: the selection band on real output, in whichever theme is asked for.
    let mut selecting = View::default();
    let mut drag = crate::select::Selection::begin((4, 6));
    drag.drag((70, 16));
    selecting.select = Some(drag);
    write(
        "15-selected",
        frame(
            &conversation("code"),
            &ready(),
            &none,
            theme,
            100,
            30,
            &mut selecting,
            None,
            None,
        ),
    );
}
