#![allow(clippy::print_stdout)]
//! The cost of watching and scrolling one session, rendered exactly as the
//! program renders it (TestBackend, no terminal). Deterministic: fixed
//! conversation, fixed animation schedule, no clock and no network.
//!
//! Frames: 300 follow the newest output (an agent streaming), then 300 step
//! up through the whole scrollback, the way the wheel does. `scroll_over_follow`
//! is the jank a person feels: how many times a scroll frame costs a follow
//! frame.

use herdr_tui::composer::Composer;
use herdr_tui::session::{Event, Record, Session, Start};
use herdr_tui::theme::Theme;
use herdr_tui::transcript::Transcript;
use herdr_tui::ui::{draw, Frame_, Header, View};
use acp::{Id, Message, SessionUpdate};
use ratatui::{backend::TestBackend, buffer::Buffer, Terminal};
use serde_json::{json, Value};

const W: u16 = 120;
const H: u16 = 40;
const TURNS: usize = 160;

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

/// A long session: `TURNS` turns of a user asking, the agent thinking, calling
/// tools (reads, searches, edits with diffs, shell runs with output) and
/// answering with markdown, code and a table. Ends with a permission request
/// waiting, so the panel is on screen every frame.
fn conversation() -> Transcript {
    let mut tr = Transcript::default();
    upd(
        &mut tr,
        &json!({"sessionUpdate": "config_option_update", "configOptions": [
        {"id": "model", "category": "model", "type": "select", "currentValue": "s", "options": [{"value": "s", "name": "Sonnet 5.5"}]},
        {"id": "thinking", "category": "thought_level", "type": "select", "currentValue": "h", "options": [{"value": "h", "name": "high"}]}]}),
    );
    upd(
        &mut tr,
        &json!({"sessionUpdate": "session_info_update", "title": "Refactor the sync layer"}),
    );
    let ask = [
        "Fix the flaky sync test in test/sync_test.dart",
        "Then port the retry logic to use exponential backoff",
        "Review the diff and tighten the error handling",
        "Add a table of the open machines to the README",
        "Check the keeper routes and fix the stale entries",
    ];
    for t in 0..TURNS {
        tr.user(ask[t % ask.len()]);
        upd(&mut tr, &json!({"sessionUpdate": "state_update", "state": "running"}));
        upd(
            &mut tr,
            &json!({"sessionUpdate": "agent_thought_chunk", "messageId": format!("th{t}"), "content": {"type": "text", "text": "The test is flaky, so it probably races on a timer. I will read the file, find the delay, and make the queue awaitable."}}),
        );
        tool(
            &mut tr,
            &format!("r{t}"),
            "Read lib/sync.dart",
            "read",
            "completed",
            json!({"content": text("class SyncService {\n  Future<void> connect() async {\n    _socket = await open();\n    await Future.delayed(retryDelay);\n    _flush();\n  }\n}"),
            }),
        );
        tool(
            &mut tr,
            &format!("g{t}"),
            "Grep Future.delayed in lib/",
            "search",
            "completed",
            json!({}),
        );
        if t % 4 == 0 {
            let old = "class SyncService {\n  Future<void> connect() async {\n    _socket = await open();\n    await Future.delayed(retryDelay);\n    _flush();\n  }\n}\n";
            let new = "class SyncService {\n  Future<void> connect() async {\n    _socket = await open();\n    await reconnect();\n  }\n\n  /// Completes once the queue is flushed.\n  Future<void> reconnect() async {\n    await _flush();\n  }\n}\n";
            tool(
                &mut tr,
                &format!("e{t}"),
                "Edit lib/sync.dart",
                "edit",
                "completed",
                json!({"content": [{"type": "diff", "path": "lib/sync.dart", "oldText": old, "newText": new}]}),
            );
        }
        if t % 3 == 0 {
            tool(
                &mut tr,
                &format!("s{t}"),
                "$ flutter test test/sync_test.dart",
                "execute",
                if t % 2 == 0 { "completed" } else { "failed" },
                json!({"content": text("00:01 +3 -1: SyncService reconnects and flushes the queue [E]\n  Expected: <3>\n    Actual: <2>\n  test/sync_test.dart 48:7  main.<fn>.<fn>\n00:01 +3 -1: Some tests failed.")}),
            );
        }
        let body = format!(
            "Turn {t}: I found the cause. `SyncService` waits a fixed **50 ms** for the reconnect, and the test asserts right after.\n\n```dart\nawait reconnect();\n```\n\n- the retry timer fires *after* the assertion\n- the queue is flushed in `onConnected`\n\n| file | change |\n|:--|--:|\n| `lib/sync.dart` | +6 −2 |\n\n> Nothing else needed to change.\n"
        );
        say(&mut tr, &format!("m{t}"), &body);
        upd(
            &mut tr,
            &json!({"sessionUpdate": "usage_update", "used": 30 + (t % 60), "size": 100}),
        );
        upd(
            &mut tr,
            &json!({"sessionUpdate": "state_update", "state": "idle", "stopReason": "end_turn"}),
        );
        tr.turn_end(Some("end_turn"));
        tr.done(7 + (t % 40) as u64);
    }
    tr
}

