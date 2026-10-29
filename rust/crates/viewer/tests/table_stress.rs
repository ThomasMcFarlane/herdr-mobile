//! Stress test for markdown tables and the text around them: documents built from awkward pieces
//! (wide and combining characters, emoji sequences, escaped pipes, ragged rows, long words,
//! controls) rendered at many widths, scrolled through a model of a terminal, and streamed one
//! character at a time.
//!
//! Seeded, so a failure names its seed and reproduces. `HERDR_STRESS=20000 cargo test -p herdr-tui
//! --test table_stress --release` runs a far longer sweep; the default is short enough for every
//! test run.

use acp::{Id, Message, SessionUpdate};
use herdr_tui::composer::Composer;
use herdr_tui::md;
use herdr_tui::queue::Queue;
use herdr_tui::session::{Event, Record, Session, Start};
use herdr_tui::theme::Theme;
use herdr_tui::transcript::Transcript;
use herdr_tui::ui::{draw, Frame_, Header, View};
use herdr_tui::width;
use ratatui::{backend::TestBackend, buffer::Buffer, layout::Rect, Terminal};
use serde_json::json;
use unicode_width::UnicodeWidthStr;

struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        // xorshift64*
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }

    fn below(&mut self, n: usize) -> usize {
        (self.next() % n as u64) as usize
    }

    fn pick<'a, T>(&mut self, xs: &'a [T]) -> &'a T {
        &xs[self.below(xs.len())]
    }
}