/// A ready session, with one permission request waiting (the panel draws).
fn ready(tr: &mut Transcript) -> Session {
    let (mut s, _) = Session::begin(Start::Attach, None);
    s.handle(
        Event::Message(Message::result(Id::Num(1), json!({}))),
        0,
        tr,
    );
    s.handle(
        Event::Record(Some(Record {
            session_id: Some("s".into()),
            cwd: "/w".into(),
            exited: None,
        })),
        0,
        tr,
    );
    s.handle(
        Event::Message(Message::result(Id::Num(2), json!({}))),
        0,
        tr,
    );
    s.handle(
        Event::Message(Message::request(
            "kp1",
            "session/request_permission",
            json!({"toolCall": {"toolCallId": "t5", "title": "Run rm -rf build/.dart_tool && flutter test", "kind": "execute",
                    "rawInput": {"command": "rm -rf build/.dart_tool && flutter test --coverage --no-pub"}},
                "options": [{"optionId": "once", "name": "Yes, proceed", "kind": "allow_once"},
                            {"optionId": "always", "name": "Yes, and don't ask again for `flutter test`", "kind": "allow_always"},
                            {"optionId": "no", "name": "No, and tell the agent what to do differently", "kind": "reject_once"}]}),
        )),
        0,
        tr,
    );
    s
}

/// How many bytes the buffer holds (what a real frame would put on the wire).
fn buf_bytes(buf: &Buffer) -> usize {
    buf.content.iter().map(|c| c.symbol().len()).sum()
}

/// Peak resident memory, KiB.
fn rss_kib() -> u64 {
    let Ok(s) = std::fs::read_to_string("/proc/self/statm") else {
        return 0;
    };
    s.split_whitespace()
        .nth(1)
        .and_then(|p| p.parse().ok())
        .unwrap_or(0)
}

fn main() {
    let mut tr = conversation();
    let session = ready(&mut tr);
    let composer = Composer::default();
    let mut view = View::default();
    let mut term = Terminal::new(TestBackend::new(W, H)).expect("a test terminal");
    let theme = Theme::detect(None);
    let working_secs: u64 = 5;

    // Warm up: allocations and caches settle before anything is measured.
    for _ in 0..24 {
        view.scroll = 0;
        let ctx = Frame_ {
            transcript: &tr,
            session: &session,
            composer: &composer,
            header: Header {
                agent: "omp",
                cwd: "/home/me/workspace/herdr-mobile",
            },
            theme,
            hint: None,
            working_secs: Some(working_secs),
            turn: TURNS,
            anim_ms: 16,
            motion: true,
        };
        term.draw(|f| draw(f, &ctx, &mut view)).expect("drawn");
    }

    let mut follow: Vec<u128> = Vec::with_capacity(300);
    let mut scroll: Vec<u128> = Vec::with_capacity(300);
    let mut wire = 0u64;
    let mut cache_peak = 0usize;
    let max_scroll = 3000;
    for n in 0..600 {
        let is_follow = n < 300;
        // Wheel up: the window walks up through the scrollback and back.
        view.scroll = if is_follow {
            0
        } else {
            let k = n - 300;
            if k < 150 {
                k * max_scroll / 150
            } else {
                (300 - k) * max_scroll / 150
            }
        };
        let ctx = Frame_ {
            transcript: &tr,
            session: &session,
            composer: &composer,
            header: Header {
                agent: "omp",
                cwd: "/home/me/workspace/herdr-mobile",
            },
            theme,
            hint: None,
            working_secs: Some(working_secs),
            turn: TURNS,
            anim_ms: 16 * (n as u64 + 1),
            motion: true,
        };
        let t0 = std::time::Instant::now();
        term.draw(|f| draw(f, &ctx, &mut view)).expect("drawn");
        let dt = t0.elapsed().as_micros();
        wire += buf_bytes(term.backend().buffer()) as u64;
        cache_peak = cache_peak.max(view.cache_chars());
        if is_follow {
            follow.push(dt);
        } else {
            scroll.push(dt);
        }
    }
    let peak_rss = rss_kib();

    follow.sort_unstable();
    scroll.sort_unstable();
    let mut all: Vec<u128> = follow.iter().chain(scroll.iter()).copied().collect();
    all.sort_unstable();
    let p = |v: &[u128], f: f64| v[(((v.len() as f64) * f) as usize).min(v.len() - 1)] as u64;
    let mean = |v: &Vec<u128>| v.iter().sum::<u128>() as u64 / v.len() as u64;

    let peak = p(&all, 1.0);
    let p95 = p(&all, 0.95);
    let f_mean = mean(&follow);
    let s_mean = mean(&scroll);
    let ratio = if f_mean > 0 {
        (s_mean as f64 / f_mean as f64 * 1000.0).round() / 1000.0
    } else {
        0.0
    };
    let bpf = wire / 600;

    println!("METRIC frame_peak_us={peak}");
    println!("METRIC frame_p95_us={p95}");
    println!("METRIC frame_mean_us={}", mean(&all));
    println!("METRIC follow_mean_us={f_mean}");
    println!("METRIC scroll_mean_us={s_mean}");
    println!("METRIC scroll_over_follow={ratio}");
    println!("METRIC bytes_per_frame={bpf}");
    println!("METRIC peak_rss_kib={peak_rss}");
    println!("METRIC cache_chars={cache_peak}");
}