/// Pieces of a cell, each awkward in its own way.
const PIECES: &[&str] = &[
    "a",
    "word",
    "Board",
    "42",
    "-3.5%",
    "",
    " ",
    "two words",
    "日本語のテキスト",
    "ＡＢＣ",
    "한국어",
    "✅",
    "❌",
    "⚠️",
    "❤️",
    "✔️",
    "☑️",
    "1️⃣",
    "©️",
    "👍🏽",
    "👨‍👩‍👧",
    "🇯🇵",
    "🏳️‍🌈",
    "🙂",
    "●",
    "○",
    "◐",
    "─",
    "│",
    "╭",
    "e\u{301}",
    "a\u{300}\u{301}",
    "ก็",
    "नमस्ते",
    "שלום",
    "مرحبا",
    "\u{200b}",
    "\u{ad}",
    "\u{a0}",
    "x\u{200d}y",
    "\u{feff}",
    "`code`",
    "`a | b`",
    "**bold**",
    "*it*",
    "~~gone~~",
    "[link](https://example.com/a/very/long/url/that/does/not/break)",
    "![img](x.png)",
    "&amp;",
    "<b>",
    "\\|",
    "a\\|b",
    "supercalifragilisticexpialidocious_and_then_some_more_letters_without_any_break_at_all",
    "https://example.com/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "\u{1b}[2Jevil",
    "\u{7}bell",
    "\u{202e}rtl",
    "tab\there",
    "line<br>break",
];

fn cell(rng: &mut Rng) -> String {
    let n = 1 + rng.below(4);
    let mut s = String::new();
    for i in 0..n {
        if i > 0 && rng.below(3) > 0 {
            s.push(' ');
        }
        s.push_str(rng.pick(PIECES));
    }
    s
}

fn table(rng: &mut Rng) -> String {
    let cols = 1 + rng.below(8);
    let rows = rng.below(6);
    let mut out = String::new();
    let row = |rng: &mut Rng, n: usize| -> String {
        let mut r = String::from("|");
        for _ in 0..n {
            r.push(' ');
            r.push_str(&cell(rng));
            r.push_str(" |");
        }
        r
    };
    out.push_str(&row(rng, cols));
    out.push('\n');
    out.push('|');
    for _ in 0..cols {
        out.push_str(match rng.below(5) {
            0 => ":--|",
            1 => "--:|",
            2 => ":-:|",
            3 => "-|",
            _ => "---|",
        });
    }
    out.push('\n');
    for _ in 0..rows {
        // Ragged now and then: too few cells, too many.
        let n = match rng.below(8) {
            0 => cols.saturating_sub(1).max(1),
            1 => cols + 1,
            _ => cols,
        };
        out.push_str(&row(rng, n));
        out.push('\n');
    }
    out
}

fn document(rng: &mut Rng) -> String {
    let mut doc = String::new();
    for _ in 0..1 + rng.below(3) {
        match rng.below(6) {
            0 => doc.push_str(
                "Some text before the table, long enough to wrap at the narrower widths.\n\n",
            ),
            1 => doc.push_str(&format!("{}. {}\n\n", 1 + rng.below(30), cell(rng))),
            2 => {
                // A table inside a list item or a quote.
                let prefix = if rng.below(2) == 0 { "- " } else { "> " };
                for (i, l) in table(rng).lines().enumerate() {
                    doc.push_str(if i == 0 {
                        prefix
                    } else if prefix == "- " {
                        "  "
                    } else {
                        "> "
                    });
                    doc.push_str(l);
                    doc.push('\n');
                }
                doc.push('\n');
            }
            3 => {
                // Two tables with or without a blank line between.
                doc.push_str(&table(rng));
                if rng.below(2) == 0 {
                    doc.push('\n');
                }
                doc.push_str(&table(rng));
                doc.push('\n');
            }
            _ => {
                doc.push_str(&table(rng));
                doc.push('\n');
            }
        }
    }
    doc
}

fn lines_text(lines: &[ratatui::text::Line]) -> Vec<String> {
    lines
        .iter()
        .map(|l| l.spans.iter().map(|s| s.content.as_ref()).collect())
        .collect()
}

fn has_forbidden(s: &str) -> Option<char> {
    s.chars().find(|c| {
        (c.is_control() && *c != '\n' && *c != '\t')
            || matches!(c, '\u{200e}' | '\u{200f}' | '\u{202a}'..='\u{202e}' | '\u{2066}'..='\u{2069}' | '\u{61c}' | '\u{fe0e}' | '\u{fe0f}' | '\u{200d}')
    })
}

/// The boxes in `rows`: every line from a `╭` to its `╰` (a table drawn whole).
fn boxes(rows: &[String]) -> Vec<&[String]> {
    let mut out = Vec::new();
    let mut start = None;
    for (i, r) in rows.iter().enumerate() {
        let t = r.trim_start_matches([' ', '│', '>', '-', '•', '▏']);
        if t.starts_with('╭') {
            start = Some(i);
        } else if t.starts_with('╰') {
            if let Some(s) = start.take() {
                out.push(&rows[s..=i]);
            }
        }
    }
    out
}

fn count() -> u64 {
    std::env::var("HERDR_STRESS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(400)
}

#[test]
fn no_table_document_overflows_panics_or_breaks_its_box_at_any_width() {
    for seed in 1..=count() {
        let mut rng = Rng(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1);
        let doc = document(&mut rng);
        // 8 columns is the narrowest the layouts promise (`no_table_overflows_at_any_width_or_shape`).
        for w in [8usize, 9, 13, 20, 31, 48, 80, 120] {
            let rows = lines_text(&md::render(&doc, w, Theme::detect(None)));
            for r in &rows {
                assert!(
                    width::of(r) <= w,
                    "seed {seed} at {w}: a row of {} columns: {r:?}\n--- document\n{doc}",
                    width::of(r)
                );
                if let Some(c) = has_forbidden(r) {
                    panic!("seed {seed} at {w}: {c:?} got through: {r:?}\n--- document\n{doc}");
                }
            }
            for b in boxes(&rows) {
                let first = width::of(&b[0]);
                for r in b {
                    assert_eq!(
                        width::of(r),
                        first,
                        "seed {seed} at {w}: a box with rows of different widths: {b:#?}\n--- document\n{doc}"
                    );
                    // The terminal's own measure of the whole row agrees with the layout's, or a
                    // glyph is drawn wider or narrower than the layout thinks.
                    let str_w = UnicodeWidthStr::width(r.as_str());
                    assert_eq!(
                        str_w, first,
                        "seed {seed} at {w}: layout and string widths disagree on {r:?}\n--- document\n{doc}"
                    );
                }
            }
        }
    }
}

#[test]
fn a_table_arriving_a_character_at_a_time_never_panics_or_overflows() {
    for seed in 1..=(count() / 8).max(20) {
        let mut rng = Rng(seed.wrapping_mul(0xD6E8_FEB8_6659_FD93) | 1);
        let doc = document(&mut rng);
        let idx: Vec<usize> = doc
            .char_indices()
            .map(|(i, _)| i)
            .chain([doc.len()])
            .collect();
        for w in [10usize, 33, 70] {
            for &i in idx.iter().step_by(1 + doc.len() / 120) {
                let rows = lines_text(&md::render_live(&doc[..i], w, Theme::detect(None)));
                for r in &rows {
                    assert!(
                        width::of(r) <= w && has_forbidden(r).is_none(),
                        "seed {seed} at {w}, {i} bytes in: {r:?}\n--- document\n{doc}"
                    );
                }
            }
        }
    }
}

/// What a terminal shows after it is sent ratatui's updates: a wide glyph covers the next cell,
/// and writing over either half of one blanks the other. `""` is a covered cell.
struct Screen {
    w: usize,
    cells: Vec<String>,
}

impl Screen {
    fn new(w: u16, h: u16) -> Screen {
        Screen {
            w: usize::from(w),
            cells: vec![" ".to_string(); usize::from(w) * usize::from(h)],
        }
    }

    /// Blanks the whole glyph that has a cell at `p` (both halves of a wide one).
    fn erase(&mut self, p: usize, row: usize) {
        let mut s = p;
        while s > row && self.cells[s].is_empty() {
            s -= 1;
        }
        for k in 0..width::of(&self.cells[s]).max(1) {
            if s + k < row + self.w {
                self.cells[s + k] = " ".to_string();
            }
        }
    }

    fn put(&mut self, x: u16, y: u16, sym: &str) {
        let row = usize::from(y) * self.w;
        let i = row + usize::from(x);
        let wide = width::of(sym).max(1);
        // Every cell the new glyph lands on may be half of another: that glyph goes entirely.
        for k in 0..wide {
            if usize::from(x) + k < self.w {
                self.erase(i + k, row);
            }
        }
        self.cells[i] = sym.to_string();
        for k in 1..wide {
            if usize::from(x) + k < self.w {
                self.cells[i + k] = String::new();
            }
        }
    }

    fn of(b: &Buffer) -> Screen {
        let (w, h) = (b.area.width, b.area.height);
        let mut s = Screen::new(w, h);
        for y in 0..h {
            for x in 0..w {
                if !s.cells[usize::from(y) * s.w + usize::from(x)].is_empty() {
                    s.put(x, y, b[(x, y)].symbol());
                }
            }
        }
        s
    }
}

fn ready_session() -> Session {
    let (mut s, _) = Session::begin(Start::Attach, None);
    let mut scratch = Transcript::default();
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

fn frame(
    tr: &Transcript,
    session: &Session,
    w: u16,
    h: u16,
    view: &mut View,
    composer: &Composer,
) -> (Buffer, ratatui::layout::Position) {
    let mut term = Terminal::new(TestBackend::new(w, h)).expect("a test terminal");
    let ctx = Frame_ {
        transcript: tr,
        session,
        composer,
        header: Header {
            agent: "omp",
            cwd: "/w",
        },
        theme: Theme::detect(None),
        hint: None,
        working_secs: None,
        queue: &Queue::default(),
        newer: None,
    };
    term.draw(|f| draw(f, &ctx, view)).expect("drawn");
    let cursor = term.get_cursor_position().expect("a cursor position");
    (term.backend().buffer().clone(), cursor)
}

/// A conversation of every kind of entry, each built from the awkward pieces.
fn conversation(rng: &mut Rng) -> Transcript {
    let mut tr = Transcript::default();
    let update = |v: serde_json::Value| SessionUpdate::from_value(&v).expect("update");
    for k in 0..9 {
        match rng.below(7) {
            0 => tr.user(cell(rng)),
            1 => tr.note(cell(rng)),
            2 => {
                let status = *rng.pick(&["completed", "failed", "in_progress"]);
                tr.apply(update(
                    json!({"sessionUpdate": "tool_call", "toolCallId": format!("t{k}"),
                    "title": cell(rng), "kind": rng.pick(&["execute", "read", "edit", "fetch"]),
                    "status": status,
                    "rawInput": {"command": cell(rng)},
                    "content": [{"type": "content", "content": {"type": "text",
                        "text": format!("{}\n{}\n{}", cell(rng), cell(rng), cell(rng))}}]}),
                ));
            }
            3 => tr.apply(update(json!({"sessionUpdate": "agent_thought_chunk",
                "messageId": format!("th{k}"), "content": {"type": "text", "text": cell(rng)}}))),
            4 => {
                let entries: Vec<serde_json::Value> = (0..1 + rng.below(6))
                    .map(|_| json!({"content": cell(rng), "status": rng.pick(&["pending", "in_progress", "completed"])}))
                    .collect();
                tr.apply(update(json!({"sessionUpdate": "plan", "entries": entries})));
            }
            _ => {
                let doc: String = (0..2).map(|_| document(rng)).collect();
                tr.apply(update(json!({"sessionUpdate": "agent_message_chunk",
                    "messageId": format!("m{k}"), "content": {"type": "text", "text": doc}})));
            }
        }
    }
    tr
}

#[test]
fn scrolling_a_conversation_of_awkward_content_leaves_nothing_behind() {
    let session = ready_session();
    for seed in 1..=(count() / 20).max(12) {
        let mut rng = Rng(seed.wrapping_mul(0xA24B_AED4_963E_E407) | 1);
        let tr = conversation(&mut rng);
        for (w, h) in [(48u16, 14u16), (90, 20)] {
            let mut warm = View::default();
            let mut shown = Screen::new(w, h);
            let mut prev = Buffer::empty(Rect::new(0, 0, w, h));
            for step in 0..24 {
                // Up, down, jumps: a reader's scrolling, with something typed in the box now and
                // then (wide text, on one row or several).
                let scroll = match step % 4 {
                    0 => rng.below(400),
                    1 => rng.below(30),
                    2 => 0,
                    _ => rng.below(120),
                };
                let mut composer = Composer::default();
                if rng.below(3) == 0 {
                    for _ in 0..1 + rng.below(4) {
                        composer.insert_str(&cell(&mut rng));
                        if rng.below(3) == 0 {
                            composer.insert('\n');
                        }
                    }
                    // Anywhere in the text.
                    for _ in 0..rng.below(8) {
                        composer.left();
                    }
                }
                warm.scroll = scroll;
                let (next, cursor) = frame(&tr, &session, w, h, &mut warm, &composer);
                assert!(
                    cursor.x < w && cursor.y < h,
                    "seed {seed} {w}x{h}: the cursor is off the screen at {cursor:?}"
                );
                let before = prev.clone();
                let updates: Vec<(u16, u16, String)> = prev
                    .diff(&next)
                    .into_iter()
                    .map(|(x, y, c)| (x, y, c.symbol().to_string()))
                    .collect();
                for (x, y, s) in &updates {
                    shown.put(*x, *y, s);
                }
                prev = next;
                let mut cold = View::default();
                cold.scroll = scroll;
                let want = Screen::of(&frame(&tr, &session, w, h, &mut cold, &composer).0);
                let bad: Vec<(usize, usize, &str, &str)> = shown
                    .cells
                    .iter()
                    .zip(&want.cells)
                    .enumerate()
                    .filter(|(_, (a, b))| a != b)
                    .map(|(i, (a, b))| {
                        (
                            i % usize::from(w),
                            i / usize::from(w),
                            a.as_str(),
                            b.as_str(),
                        )
                    })
                    .collect();
                if let Some(&(bx, by, _, _)) = bad.first() {
                    let row = |b: &Buffer| -> Vec<String> {
                        (bx.saturating_sub(4)..(bx + 6).min(usize::from(w)))
                            .map(|x| b[(x as u16, by as u16)].symbol().to_string())
                            .collect()
                    };
                    eprintln!(
                        "x {}..: before {:?}\n       now    {:?}\n updates on row {by}: {:?}",
                        bx.saturating_sub(4),
                        row(&before),
                        row(&prev),
                        updates
                            .iter()
                            .filter(|u| usize::from(u.1) == by
                                && usize::from(u.0) + 6 > bx
                                && usize::from(u.0) < bx + 6)
                            .collect::<Vec<_>>()
                    );
                    for y in 0..h {
                        let line: String = (0..w).map(|x| prev[(x, y)].symbol()).collect();
                        eprintln!("{y:>2}|{line}|");
                    }
                }
                assert!(
                    bad.is_empty(),
                    "seed {seed} {w}x{h} scroll={scroll}: left behind (x, y, shown, cold) {bad:?}"
                );
            }
        }
    }
}

/// Prose: headings, lists, quotes, code, rules, mixed with tables.
fn prose(rng: &mut Rng) -> String {
    let mut doc = String::new();
    for _ in 0..2 + rng.below(6) {
        let c = cell(rng);
        match rng.below(11) {
            0 => doc.push_str(&format!("# {c}\n\n")),
            1 => doc.push_str(&format!("### {c} {}\n\n", cell(rng))),
            2 => doc.push_str(&format!(
                "- {c}\n  - {}\n    - {}\n\n",
                cell(rng),
                cell(rng)
            )),
            3 => doc.push_str(&format!("1. {c}\n2. {}\n\n", cell(rng))),
            4 => doc.push_str(&format!("> {c}\n> {}\n\n", cell(rng))),
            5 => doc.push_str(&format!("```\n{c}\n{}\n```\n\n", cell(rng))),
            6 => doc.push_str("---\n\n"),
            7 => doc.push_str(&format!(
                "**{c}** and *{}* and `{}`\n\n",
                cell(rng),
                cell(rng)
            )),
            8 => doc.push_str(&table(rng)),
            _ => doc.push_str(&format!("{c} {} {}\n\n", cell(rng), cell(rng))),
        }
    }
    doc
}

#[test]
fn no_document_overflows_or_lets_a_control_through_at_any_width() {
    for seed in 1..=count() {
        let mut rng = Rng(seed.wrapping_mul(0xC13F_A9A9_02A6_328F) | 1);
        let doc = prose(&mut rng);
        for w in [8usize, 11, 17, 29, 60, 100] {
            for r in lines_text(&md::render(&doc, w, Theme::detect(None))) {
                assert!(
                    width::of(&r) <= w,
                    "seed {seed} at {w}: a row of {} columns: {r:?}\n--- document\n{doc}",
                    width::of(&r)
                );
                if let Some(c) = has_forbidden(&r) {
                    panic!("seed {seed} at {w}: {c:?} got through: {r:?}\n--- document\n{doc}");
                }
            }
        }
    }
}
