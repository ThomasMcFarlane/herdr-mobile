//! Drawing. Only the lines that can be seen are built: a long history costs
//! nothing until it is scrolled to.
//!
//! The layout keeps one left gutter of two columns: what the person said sits in a tinted band
//! behind a `›`, what the agent said hangs from a `•`, and every tool call, note and result
//! opens with its mark in the same column. Below the conversation sit the panel that asks (a
//! permission or a question, when one waits), the rule that carries the session's title, the
//! input, a status line and one line of facts about the session.

use crate::composer::Composer;
use crate::elapsed;
use crate::fold::{self, Block};
use crate::md::{self, clean};
use crate::queue;
use crate::select::{self, Selection};
use crate::session::{Ask, Phase, Session};
use crate::shell;
use crate::slash;
use crate::theme::Theme;
use crate::transcript::{Entry, Item, Role, Tool, Transcript};
use crate::width;
use acp::ToolStatus;
use ratatui::{
    layout::{Constraint, Layout, Position, Rect},
    style::{Modifier, Style},
    text::{Line, Span},
    widgets::Paragraph,
    Frame,
};
use std::collections::{HashMap, HashSet, VecDeque};

/// Columns every block keeps free on the left for its mark.
const GUTTER: usize = 2;
/// Rows the composer may grow to.
const COMPOSER_MAX: usize = 6;
/// Rows of a command shown on the permission panel before it is cut.
const SUBJECT_MAX_ROWS: usize = 12;
/// Diff rows shown under an edit when it is open, and the last lines of a failed call's output.
const DIFF_OPEN_ROWS: usize = 60;
const FAILED_TAIL_ROWS: usize = 2;

#[derive(Default)]
pub struct View {
    /// Lines up from the bottom; 0 follows the newest output.
    pub scroll: usize,
    /// Ctrl-T: every thought open.
    pub thoughts: bool,
    /// Rows of one page of conversation (set when drawn), for PgUp and PgDn.
    pub page: usize,
    /// The option chosen on the permission panel.
    pub sel: usize,
    /// The blocks the person has opened, by key.
    pub expanded: HashSet<u64>,
    /// The block browse mode is on, when it is on.
    pub focus: Option<u64>,
    /// The focus moved: the next frame brings it into view.
    pub focus_dirty: bool,
    /// The key list is open (`?`).
    pub help: bool,
    /// The command list opened by typing `/`, and the row chosen on it.
    pub palette: Vec<slash::Entry>,
    pub palette_sel: usize,
    /// The choices of the option being changed (`/model`), while its picker is open.
    pub picker: Option<slash::Picker>,
    /// The files attached to the next message, by name (one row above the input).
    pub chips: Vec<String>,
    /// How far `/update` has got, while one runs (the footer says it).
    pub update: Option<String>,
    /// The lines of the blocks, kept from one frame to the next, and the width they were built at.
    line_cache: LineCache,
    last_width: usize,
    /// What a click lands on, as last drawn: per screen row of the conversation, the key of the
    /// block there when it folds; and the first row the conversation starts at.
    fold_rows: Vec<Option<u64>>,
    fold_top: u16,
    /// Per screen row of the panel that asks (a permission or a question), the option drawn
    /// there, and the panel's first row.
    option_rows: Vec<Option<usize>>,
    option_top: u16,
    /// Per screen row of the queue above the input, the message drawn there, and its first row.
    queue_ids: Vec<Option<u64>>,
    queue_top: u16,
    /// How many queued messages had no room to be drawn, as last drawn.
    queue_hidden: usize,
    /// A block that was clicked open or closed, and the screen row its first line was on: it
    /// stays there while it changes height, as far as showing what it opened allows.
    anchor: Option<(u64, usize)>,
    /// Scrolled back: the block at the bottom edge and how far into it, at the scroll it was
    /// taken at. Output that arrives below then leaves what the person reads where it is.
    hold: Option<Hold>,
    /// The screen row of the "below · End" control, when it is drawn.
    newest_row: Option<u16>,
    /// The agent message that was still arriving when last drawn.
    live: Option<u64>,
    /// What the pointer is selecting, or selected when the button last went up. Cells of the
    /// screen as drawn, so it is dropped as soon as the person does something else.
    pub select: Option<Selection>,
}

#[derive(Clone, Copy)]
struct Hold {
    key: u64,
    off: usize,
    at: usize,
}

impl View {
    /// What a block draws changed without its key changing (a block opened or closed, the
    /// focus moved, the thoughts toggle flipped): the lines kept for it cannot be reused.
    pub fn invalidate_lines(&mut self) {
        self.line_cache.clear();
    }

    /// How many characters of block lines the cache is holding (the "low memory" gauge).
    pub fn cache_chars(&self) -> usize {
        self.line_cache.chars()
    }

    /// The option of the asking panel drawn on screen row `y`, as last drawn.
    #[must_use]
    pub fn option_at(&self, y: u16) -> Option<usize> {
        let row = y.checked_sub(self.option_top)?;
        self.option_rows.get(usize::from(row)).copied().flatten()
    }

    /// The queued message drawn on screen row `y`, as last drawn.
    #[must_use]
    pub fn queued_at(&self, y: u16) -> Option<u64> {
        let row = y.checked_sub(self.queue_top)?;
        self.queue_ids.get(usize::from(row)).copied().flatten()
    }

    /// A click on screen row `y`: when it is on the "below · End" control, back to the newest.
    pub fn click_newest(&mut self, y: u16) -> bool {
        if self.newest_row != Some(y) {
            return false;
        }
        self.scroll = 0;
        true
    }

    /// A click on screen row `y`: opens or closes the block drawn there, when it folds, keeping
    /// its first row where it was. `true` when something opened or closed.
    pub fn click_fold(&mut self, y: u16) -> bool {
        let Some(row) = y.checked_sub(self.fold_top).map(usize::from) else {
            return false;
        };
        let Some(key) = self.fold_rows.get(row).copied().flatten() else {
            return false;
        };
        // Where the block's first line is now: the clicked row, less the block's rows above it.
        let top = self.fold_rows[..row]
            .iter()
            .rev()
            .take_while(|k| **k == Some(key))
            .count();
        if !self.expanded.remove(&key) {
            self.expanded.insert(key);
        }
        self.anchor = Some((key, row - top));
        self.invalidate_lines();
        true
    }
}

/// What a cache of block lines is keyed by: the block, the content revision of what it draws
/// (a `One`'s item revision, a `Run`'s fold of its calls' — so a streaming edit moves the
/// line), the width it was wrapped to, and a generation that is bumped whenever the look
/// changes (a block opens or closes, the focus moves, the thoughts toggle flips). Bumping the
/// generation clears the cache, so it only ever holds the lines for the current look: a scroll
/// is all hits, a focus move is one rebuild. The content revision is the field that makes an
/// in-place edit safe: it keeps the block's id, so the id alone would serve the old line.
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
struct LineKey {
    block: u64,
    rev: u64,
    width: usize,
    gen: u64,
}

/// What a cache entry costs, in the units the budget is measured in: the characters in its
/// lines. A line is a handful of spans, so characters are a fair stand-in for its memory.
fn line_size(l: &[Line<'static>]) -> usize {
    l.iter()
        .map(|r| {
            r.spans
                .iter()
                .map(|s| s.content.chars().count())
                .sum::<usize>()
        })
        .sum()
}

/// The lines of the blocks, kept from one frame to the next: a scroll, a keystroke or a frame
/// that does not touch what a block draws costs a lookup, not a re-wrap. Bounded by characters
/// the way the transcript is, so a viewer left open for days stays small: the oldest lines are
/// dropped first, and a block that scrolls back into view is simply built again. Lived here,
/// not in [`View`], because the look a block is drawn with borrows what the view keeps open.
#[derive(Default)]
struct LineCache {
    lines: HashMap<LineKey, Vec<Line<'static>>>,
    /// Insertion order, oldest first, for the eviction.
    order: VecDeque<LineKey>,
    chars: usize,
    gen: u64,
}

/// How much of the conversation's lines the cache may keep: a few screens' worth, so a steady
/// scroll is all hits and a long scroll only rebuilds what it walks back past.
const CACHE_BUDGET: usize = 256 * 1024;

impl LineCache {
    /// The block's lines, built once and kept; a borrow into the cache, no copy.
    fn ensure(
        &mut self,
        b: Block,
        items: &VecDeque<Item>,
        width: usize,
        look: Look,
    ) -> &Vec<Line<'static>> {
        let key = LineKey {
            block: fold::key(b, items),
            rev: fold::revision(b, items),
            width,
            gen: self.gen,
        };
        if !self.lines.contains_key(&key) {
            self.order.push_back(key);
            let l = block_lines(b, items, width, look);
            self.chars += line_size(&l);
            self.lines.insert(key, l);
            self.enforce();
        }
        self.lines.get(&key).expect("just inserted")
    }

    /// How many lines a block draws, without copying them: a scroll walks this per block,
    /// so a long history costs a lookup each, not a clone.
    fn count_for(&mut self, b: Block, items: &VecDeque<Item>, width: usize, look: Look) -> usize {
        self.ensure(b, items, width, look).len()
    }

    /// The budget: drop the oldest lines until the cache fits. A block that is evicted is
    /// rebuilt when it is needed again; its key is stable, so nothing stale is ever drawn.
    fn enforce(&mut self) {
        while self.chars > CACHE_BUDGET {
            let Some(old) = self.order.pop_front() else {
                break;
            };
            if let Some(gone) = self.lines.remove(&old) {
                self.chars = self.chars.saturating_sub(line_size(&gone));
            }
        }
    }

    /// How many characters of lines the cache is holding.
    fn chars(&self) -> usize {
        self.chars
    }

    /// The "what is open" state changed (a block opened or closed, the focus moved, the
    /// thoughts toggle flipped) or the width did: nothing drawn from the old state can be
    /// reused.
    fn clear(&mut self) {
        self.gen = self.gen.wrapping_add(1);
        self.lines.clear();
        self.order.clear();
        self.chars = 0;
    }
}
/// What the footer says about the session.
pub struct Header<'a> {
    pub agent: &'a str,
    pub cwd: &'a str,
}

/// Everything a frame is drawn from.
pub struct Frame_<'a> {
    pub transcript: &'a Transcript,
    pub session: &'a Session,
    pub composer: &'a Composer,
    pub header: Header<'a>,
    pub theme: Theme,
    /// Why the last key did nothing, until the next key.
    pub hint: Option<&'a str>,
    /// Seconds the current turn has run, when one does.
    pub working_secs: Option<u64>,
    /// The messages waiting for the turn to end.
    pub queue: &'a queue::Queue,
    /// The version of a newer herdr-tui that was installed while this one ran (`Ctrl-R` loads it).
    pub newer: Option<&'a str>,
}

fn width_of(s: &str) -> usize {
    width::of(s)
}

/// The rows `text` wraps to, as byte ranges into it: at spaces, by display width, and a word longer
/// than a row is cut. [`wrap`] and the cursor both use this, so the cursor is always put on the row
/// that is drawn.
fn wrap_ranges(text: &str, width: usize) -> Vec<(usize, usize)> {
    let width = width.max(1);
    let mut rows = Vec::new();
    let mut line_start = 0;
    for raw in text.split('\n') {
        let line_end = line_start + raw.len();
        let (mut row_start, mut w, mut at) = (line_start, 0usize, line_start);
        for word in raw.split_inclusive(' ') {
            let ww = width_of(word);
            if w + ww > width && at > row_start {
                rows.push((row_start, at));
                row_start = at;
                w = 0;
            }
            if w + ww <= width {
                // Fits whole: no need to look inside it.
                w += ww;
            } else {
                for (i, _, cw) in width::cluster_indices(word) {
                    if w + cw > width && at + i > row_start {
                        rows.push((row_start, at + i));
                        row_start = at + i;
                        w = 0;
                    }
                    w += cw;
                }
            }
            at += word.len();
        }
        rows.push((row_start, line_end));
        line_start = line_end + 1;
    }
    rows
}

/// Wraps plain text to `width` columns (display width), keeping blank lines.
pub fn wrap(text: &str, width: usize) -> Vec<String> {
    let text = clean(text).replace('\t', "    ");
    wrap_ranges(&text, width)
        .into_iter()
        .map(|(a, b)| text[a..b].to_string())
        .collect()
}

/// The row and column of byte `cursor` among `rows` (from [`wrap_ranges`]). A row that is exactly
/// full puts the cursor at the start of the next one, not past the edge.
fn cursor_cell(text: &str, cursor: usize, width: usize, rows: &[(usize, usize)]) -> (usize, usize) {
    let r = rows
        .iter()
        .rposition(|(start, _)| *start <= cursor)
        .unwrap_or(0);
    let col = width_of(&text[rows.get(r).map_or(0, |row| row.0)..cursor]);
    if col >= width.max(1) {
        (r + 1, 0)
    } else {
        (r, col)
    }
}

fn headed(
    text: &str,
    width: usize,
    head: &'static str,
    head_style: Style,
    style: Style,
) -> Vec<Line<'static>> {
    let hw = head.chars().count();
    wrap(text, width.saturating_sub(hw))
        .into_iter()
        .enumerate()
        .map(|(i, l)| {
            let lead = if i == 0 {
                Span::styled(head, head_style)
            } else {
                Span::raw(" ".repeat(hw))
            };
            Line::from(vec![lead, Span::styled(l, style)])
        })
        .collect()
}

/// `s` cut to `width` columns with an ellipsis where it was cut.
fn fit(s: &str, width: usize) -> String {
    if width_of(s) <= width {
        return s.to_string();
    }
    let mut out = String::new();
    let mut w = 0;
    for (g, cw) in width::clusters(s) {
        if w + cw + 1 > width {
            break;
        }
        out.push_str(g);
        w += cw;
    }
    out.push('…');
    out
}

/// Lines padded to `width` and given the band's background, so the tint is a solid block.
fn band(lines: Vec<Line<'static>>, width: usize, bg: Style) -> Vec<Line<'static>> {
    lines
        .into_iter()
        .map(|l| {
            let used: usize = l.spans.iter().map(|s| width_of(&s.content)).sum();
            let mut spans: Vec<Span<'static>> = l
                .spans
                .into_iter()
                .map(|s| Span::styled(s.content, s.style.patch(bg)))
                .collect();
            spans.push(Span::styled(" ".repeat(width.saturating_sub(used)), bg));
            Line::from(spans)
        })
        .collect()
}

/// What the person said: a tinted band with a `›`, or, where the terminal's background is
/// unknown, a bar down the left edge.
fn user_lines(text: &str, width: usize, theme: Theme) -> Vec<Line<'static>> {
    let inner = width.saturating_sub(GUTTER + 1);
    match theme.band() {
        Some(bg) => {
            let mut rows = vec![Line::default()];
            rows.extend(wrap(text, inner).into_iter().enumerate().map(|(i, l)| {
                let mark = if i == 0 {
                    Span::styled("› ", theme.dim())
                } else {
                    Span::raw("  ")
                };
                Line::from(vec![mark, Span::raw(l)])
            }));
            rows.push(Line::default());
            band(rows, width, bg)
        }
        None => wrap(text, inner)
            .into_iter()
            .map(|l| {
                Line::from(vec![
                    Span::styled("▎ ", theme.accent()),
                    Span::styled(l, theme.bold()),
                ])
            })
            .collect(),
    }
}

/// What the agent said: markdown hanging from a bullet. `live`: it is still arriving
/// ([`md::render_live`]).
fn agent_lines(text: &str, width: usize, theme: Theme, live: bool) -> Vec<Line<'static>> {
    let inner = width.saturating_sub(GUTTER);
    let lines = if live {
        md::render_live(text, inner, theme)
    } else {
        md::render(text, inner, theme)
    };
    lines
        .into_iter()
        .enumerate()
        .map(|(i, mut l)| {
            let lead = if i == 0 {
                Span::styled("• ", theme.dim())
            } else {
                Span::raw("  ")
            };
            l.spans.insert(0, lead);
            l
        })
        .collect()
}

/// What the conversation is drawn with: what is open, what has focus.
#[derive(Clone, Copy)]
struct Look<'a> {
    expanded: &'a HashSet<u64>,
    focus: Option<u64>,
    /// Ctrl-T: every thought open.
    thoughts: bool,
    theme: Theme,
    /// The agent message still arriving, if one is.
    live: Option<u64>,
}

impl Look<'_> {
    fn open(&self, id: u64) -> bool {
        self.expanded.contains(&id)
    }
    fn focused(&self, id: u64) -> bool {
        self.focus == Some(id)
    }
}

/// The mark that says a block can be opened: quiet, or a lit pill when it has the focus.
fn chevron(open: bool, focused: bool, theme: Theme) -> Span<'static> {
    let glyph = if open { "▾" } else { "▸" };
    if focused {
        Span::styled(
            format!(" {glyph} "),
            theme
                .accent()
                .add_modifier(Modifier::BOLD | Modifier::REVERSED),
        )
    } else {
        Span::styled(format!(" {glyph}"), theme.dim())
    }
}

/// Columns a chevron may take, kept free at the end of a row.
const CHEVRON_W: usize = 3;

/// A tool call's title. A call still running or failed shows its shell command in colour; one that
/// finished is background, so it is plain and quiet.
fn title_lines(
    t: &Tool,
    width: usize,
    glyph: &'static str,
    glyph_style: Style,
    theme: Theme,
    tail: usize,
    quiet: bool,
) -> Vec<Line<'static>> {
    let body = match (quiet, t.title.strip_prefix("$ ")) {
        (true, shown) => vec![Span::styled(clean(shown.unwrap_or(&t.title)), theme.dim())],
        (false, Some(cmd)) => shell::highlight(&clean(cmd), theme),
        (false, None) => vec![Span::raw(clean(&t.title))],
    };
    let mut rows = md::wrap_spans(
        body,
        vec![Span::styled(glyph, glyph_style)],
        vec![Span::raw("  ")],
        width.saturating_sub(tail),
    );
    rows.truncate(2);
    rows
}

fn dim_row(indent: &'static str, text: &str, width: usize, theme: Theme) -> Line<'static> {
    Line::from(vec![
        Span::styled(indent, theme.dim()),
        Span::styled(
            fit(&clean(text), width.saturating_sub(indent.chars().count())),
            theme.dim(),
        ),
    ])
}

fn tool_lines(
    t: &Tool,
    width: usize,
    open: bool,
    focused: bool,
    theme: Theme,
) -> Vec<Line<'static>> {
    let completed = t.status == ToolStatus::Completed;
    let (glyph, gs) = match t.status {
        ToolStatus::Completed => ("  ", theme.dim()),
        ToolStatus::Failed => ("✗ ", theme.bad()),
        ToolStatus::Pending | ToolStatus::InProgress => ("◌ ", theme.dim()),
    };
    let stat = t
        .diffs
        .first()
        .map(crate::diff::hunk)
        .map(|h| format!("  +{} −{}", h.added, h.removed));
    let foldable = fold::tool_foldable(t);
    let tail = stat.as_ref().map_or(0, |s| width_of(s)) + if foldable { CHEVRON_W } else { 0 };
    let mut out = title_lines(t, width, glyph, gs, theme, tail, completed);
    if let Some(last) = out.last_mut() {
        if let Some(stat) = stat {
            last.spans.push(Span::styled(stat, theme.dim()));
        }
        if foldable {
            last.spans.push(chevron(open, focused, theme));
        }
        if focused {
            for span in &mut last.spans[1..] {
                span.style = span.style.add_modifier(Modifier::BOLD);
            }
        }
    }
    let running = matches!(t.status, ToolStatus::Pending | ToolStatus::InProgress);
    if running {
        if let Some(subject) = &t.subject {
            let first = clean(subject).lines().next().unwrap_or("").to_string();
            if !t.title.contains(first.as_str()) {
                let mut spans = vec![Span::styled("  └ ", theme.dim())];
                if t.kind.as_deref() == Some("execute") {
                    spans.extend(shell::highlight(
                        &fit(&first, width.saturating_sub(4)),
                        theme,
                    ));
                } else {
                    spans.push(Span::styled(
                        fit(&first, width.saturating_sub(4)),
                        theme.dim(),
                    ));
                }
                out.push(Line::from(spans));
            }
        }
    }
    // The last lines that say something: blank rows are not evidence.
    let said: Vec<&String> = t
        .output
        .head
        .iter()
        .chain(&t.output.tail)
        .filter(|l| !l.trim().is_empty())
        .collect();
    if open && !said.is_empty() {
        for l in &t.output.head {
            out.push(dim_row("    ", l, width, theme));
        }
        if t.output.omitted > 0 {
            out.push(dim_row(
                "    ",
                &format!("… {} lines not kept", t.output.omitted),
                width,
                theme,
            ));
        }
        for l in &t.output.tail {
            out.push(dim_row("    ", l, width, theme));
        }
    } else if t.status == ToolStatus::Failed {
        // One reason, not a stack: what failed, in its own last words.
        let skip = said.len().saturating_sub(FAILED_TAIL_ROWS);
        for l in said.into_iter().skip(skip) {
            out.push(dim_row("    ", l, width, theme));
        }
        if t.output.head.is_empty() && t.output.tail.is_empty() {
            if let Some(first) = t.subject.as_deref().and_then(|s| s.lines().next()) {
                out.push(dim_row("    ", first, width, theme));
            }
        }
    }
    if let Some(d) = t.diffs.first() {
        let rows = crate::diff::hunk(d).rows;
        let total = rows.len();
        let show = if open {
            DIFF_OPEN_ROWS
        } else {
            fold::DIFF_FOLDED_ROWS
        };
        let rows: Vec<(char, String)> = rows
            .into_iter()
            .take(show)
            .map(|(m, t)| (m, clean(&t).replace('\t', "    ")))
            .collect();
        // Each side read as the file it is: the old side (context and removed lines) and the new
        // side (context and added), so a string or comment open across lines stays one.
        let lang = crate::highlight::for_path(&d.path);
        let side = |keep: char| -> Vec<Option<Vec<Span<'static>>>> {
            let picked: Vec<&str> = rows
                .iter()
                .filter(|(m, _)| *m == ' ' || *m == keep)
                .map(|(_, t)| t.as_str())
                .collect();
            let mut coloured = lang
                .and_then(|l| crate::highlight::lines(l, &picked, theme))
                .map(Vec::into_iter);
            rows.iter()
                .map(|(m, _)| {
                    if *m == ' ' || *m == keep {
                        coloured.as_mut().and_then(Iterator::next)
                    } else {
                        None
                    }
                })
                .collect()
        };
        let (old, new) = (side('-'), side('+'));
        for (i, (mark, text)) in rows.into_iter().enumerate() {
            let style = match mark {
                '+' => theme.ok(),
                '-' => theme.bad(),
                _ => theme.dim(),
            };
            // Where the background is known, a changed line sits on a tint of its colour to the
            // right edge, and its text is coloured as code: told apart at a glance, read as code.
            match (mark, theme.diff_row(mark == '+')) {
                ('+' | '-', Some(bg)) => {
                    let code = if mark == '+' { &new[i] } else { &old[i] };
                    let spans = code
                        .clone()
                        .unwrap_or_else(|| vec![Span::raw(text)])
                        .into_iter()
                        .map(|s| Span::styled(s.content, s.style.patch(bg)))
                        .collect();
                    let body = fit_spans(spans, width.saturating_sub(6));
                    let pad = width.saturating_sub(6 + spans_width(&body));
                    let mut line = vec![
                        Span::raw("    "),
                        Span::styled(format!("{mark} "), style.patch(bg)),
                    ];
                    line.extend(body);
                    line.push(Span::styled(" ".repeat(pad), bg));
                    out.push(Line::from(line));
                }
                _ => out.push(Line::from(vec![
                    Span::styled(format!("    {mark} "), style),
                    Span::styled(fit(&text, width.saturating_sub(6)), style),
                ])),
            }
        }
        if total > show {
            out.push(dim_row(
                "    ",
                &format!("… {} more lines", total - show),
                width,
                theme,
            ));
        }
    }
    out
}

/// A run of finished tool calls as one line: how many, how they ended, what they were. The ones
/// that failed stay in view under it, whatever else is folded.
fn run_lines(
    items: &VecDeque<Item>,
    start: usize,
    end: usize,
    open: bool,
    focused: bool,
    width: usize,
    theme: Theme,
) -> Vec<Line<'static>> {
    let tools: Vec<&Tool> = (start..end)
        .filter_map(|i| {
            if let Entry::Tool(t) = &items[i].entry {
                Some(t)
            } else {
                None
            }
        })
        .collect();
    let failed = tools
        .iter()
        .filter(|t| t.status == ToolStatus::Failed)
        .count();
    let mut verbs: Vec<(String, usize)> = Vec::new();
    for t in &tools {
        let verb = clean(
            t.title
                .trim_start_matches("$ ")
                .split_whitespace()
                .next()
                .unwrap_or("tool"),
        );
        match verbs.iter_mut().find(|(v, _)| *v == verb) {
            Some(slot) => slot.1 += 1,
            None => verbs.push((verb, 1)),
        }
    }
    let verbs = verbs
        .iter()
        .map(|(v, n)| {
            if *n > 1 {
                format!("{v} ×{n}")
            } else {
                v.clone()
            }
        })
        .collect::<Vec<_>>()
        .join(" · ");
    let mark = if focused {
        Span::styled(
            if open { "▾ " } else { "▸ " },
            theme
                .accent()
                .add_modifier(Modifier::BOLD | Modifier::REVERSED),
        )
    } else {
        Span::styled(if open { "▾ " } else { "▸ " }, theme.dim())
    };
    let count = format!("{} tool calls", tools.len());
    let count_style = if focused { theme.bold() } else { theme.dim() };
    let mut spans = vec![mark, Span::styled(count.clone(), count_style)];
    let mut used = 2 + width_of(&count);
    if failed > 0 {
        let f = format!(" · {failed} failed");
        used += width_of(&f);
        spans.push(Span::styled(f, theme.bad()));
    }
    if !verbs.is_empty() && width > used + 4 {
        spans.push(Span::styled(
            format!(" · {}", fit(&verbs, width - used - 3)),
            theme.dim(),
        ));
    }
    let mut out = vec![Line::from(spans)];
    if !open {
        for t in tools.iter().filter(|t| t.status == ToolStatus::Failed) {
            out.extend(tool_lines(t, width, false, false, theme));
        }
    }
    out
}

fn is_thought(item: Option<&Item>) -> bool {
    item.is_some_and(|i| {
        matches!(
            i.entry,
            Entry::Message {
                role: Role::Thought,
                ..
            }
        )
    })
}

fn item_lines(
    item: &Item,
    prev: Option<&Item>,
    next: Option<&Item>,
    width: usize,
    look: Look,
) -> Vec<Line<'static>> {
    let theme = look.theme;
    // Agents send empty chunks while they work; nothing to show is nothing to space.
    if let Entry::Message { text, .. } = &item.entry {
        if text.trim().is_empty() {
            return Vec::new();
        }
    }
    let thought_open = look.thoughts || look.open(item.id);
    let mut v = match &item.entry {
        Entry::Message {
            role: Role::User,
            text,
            ..
        } => user_lines(text, width, theme),
        Entry::Message {
            role: Role::Agent,
            text,
            ..
        } => agent_lines(text, width, theme, look.live == Some(item.id)),
        Entry::Message {
            role: Role::Thought,
            text,
            ..
        } if thought_open => headed(
            text,
            width,
            "… ",
            theme.dim(),
            Style::default().add_modifier(Modifier::ITALIC),
        ),
        // Several thoughts in a row say it once.
        Entry::Message {
            role: Role::Thought,
            ..
        } if is_thought(prev) && !look.thoughts && prev.is_some_and(|p| !look.open(p.id)) => {
            return Vec::new()
        }
        Entry::Message {
            role: Role::Thought,
            ..
        } => vec![Line::from(vec![
            Span::styled("… thinking", theme.dim()),
            chevron(false, look.focused(item.id), theme),
        ])],
        Entry::Note(text) => headed(text, width, "· ", theme.dim(), theme.dim()),
        Entry::Done { text, ok: true } => headed(text, width, "✓ ", theme.ok(), theme.dim()),
        Entry::Done { text, ok: false } => headed(text, width, "! ", theme.warn(), theme.dim()),
        Entry::Tool(t) => tool_lines(t, width, look.open(item.id), look.focused(item.id), theme),
    };
    // A blank row between blocks. Tool calls, and the folded thinking that leads into them, form
    // one run with none between. A tinted block carries its own padding.
    let next_is_tool = next.is_some_and(|n| matches!(n.entry, Entry::Tool(_)));
    let folded_thought = is_thought(Some(item)) && !thought_open;
    let joined = (matches!(item.entry, Entry::Tool(_)) || folded_thought)
        && (next_is_tool || (folded_thought && is_thought(next)));
    if !joined {
        v.push(Line::default());
    }
    v
}

/// What a session with nothing in it yet says: it is ready, and a way in.
fn welcome(theme: Theme) -> Vec<Line<'static>> {
    let try_it = |t: &'static str| {
        Line::from(vec![
            Span::raw("    "),
            Span::styled("› ", theme.accent()),
            Span::raw(t),
        ])
    };
    vec![
        Line::from(vec![
            Span::styled("• ", theme.dim()),
            Span::styled("Ready when you are.", theme.bold()),
        ]),
        Line::default(),
        Line::from(Span::styled("  Try", theme.dim())),
        try_it("explain how this repo is laid out"),
        try_it("find out why the last test failed, and fix it"),
        Line::default(),
    ]
}

fn home_short(path: &str) -> String {
    match std::env::var("HOME") {
        Ok(h) if !h.is_empty() && (path == h || path.starts_with(&format!("{h}/"))) => {
            format!("~{}", &path[h.len()..])
        }
        _ => path.to_string(),
    }
}

/// The panel that asks the person: what, the command whole, the choices, how to answer. With
/// the lines, the option each row draws (what a click on that row chooses).
fn panel_lines(
    request: &acp::PermissionRequest,
    total: usize,
    sel: usize,
    width: usize,
    max_subject: usize,
    theme: Theme,
) -> (Vec<Line<'static>>, Vec<Option<usize>>) {
    let inner = width.saturating_sub(GUTTER * 2);
    let tc = request.tool_call.as_ref();
    let title = tc.and_then(|t| t.title.as_deref()).unwrap_or("(no title)");
    let more = if total > 1 {
        format!("  ({} waiting)", total)
    } else {
        String::new()
    };
    let mut rows = vec![
        Line::default(),
        Line::from(vec![
            Span::raw("  "),
            Span::styled("▲ Needs you", theme.warn()),
            Span::styled(
                format!(" · {}{more}", fit(&clean(title), inner.saturating_sub(14))),
                theme.bold(),
            ),
        ]),
        Line::default(),
    ];
    if let Some(subject) = tc.and_then(|t| t.subject()) {
        let is_cmd = tc.and_then(|t| t.kind.as_deref()) == Some("execute");
        let lead: Vec<Span<'static>> = if is_cmd {
            vec![Span::raw("  "), Span::styled("$ ", theme.dim())]
        } else {
            vec![Span::raw("  ")]
        };
        let hang = if is_cmd { "    " } else { "  " };
        let body = if is_cmd {
            shell::highlight(&subject, theme)
        } else {
            vec![Span::raw(subject.clone())]
        };
        let mut lines = md::wrap_spans(body, lead, vec![Span::raw(hang)], inner + GUTTER);
        let cut = lines.len() > max_subject;
        lines.truncate(max_subject);
        rows.extend(lines);
        if cut {
            rows.push(Line::from(Span::styled("  …", theme.dim())));
        }
        rows.push(Line::default());
    }
    let mut options: Vec<Option<usize>> = Vec::new();
    for (i, o) in request.options.iter().enumerate() {
        let chosen = i == sel.min(request.options.len().saturating_sub(1));
        let (mark, style) = if chosen {
            ("› ", theme.accent().add_modifier(Modifier::BOLD))
        } else {
            ("  ", Style::default())
        };
        let mut body = vec![Span::styled(
            format!("{}. {}", i + 1, clean(&o.name)),
            style,
        )];
        if o.is_standing() {
            let word = if o.kind.as_deref().is_some_and(|k| k.starts_with("reject")) {
                "rejected"
            } else {
                "allowed"
            };
            body.push(Span::styled(format!("  · stays {word}"), theme.dim()));
        }
        // A long choice wraps under its own text, past the number.
        let lines = md::wrap_spans(
            body,
            vec![Span::raw("  "), Span::styled(mark, style)],
            vec![Span::raw("       ")],
            width.saturating_sub(GUTTER),
        );
        options.resize(rows.len(), None);
        options.extend(std::iter::repeat_n(Some(i), lines.len()));
        rows.extend(lines);
    }
    rows.push(Line::default());
    rows.push(Line::from(vec![
        Span::raw("  "),
        Span::styled(
            "↑↓ choose · Enter confirms · a number answers · Esc cancels",
            theme.dim(),
        ),
    ]));
    rows.push(Line::default());
    options.resize(rows.len(), None);
    (tint(rows, width, theme), options)
}

/// A panel that needs the person, set apart: a tinted band where the terminal's background is
/// known, else a bar down the left edge.
fn tint(rows: Vec<Line<'static>>, width: usize, theme: Theme) -> Vec<Line<'static>> {
    match theme.band() {
        Some(bg) => band(rows, width, bg),
        None => rows
            .into_iter()
            .map(|mut l| {
                if let Some(first) = l.spans.first_mut() {
                    // The bar takes the gutter's two columns; a hanging indent keeps the rest.
                    if first.content.len() >= 2 && first.content.chars().all(|c| c == ' ') {
                        let rest = first.content[2..].to_string();
                        *first = Span::styled("▎ ", theme.warn());
                        if !rest.is_empty() {
                            l.spans.insert(1, Span::raw(rest));
                        }
                    }
                }
                l
            })
            .collect(),
    }
}

pub fn draw(f: &mut Frame, ctx: &Frame_, v: &mut View) {
    let theme = ctx.theme;
    let area = f.area();
    let w = area.width as usize;
    let inner = w.saturating_sub(GUTTER);
    let text = ctx.composer.text.as_str();
    let ranges = wrap_ranges(text, inner);
    let (cur_row, cur_col) = cursor_cell(text, ctx.composer.cursor, inner, &ranges);
    // The cursor may be on a row after the last (a full row): make room for it.
    let comp_h = ranges.len().max(cur_row + 1).clamp(1, COMPOSER_MAX) as u16;
    let waiting = ctx.session.waiting();
    let mut option_rows = Vec::new();
    let panel = waiting
        .first()
        .map(|first| {
            let max_subject =
                ((area.height as usize / 2).saturating_sub(9)).clamp(2, SUBJECT_MAX_ROWS);
            let (lines, options) = match &first.ask {
                Ask::Permission(request) => {
                    v.sel = v.sel.min(request.options.len().saturating_sub(1));
                    panel_lines(request, waiting.len(), v.sel, w, max_subject, theme)
                }
                Ask::Question(form) => {
                    let max_rows = usize::from(area.height.saturating_sub(7));
                    let (rows, options) =
                        form.lines(waiting.len(), w, max_subject, max_rows, theme);
                    (tint(rows, w, theme), options)
                }
            };
            option_rows = options;
            lines
        })
        .or_else(|| v.picker.as_ref().map(|p| picker_lines(p, w, theme)))
        .or_else(|| v.help.then(|| help_lines(w, theme)))
        .or_else(|| {
            (!v.palette.is_empty()).then(|| palette_lines(&v.palette, v.palette_sel, w, theme))
        });
    let panel_h = panel
        .as_ref()
        .map_or(0, |p| p.len() as u16)
        .min(area.height.saturating_sub(7));
    // The input sits in its own zone: a tinted block where the terminal's background is known,
    // else a rule above it and below it. `HERDR_TUI_INPUT=rules` asks for the rules.
    let tinted = theme
        .band()
        .filter(|_| std::env::var("HERDR_TUI_INPUT").map_or(true, |v| v != "rules"));
    // A rule frames an input that is not tinted.
    let rule_h = u16::from(tinted.is_none());
    let zone_h = comp_h + if tinted.is_some() { 2 } else { 1 };
    let chips_h = u16::from(!v.chips.is_empty());
    // The messages waiting for the turn to end sit just above the input. They take priority over
    // the plan, and give way to the conversation, the panel and the input on a short screen.
    let (mut queue_rows, mut queue_ids) = queue_lines(ctx.queue, w, theme);
    let queue_room = usize::from(
        area.height
            .saturating_sub(panel_h + chips_h + rule_h + zone_h + 1 + 8),
    );
    queue_rows.truncate(queue_room);
    let queue_h = u16::try_from(queue_rows.len()).unwrap_or(u16::MAX);
    // The agent's plan, while it has steps left: a quiet checklist above the conversation's
    // edge. It gives way to everything else (the panel, the input) on a short screen.
    let mut plan_rows = plan_lines(ctx.transcript.plan(), w, theme);
    let kept = usize::from(panel_h + queue_h + chips_h + rule_h + zone_h + 1) + 8;
    let room = usize::from(area.height).saturating_sub(kept);
    if room < 3 {
        plan_rows.clear();
    } else {
        plan_rows.truncate(room);
    }
    let plan_h = u16::try_from(plan_rows.len()).unwrap_or(u16::MAX);
    let [hist, plan, perm, queue, chips, rule, zone, footer] = Layout::vertical([
        Constraint::Min(1),
        Constraint::Length(plan_h),
        Constraint::Length(panel_h),
        Constraint::Length(queue_h),
        Constraint::Length(chips_h),
        Constraint::Length(rule_h),
        Constraint::Length(zone_h),
        Constraint::Length(1),
    ])
    .areas(area);

    let welcome = if ctx.transcript.items().is_empty() && ctx.session.ready() {
        welcome(theme)
    } else {
        Vec::new()
    };
    draw_history(f, hist, ctx, v, welcome);
    if plan_h > 0 {
        f.render_widget(Paragraph::new(plan_rows), plan);
    }
    // Only the rows the panel had room for can be clicked.
    option_rows.truncate(usize::from(perm.height));
    v.option_rows = option_rows;
    v.option_top = perm.y;
    if let Some(rows) = panel {
        f.render_widget(Paragraph::new(rows), perm);
    }
    queue_ids.truncate(usize::from(queue.height));
    if queue_h > 0 {
        f.render_widget(Paragraph::new(queue_rows), queue);
    }
    v.queue_ids = queue_ids;
    v.queue_top = queue.y;
    // Said in the footer when the rows had no room, so a short pane never swallows a message.
    v.queue_hidden = if queue_h == 0 { ctx.queue.len() } else { 0 };
    if chips_h > 0 {
        f.render_widget(Paragraph::new(chips_line(&v.chips, w, theme)), chips);
    }

    if rule_h > 0 {
        f.render_widget(
            Paragraph::new(Line::from(Span::styled("─".repeat(w), theme.dim()))),
            rule,
        );
    }

    // What the input shows. When it is taller than the room, the rows around the cursor.
    let skip = (cur_row + 1)
        .saturating_sub(usize::from(comp_h))
        .min(ranges.len().saturating_sub(usize::from(comp_h)));
    let lines: Vec<Line<'static>> = if text.is_empty() {
        // While a question waits the box is its own: it says so rather than invite a message.
        let question = waiting.first().and_then(|w| w.question());
        let hint = match question {
            Some(q) if q.typed() => "Type your answer",
            Some(_) => "Answer the question above",
            None if ctx.session.ready()
                && (ctx.transcript.running() || ctx.session.prompting()) =>
            {
                "Queue a message for when this turn ends"
            }
            None if ctx.session.ready() => "Message the agent",
            None => "Opening the session…",
        };
        vec![Line::from(vec![
            Span::styled("› ", theme.accent()),
            Span::styled(hint, theme.dim()),
        ])]
    } else {
        ranges
            .iter()
            .skip(skip)
            .take(usize::from(comp_h))
            .enumerate()
            .map(|(i, (a, b))| {
                let lead = if skip == 0 && i == 0 {
                    Span::styled("› ", theme.accent())
                } else {
                    Span::raw("  ")
                };
                Line::from(vec![lead, Span::raw(text[*a..*b].to_string())])
            })
            .collect()
    };
    let top_pad = if let Some(bg) = tinted {
        let mut rows = vec![Line::default()];
        rows.extend(lines);
        rows.push(Line::default());
        f.render_widget(Paragraph::new(band(rows, w, bg)), zone);
        1
    } else {
        // The layout may have given less room than was asked for on a short screen: draw only
        // what fits, and only draw the rule below the input if there is a row for it.
        f.render_widget(
            Paragraph::new(lines),
            Rect {
                height: comp_h.min(zone.height),
                ..zone
            },
        );
        if zone.height > comp_h {
            let bottom = Rect {
                y: zone.y + comp_h,
                height: 1,
                ..zone
            };
            f.render_widget(
                Paragraph::new(Span::styled("─".repeat(w), theme.dim())),
                bottom,
            );
        }
        0
    };
    // The cursor goes on the row it is on, never outside the screen.
    let row_on_screen = u16::try_from(cur_row.saturating_sub(skip))
        .unwrap_or(u16::MAX)
        .min(comp_h.saturating_sub(1));
    let col_on_screen = u16::try_from(GUTTER + cur_col).unwrap_or(u16::MAX);
    f.set_cursor_position(Position::new(
        zone.x
            .saturating_add(col_on_screen)
            .min(area.right().saturating_sub(1)),
        zone.y
            .saturating_add(top_pad + row_on_screen)
            .min(area.bottom().saturating_sub(1)),
    ));

    // The footer is one calm row: what to do on the left, the model and the context on the right,
    // both in the same two-column gutter as everything above, with a margin at the right edge.
    // Scrolled back, the way to the newest is on the conversation's last row, not here.
    let left = footer_left(ctx, v);
    let inner = w.saturating_sub(GUTTER * 2);
    // Whatever the left side is, it keeps at least this much before the facts take the room.
    let keep = spans_width(&left).min(16);
    let facts = footer_facts(ctx, theme)
        .into_iter()
        .find(|f| spans_width(f) + GAP <= inner.saturating_sub(keep))
        .unwrap_or_default();
    let facts_w = spans_width(&facts);
    let left = fit_spans(
        left,
        inner.saturating_sub(facts_w + if facts.is_empty() { 0 } else { GAP }),
    );
    let pad = inner.saturating_sub(spans_width(&left) + facts_w);
    let mut row = vec![Span::raw(" ".repeat(GUTTER))];
    row.extend(left);
    row.push(Span::raw(" ".repeat(pad)));
    row.extend(facts);
    f.render_widget(Paragraph::new(Line::from(row)), footer);
    // Last, over everything drawn: the selection puts its band behind the cells it covers.
    if let Some(range) = v.select.as_ref().and_then(Selection::range) {
        select::paint(f.buffer_mut(), range, ctx.theme);
    }
}

/// Columns kept between the two sides of the footer.
const GAP: usize = 3;

fn spans_width(spans: &[Span]) -> usize {
    spans.iter().map(|s| width_of(&s.content)).sum()
}

/// The spans cut to `width` columns; the one that crosses the edge is shortened with an ellipsis.
fn fit_spans(spans: Vec<Span<'static>>, width: usize) -> Vec<Span<'static>> {
    let mut out = Vec::new();
    let mut used = 0;
    for span in spans {
        let w = width_of(&span.content);
        if used + w <= width {
            used += w;
            out.push(span);
            continue;
        }
        let room = width.saturating_sub(used);
        if room >= 2 {
            out.push(Span::styled(fit(&span.content, room), span.style));
        }
        break;
    }
    out
}

/// Steps of the agent's plan drawn at once.
const PLAN_ROWS: usize = 6;

/// The agent's plan as a checklist: `Plan · 2/5`, then the steps around the one in progress
/// (`✓` done, `●` doing, `○` to do). Nothing when the plan is empty or finished: the end-of-turn
/// line says what was done.
fn plan_lines(plan: &[acp::PlanEntry], width: usize, theme: Theme) -> Vec<Line<'static>> {
    use acp::PlanStatus::{Completed, InProgress};
    let done = plan.iter().filter(|e| e.status == Completed).count();
    if plan.is_empty() || done == plan.len() {
        return Vec::new();
    }
    let first_open = plan.iter().position(|e| e.status != Completed).unwrap_or(0);
    let start = first_open
        .saturating_sub(1)
        .min(plan.len().saturating_sub(PLAN_ROWS));
    let end = (start + PLAN_ROWS).min(plan.len());
    let mut rows = vec![Line::from(vec![
        Span::raw("  "),
        Span::styled("Plan", theme.bold()),
        Span::styled(format!(" · {done}/{}", plan.len()), theme.dim()),
    ])];
    for e in &plan[start..end] {
        let (mark, mark_style, text_style) = match e.status {
            Completed => ("✓", theme.dim(), theme.dim()),
            InProgress => ("●", theme.accent(), theme.bold()),
            acp::PlanStatus::Pending => ("○", theme.dim(), Style::default()),
        };
        rows.push(Line::from(vec![
            Span::raw("  "),
            Span::styled(mark, mark_style),
            Span::raw(" "),
            Span::styled(
                fit(&clean(&e.content), width.saturating_sub(GUTTER + 2)),
                text_style,
            ),
        ]));
    }
    if end < plan.len() {
        rows.push(Line::from(Span::styled(
            format!("    … {} more", plan.len() - end),
            theme.dim(),
        )));
    }
    rows
}

/// The files attached to the next message, on one row: `+ name` for each, and, when there is
/// room, how to take them off (the first thing a person asks).
fn chips_line(names: &[String], width: usize, theme: Theme) -> Line<'static> {
    const HOW: &str = "Backspace takes the last off · /files picks";
    let mut spans = vec![Span::raw(" ".repeat(GUTTER))];
    for (i, n) in names.iter().enumerate() {
        if i > 0 {
            spans.push(Span::raw("  "));
        }
        spans.push(Span::styled("+ ", theme.accent()));
        spans.push(Span::raw(clean(n)));
    }
    let used = spans_width(&spans);
    if used + 3 + width_of(HOW) + GUTTER <= width {
        spans.push(Span::raw(" ".repeat(width - used - width_of(HOW) - GUTTER)));
        spans.push(Span::styled(HOW, theme.dim()));
        return Line::from(spans);
    }
    Line::from(fit_spans(spans, width))
}

/// Queued messages drawn at once.
const QUEUE_ROWS: usize = 3;

/// How to take a queued message back, said at the right of the first one when there is room.
const QUEUE_HOW: &str = "Backspace takes the newest back · click a row for any";

/// The messages waiting for the turn to end, oldest first: `↳` and the first line of each, then
/// how many more wait. When some are held, a first row says why and how to go on. Nothing when
/// the queue is empty. With the rows, the message each draws (what a click on that row takes back).
fn queue_lines(
    q: &queue::Queue,
    width: usize,
    theme: Theme,
) -> (Vec<Line<'static>>, Vec<Option<u64>>) {
    let mut rows = Vec::new();
    let mut ids = Vec::new();
    if let Some(why) = q.held_reason() {
        rows.push(Line::from(Span::styled(
            format!("  Held · {} · Enter resumes", clean(why)),
            theme.warn(),
        )));
        ids.push(None);
    }
    for (i, e) in q.entries().iter().take(QUEUE_ROWS).enumerate() {
        let text = clean(&e.text);
        let mut lines = text.lines().map(str::trim).filter(|l| !l.is_empty());
        let first = lines.next().unwrap_or("").to_string();
        let more = lines.next().is_some();
        let suffix = match e.files.len() {
            0 => String::new(),
            1 => " · 1 file".to_string(),
            n => format!(" · {n} files"),
        };
        let room = width.saturating_sub(GUTTER + 2 + width_of(&suffix) + usize::from(more));
        let mark = if e.held.is_some() {
            theme.warn()
        } else {
            theme.dim()
        };
        let mut spans = vec![
            Span::raw("  "),
            Span::styled("↳ ", mark),
            Span::styled(fit(&first, room), theme.dim()),
        ];
        if more {
            spans.push(Span::styled("…", theme.dim()));
        }
        if !suffix.is_empty() {
            spans.push(Span::styled(suffix, theme.dim()));
        }
        // Like the files row: the way back is said where there is room, not where it would crowd.
        let used = spans_width(&spans);
        if i == 0 && used + 3 + width_of(QUEUE_HOW) + GUTTER <= width {
            spans.push(Span::raw(
                " ".repeat(width - used - width_of(QUEUE_HOW) - GUTTER),
            ));
            spans.push(Span::styled(QUEUE_HOW, theme.dim()));
        }
        rows.push(Line::from(spans));
        ids.push(Some(e.id));
    }
    if q.len() > QUEUE_ROWS {
        rows.push(Line::from(Span::styled(
            format!("    {} more queued", q.len() - QUEUE_ROWS),
            theme.dim(),
        )));
        ids.push(None);
    }
    (rows, ids)
}

/// What the left of the footer says, by what the person is doing. Only the keys needed to act now;
/// the rest are behind `?`.
fn footer_left(ctx: &Frame_, v: &View) -> Vec<Span<'static>> {
    let theme = ctx.theme;
    if let Phase::Ended(e) = ctx.session.phase() {
        return vec![Span::styled(
            format!("● ended: {}", md::one_line(e, 200)),
            theme.bad(),
        )];
    }
    if let Some(h) = ctx.hint {
        return vec![Span::styled(h.to_string(), theme.warn())];
    }
    // The panel that asks carries its own keys, next to the options: the footer says nothing.
    if !ctx.session.waiting().is_empty() {
        return Vec::new();
    }
    if let Some(u) = &v.update {
        return vec![
            Span::styled("↻ ", theme.accent()),
            Span::styled(format!("updating · {}", clean(u)), theme.dim()),
        ];
    }
    if let Some(p) = &v.picker {
        let keys = match p.kind {
            slash::PickerKind::Files => "↑↓ choose · Enter takes it off · Esc cancel",
            _ => "↑↓ choose · Enter set · Esc cancel",
        };
        return vec![Span::styled(keys, theme.dim())];
    }
    if !v.palette.is_empty() {
        return vec![Span::styled(
            "↑↓ choose · Tab complete · Enter run · Esc close",
            theme.dim(),
        )];
    }
    if v.focus.is_some() {
        return vec![
            Span::styled("Browsing", theme.accent().add_modifier(Modifier::BOLD)),
            Span::styled(
                " · ↑↓ move · → open · ← close · Esc back · ? keys",
                theme.dim(),
            ),
        ];
    }
    if ctx.transcript.running() || ctx.session.prompting() {
        let secs = ctx.working_secs.unwrap_or(0);
        let mut out = vec![
            Span::styled("● ", theme.accent()),
            Span::styled("Working", theme.bold()),
            Span::styled(format!(" {}", elapsed::duration(secs)), theme.dim()),
        ];
        if !ctx.composer.text.trim().is_empty() {
            out.push(Span::styled(" · Enter queues", theme.dim()));
        }
        if v.queue_hidden > 0 {
            out.push(Span::styled(
                format!(" · {} queued", v.queue_hidden),
                theme.dim(),
            ));
        }
        out.push(Span::styled(
            if ctx.queue.has_waiting() {
                " · Ctrl-C stops and sends queued"
            } else {
                " · Ctrl-C stops"
            },
            theme.dim(),
        ));
        return out;
    }
    // A held queue whose rows did not fit on a short screen: the way on is said here instead.
    if v.queue_hidden > 0 && ctx.queue.has_held() {
        return vec![Span::styled(
            format!("{} queued, held · Enter resumes", v.queue_hidden),
            theme.warn(),
        )];
    }
    // Idle, and a newer herdr-tui has been installed: say so, and how to load it. Not while a
    // turn runs or a request waits, when something else is the thing to look at.
    if let Some(v) = ctx.newer {
        return vec![
            Span::styled("↻ ", theme.accent()),
            Span::styled(
                format!("herdr-tui {} is installed · Ctrl-R loads it", clean(v)),
                theme.dim(),
            ),
        ];
    }
    vec![Span::styled(
        "Enter send · / commands · ? keys",
        theme.dim(),
    )]
}

/// The facts for the right of the footer, fullest first, each a shorter version of the one before:
/// the model leads, a mode only when it is not the default, the context gauge changes colour as
/// the window fills. With no model reported, where it runs stands in for it.
fn footer_facts(ctx: &Frame_, theme: Theme) -> Vec<Vec<Span<'static>>> {
    let tr = ctx.transcript;
    let model = tr.model().map(clean).filter(|m| !m.is_empty());
    let first = model
        .clone()
        .unwrap_or_else(|| ctx.header.agent.to_string());
    let thinking = tr.thinking().map(|t| format!("thinking {}", clean(t)));
    let mode = tr
        .mode()
        .filter(|m| !m.eq_ignore_ascii_case("default"))
        .map(clean);
    let gauge = tr.context().and_then(|c| {
        let style = match c {
            0..=59 => return None,
            60..=84 => theme.warn(),
            _ => theme.bad(),
        };
        Some((format!("ctx {c}%"), style))
    });
    let place = (model.is_none()).then(|| home_short(ctx.header.cwd));
    let build = |parts: Vec<Option<(String, Style)>>| -> Vec<Span<'static>> {
        let mut out: Vec<Span<'static>> = Vec::new();
        for (text, style) in parts.into_iter().flatten().filter(|(t, _)| !t.is_empty()) {
            if !out.is_empty() {
                out.push(Span::styled(" · ", theme.dim()));
            }
            out.push(Span::styled(text, style));
        }
        out
    };
    let lead = |bold: bool| {
        Some((
            first.clone(),
            if bold && model.is_some() {
                Style::default()
            } else {
                theme.dim()
            },
        ))
    };
    let mut options = vec![
        build(vec![
            lead(true),
            place.clone().map(|p| (p, theme.dim())),
            thinking.clone().map(|t| (t, theme.dim())),
            mode.clone().map(|m| (m, theme.dim())),
            gauge.clone(),
        ]),
        build(vec![
            lead(true),
            mode.map(|m| (m, theme.dim())),
            gauge.clone(),
        ]),
        build(vec![lead(true), gauge.clone()]),
        build(vec![gauge]),
    ];
    options.retain(|o| !o.is_empty());
    options.dedup_by(|a, b| spans_width(a) == spans_width(b));
    options
}

/// The key list, opened with `?`: what is not worth a place in the footer.
fn help_lines(width: usize, theme: Theme) -> Vec<Line<'static>> {
    const KEYS: [(&str, &str); 20] = [
        ("Enter", "send; queued while the agent works"),
        ("Backspace  click ↳", "take a queued message back to edit"),
        ("Ctrl-J", "new line"),
        ("/", "commands: model, plan, settings, info, new, skills"),
        ("Shift-Tab", "next mode (plan, ...)"),
        (
            "paste a path",
            "attach a file or picture; Backspace takes it off",
        ),
        ("Ctrl-V", "attach the screenshot on the clipboard"),
        ("↑ ↓  wheel", "scroll; with a request waiting, ↑ ↓ choose"),
        ("PgUp PgDn", "page"),
        ("Home  End", "oldest, newest"),
        ("click", "open or close a tool call or the thinking; choose"),
        ("Space  Shift-Tab", "on a question: tick a box, back a step"),
        ("drag", "select text and copy it"),
        ("Esc", "browse what the agent did"),
        ("Ctrl-P  Ctrl-N", "earlier messages"),
        ("Ctrl-T", "show the thinking"),
        ("Ctrl-C", "stop the turn"),
        ("Ctrl-L", "repaint the screen"),
        ("Ctrl-D", "leave; the session keeps running"),
        ("?", "close this"),
    ];
    let key_w = KEYS.iter().map(|(k, _)| width_of(k)).max().unwrap_or(0);
    let mut rows = vec![
        Line::default(),
        Line::from(vec![Span::raw("  "), Span::styled("Keys", theme.bold())]),
        Line::default(),
    ];
    for (key, what) in KEYS {
        let pad = " ".repeat(key_w - width_of(key) + 3);
        rows.push(Line::from(vec![
            Span::raw("  "),
            Span::styled(key, theme.accent()),
            Span::raw(pad),
            Span::raw(what),
        ]));
    }
    rows.push(Line::default());
    match theme.band() {
        Some(bg) => band(rows, width, bg),
        None => rows,
    }
}

/// The command list opened by typing `/`: a window of rows around the chosen one, each with the
/// name, what it takes and what it does, or why it cannot be used now.
fn palette_lines(
    entries: &[slash::Entry],
    sel: usize,
    width: usize,
    theme: Theme,
) -> Vec<Line<'static>> {
    let sel = sel.min(entries.len().saturating_sub(1));
    let start = if sel >= slash::MAX_ROWS {
        sel + 1 - slash::MAX_ROWS
    } else {
        0
    };
    let end = (start + slash::MAX_ROWS).min(entries.len());
    // What the agent called its commands goes through `clean` like all its text: a name or a
    // description can carry controls and joiners that would break the row.
    let one_line = |s: &str| clean(s).split_whitespace().collect::<Vec<_>>().join(" ");
    let names: Vec<String> = entries[start..end]
        .iter()
        .map(|e| one_line(&e.name))
        .collect();
    let name_w = names
        .iter()
        .map(|n| width_of(n) + 1)
        .max()
        .unwrap_or(0)
        .min((width / 3).clamp(18, 30));
    let room = width.saturating_sub(GUTTER + 2 + name_w + 3);
    let mut rows = vec![Line::default()];
    for (i, e) in entries[start..end].iter().enumerate() {
        let chosen = start + i == sel;
        let name_style = if e.reason.is_some() {
            theme.dim()
        } else if chosen {
            theme.accent().add_modifier(Modifier::BOLD)
        } else {
            Style::default()
        };
        let what = match &e.reason {
            Some(r) => one_line(r),
            None => [e.hint.as_deref().unwrap_or(""), e.description.as_str()]
                .into_iter()
                .map(one_line)
                .filter(|s| !s.is_empty())
                .collect::<Vec<_>>()
                .join("  "),
        };
        let name = fit(&format!("/{}", names[i]), name_w);
        let pad = " ".repeat((name_w + 3).saturating_sub(width_of(&name)));
        rows.push(Line::from(vec![
            Span::raw("  "),
            Span::styled(if chosen { "›" } else { " " }, theme.accent()),
            Span::raw(" "),
            Span::styled(name, name_style),
            Span::raw(pad),
            Span::styled(fit(&what, room), theme.dim()),
        ]));
    }
    if end < entries.len() {
        rows.push(Line::from(Span::styled(
            format!("    … {} more · keep typing", entries.len() - end),
            theme.dim(),
        )));
    }
    rows.push(Line::default());
    match theme.band() {
        Some(bg) => band(rows, width, bg),
        None => rows,
    }
}

/// Rows of the picker drawn at once.
const PICKER_ROWS: usize = 8;

/// The choices of one option (`/model`), the chosen one marked, the current one named.
fn picker_lines(p: &slash::Picker, width: usize, theme: Theme) -> Vec<Line<'static>> {
    let sel = p.sel.min(p.rows.len().saturating_sub(1));
    let start = if sel >= PICKER_ROWS {
        sel + 1 - PICKER_ROWS
    } else {
        0
    };
    let end = (start + PICKER_ROWS).min(p.rows.len());
    let room = width.saturating_sub(GUTTER + 2);
    let mut rows = vec![
        Line::default(),
        Line::from(vec![
            Span::raw("  "),
            Span::styled(clean(&p.title), theme.bold()),
        ]),
        Line::default(),
    ];
    for (i, (value, name)) in p.rows[start..end].iter().enumerate() {
        let chosen = start + i == sel;
        // Two choices may share a name (the same model from two providers): the value tells
        // them apart.
        let twin = p.rows.iter().filter(|(_, n)| n == name).count() > 1;
        let tag = format!(
            "{}{}",
            if twin {
                format!(" · {}", clean(value))
            } else {
                String::new()
            },
            if p.current.as_ref() == Some(value) {
                " · current"
            } else {
                ""
            }
        );
        let label = fit(&clean(name), room.saturating_sub(width_of(&tag)));
        rows.push(Line::from(vec![
            Span::raw("  "),
            Span::styled(if chosen { "›" } else { " " }, theme.accent()),
            Span::raw(" "),
            Span::styled(
                label,
                if chosen {
                    theme.accent().add_modifier(Modifier::BOLD)
                } else {
                    Style::default()
                },
            ),
            Span::styled(tag, theme.dim()),
        ]));
    }
    if end < p.rows.len() {
        rows.push(Line::from(Span::styled(
            format!("    … {} more", p.rows.len() - end),
            theme.dim(),
        )));
    }
    rows.push(Line::default());
    match theme.band() {
        Some(bg) => band(rows, width, bg),
        None => rows,
    }
}

/// The lines of one block, with the blank row that follows it.
fn block_lines(b: Block, items: &VecDeque<Item>, width: usize, look: Look) -> Vec<Line<'static>> {
    match b {
        Block::One(i) => item_lines(
            &items[i],
            i.checked_sub(1).and_then(|p| items.get(p)),
            items.get(i + 1),
            width,
            look,
        ),
        Block::Run { start, end, open } => {
            let mut l = run_lines(
                items,
                start,
                end,
                open,
                look.focused(fold::key(b, items)),
                width,
                look.theme,
            );
            // A closed run is always followed by something that is not a tool call.
            if !open {
                l.push(Line::default());
            }
            l
        }
    }
}

fn draw_history(
    f: &mut Frame,
    area: Rect,
    ctx: &Frame_,
    v: &mut View,
    welcome: Vec<Line<'static>>,
) {
    let (tr, theme) = (ctx.transcript, ctx.theme);
    v.page = (area.height as usize).saturating_sub(2).max(1);
    let mut need = (area.height as usize).saturating_add(v.scroll);
    let items = tr.items();
    let blocks = fold::blocks(items, &v.expanded);
    // The agent message still arriving: the newest item, while a turn runs. When it settles the
    // lines kept for it no longer show it as it is, so the cache starts over (once a turn).
    let live = (tr.running() || ctx.session.prompting())
        .then(|| items.back())
        .flatten()
        .filter(|i| {
            matches!(
                i.entry,
                Entry::Message {
                    role: Role::Agent,
                    ..
                }
            )
        })
        .map(|i| i.id);
    if live != v.live {
        v.live = live;
        v.line_cache.clear();
    }
    let look = Look {
        expanded: &v.expanded,
        focus: v.focus,
        thoughts: v.thoughts,
        theme,
        live,
    };
    let width = area.width as usize;
    if width != v.last_width {
        v.last_width = width;
        v.line_cache.clear();
    }
    let h = area.height as usize;
    let mut reached_start = true;
    // Pass 1, newest first: how many lines each block draws, and where, counted up from the
    // newest. A scroll walks this per block, so a long history costs a lookup each, not a
    // clone.
    let mut spans: Vec<(Block, usize, usize)> = Vec::new();
    let mut found: Option<(usize, usize)> = None;
    let anchor_key = v.anchor.map(|(k, _)| k);
    let mut anchored: Option<(usize, usize)> = None;
    // Scrolled back and not moved since the last frame: what was at the bottom edge stays there,
    // however much arrives below it.
    let hold = v
        .hold
        .filter(|h| v.scroll > 0 && h.at == v.scroll && v.anchor.is_none() && !v.focus_dirty);
    let mut held: Option<usize> = None;
    let total = if items.is_empty() {
        welcome.len()
    } else {
        let mut count = 0usize;
        for (bi, b) in blocks.iter().enumerate().rev() {
            let bkey = fold::key(*b, items);
            let n = v.line_cache.count_for(*b, items, width, look);
            if v.focus == Some(bkey) {
                found = Some((count, count + n));
            }
            if anchor_key == Some(bkey) {
                anchored = Some((count, count + n));
                // The window may move up to a screen above this block: build that far.
                need = need.max(count + n + h);
            }
            if let Some(hd) = hold.filter(|hd| hd.key == bkey) {
                // `off` counts from the block's first (oldest) line, so lines that stream in at
                // its end leave the held line where it is.
                let at = count + (n.saturating_sub(1) - hd.off.min(n.saturating_sub(1)));
                held = Some(at);
                need = need.max(at + h);
            }
            spans.push((*b, count, count + n));
            count += n;
            if count >= need
                && (!v.focus_dirty || found.is_some())
                && (anchor_key.is_none() || anchored.is_some())
                && (hold.is_none() || held.is_some())
            {
                reached_start = bi == 0;
                break;
            }
        }
        count
    };
    // The "not shown" line sits oldest, just past the last built line.
    let has_drop = reached_start && tr.dropped() > 0;
    let all = total + usize::from(has_drop);
    // Keep the focused block in view: bring it to the edge it is past, never further than it needs.
    if v.focus_dirty {
        if let Some((from, to)) = found {
            if to > v.scroll + h {
                v.scroll = to.saturating_sub(h);
            }
            if from < v.scroll {
                v.scroll = from;
            }
        }
        v.focus_dirty = false;
    }
    if let Some(at) = held {
        v.scroll = at;
    }
    // A block that was clicked keeps its first row where it was, unless what it opened would then
    // fall off the bottom: then it rises as far as its first row can stay on screen.
    if let Some((_, row)) = v.anchor {
        if let Some((from, to)) = anchored {
            let stay = (to + row).saturating_sub(h);
            v.scroll = stay.min(from).max(to.saturating_sub(h));
        }
        v.anchor = None;
    }
    // Do not scroll past the oldest line built.
    v.scroll = v.scroll.min(all.saturating_sub(h));
    // What the bottom edge shows now, for the next frame to keep in place.
    let scroll = v.scroll;
    v.hold = spans
        .iter()
        .filter(|_| scroll > 0)
        .find(|(_, from, to)| (*from..*to).contains(&scroll))
        .map(|&(b, _, to)| Hold {
            key: fold::key(b, items),
            off: to - 1 - scroll,
            at: scroll,
        });
    let end = (v.scroll + h).min(all);
    // Pass 2: the lines the window `v.scroll..end` shows, oldest first, and nothing else.
    // A block spans newest-first index `from..to`, so the part the window shows, oldest
    // first, is its own lines `to - hi .. to - lo`, where `lo..hi` is that overlap.
    let mut out_window: Vec<Line> = Vec::new();
    // What a click on each of those lines opens or closes.
    let mut keys: Vec<Option<u64>> = Vec::new();
    if items.is_empty() {
        // The welcome is the whole of the history: index it newest-first the way the blocks
        // are, then hand back the oldest-first slice the tail expects.
        let mut w = welcome;
        w.reverse();
        let mut window = w[v.scroll..end].to_vec();
        window.reverse();
        out_window.extend(window);
    } else {
        if has_drop && total < end {
            out_window.push(Line::from(Span::styled(
                format!("· {} earlier items are not shown", tr.dropped()),
                theme.dim(),
            )));
        }
        for &(b, from, to) in spans.iter().rev() {
            if to > v.scroll && from < end {
                let lo = from.max(v.scroll);
                let hi = to.min(end);
                let key = fold::foldable(b, items).then(|| fold::key(b, items));
                let lines = v.line_cache.ensure(b, items, width, look);
                let last = lines.len().saturating_sub(1);
                keys.resize(out_window.len(), None);
                for (j, l) in lines.iter().enumerate().take(to - lo).skip(to - hi) {
                    // The blank row after a block belongs to no block.
                    let blank = j == last && l.spans.iter().all(|s| s.content.trim().is_empty());
                    keys.push(if blank { None } else { key });
                    out_window.push(l.clone());
                }
            }
        }
    }
    // Bottom-align: short history sits just above the input.
    let pad = h - out_window.len().min(h);
    keys.resize(out_window.len(), None);
    let mut rows = vec![None; pad];
    rows.extend(keys);
    let mut out = vec![Line::default(); pad];
    out.extend(out_window);
    // Scrolled back: the last row says how much is below and is the way back (click or End).
    v.newest_row = None;
    if v.scroll > 0 && h > 1 {
        if let (Some(last), Some(slot)) = (out.last_mut(), rows.last_mut()) {
            let label = format!(" ↓ {} below · End ", lines_word(v.scroll));
            let style = theme.band().map_or_else(
                || theme.accent().add_modifier(Modifier::REVERSED),
                |bg| theme.accent().patch(bg),
            );
            let lead = width.saturating_sub(width_of(&label)) / 2;
            *last = Line::from(vec![
                Span::raw(" ".repeat(lead)),
                Span::styled(label, style),
            ]);
            *slot = None;
            v.newest_row = Some(area.y + area.height - 1);
        }
    }
    v.fold_rows = rows;
    v.fold_top = area.y;
    f.render_widget(Paragraph::new(out), area);
}

/// `n lines`, or `1 line`.
fn lines_word(n: usize) -> String {
    if n == 1 {
        "1 line".to_string()
    } else {
        format!("{n} lines")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::queue::Queue;
    use crate::session::Start;
    use acp::{is_unsafe_control, SessionUpdate};
    use ratatui::{backend::TestBackend, buffer::Buffer, style::Color, Terminal};
    use serde_json::json;

    fn draw_with(
        tr: &Transcript,
        session: &Session,
        composer: &Composer,
        theme: Theme,
        w: u16,
        h: u16,
        view: &mut View,
    ) -> Buffer {
        let mut term = Terminal::new(TestBackend::new(w, h)).expect("a test terminal");
        let ctx = Frame_ {
            transcript: tr,
            session,
            composer,
            header: Header {
                agent: "omp",
                cwd: "/w",
            },
            theme,
            hint: None,
            working_secs: None,
            queue: &Queue::default(),
            newer: None,
        };
        term.draw(|f| draw(f, &ctx, view)).expect("drawn");
        term.backend().buffer().clone()
    }

    fn rows_of(buf: &Buffer) -> Vec<String> {
        let a = buf.area;
        (0..a.height)
            .map(|y| {
                (0..a.width)
                    .map(|x| buf[(x, y)].symbol().to_string())
                    .collect::<String>()
                    .trim_end()
                    .to_string()
            })
            .collect()
    }

    /// The screen as rows of text.
    fn render(tr: &Transcript, w: u16, h: u16, scroll: usize) -> Vec<String> {
        let (session, _) = Session::begin(Start::Attach, None);
        let mut view = View {
            scroll,
            ..View::default()
        };
        rows_of(&draw_with(
            tr,
            &session,
            &Composer::default(),
            Theme::plain(),
            w,
            h,
            &mut view,
        ))
    }

    fn ready_session() -> Session {
        let (mut session, _) = Session::begin(Start::Attach, None);
        let mut scratch = Transcript::default();
        session.handle(
            crate::session::Event::Message(acp::Message::result(acp::Id::Num(1), json!({}))),
            0,
            &mut scratch,
        );
        session.handle(
            crate::session::Event::Record(Some(crate::session::Record {
                session_id: Some("s".into()),
                cwd: "/w".into(),
                exited: None,
            })),
            0,
            &mut scratch,
        );
        session.handle(
            crate::session::Event::Message(acp::Message::result(acp::Id::Num(2), json!({}))),
            0,
            &mut scratch,
        );
        assert!(session.ready());
        session
    }

    fn agent(tr: &mut Transcript, id: &str, text: &str) {
        tr.apply(SessionUpdate::from_value(&json!({"sessionUpdate": "agent_message_chunk", "messageId": id, "content": {"type": "text", "text": text}})).expect("update"));
    }

    /// A conversation long enough to overflow the line cache, so a scroll sweep forces eviction.
    fn big_transcript() -> Transcript {
        let mut tr = Transcript::default();
        for t in 0..600 {
            tr.user(format!("turn {t}"));
            let id = format!("m{t}");
            agent(
                &mut tr,
                &id,
                "a line of `code` and **bold**\n\n- one\n- two\n",
            );
            tr.apply(
                SessionUpdate::from_value(
                    &json!({"sessionUpdate": "tool_call", "toolCallId": format!("r{t}"), "title": "Read lib/sync.dart", "kind": "read", "status": "completed"}),
                )
                .expect("update"),
            );
        }
        tr
    }

    #[test]
    fn the_line_cache_never_changes_what_is_drawn() {
        // The whole point of the cache: a scroll, and a scroll that evicts, must show exactly
        // what a fresh build would. A warm view is swept across the conversation and compared,
        // line for line, to a cold view at every offset.
        let tr = big_transcript();
        let session = ready_session();
        let (w, h) = (100u16, 30u16);
        let mut warm = View::default();
        for scroll in (0..6000).step_by(37) {
            warm.scroll = scroll;
            let a = rows_of(&draw_with(
                &tr,
                &session,
                &Composer::default(),
                Theme::plain(),
                w,
                h,
                &mut warm,
            ));
            let mut cold = View {
                scroll,
                ..View::default()
            };
            let b = rows_of(&draw_with(
                &tr,
                &session,
                &Composer::default(),
                Theme::plain(),
                w,
                h,
                &mut cold,
            ));
            assert_eq!(a, b, "the cache changed what is drawn at scroll={scroll}");
        }
        // The sweep was long enough to have filled and evicted the cache.
        assert!(
            warm.cache_chars() <= 256 * 1024,
            "the cache outgrew its budget"
        );
        assert!(warm.cache_chars() > 0, "the cache never held a line");
    }

    /// What a terminal shows after it is sent ratatui's updates, one by one: a wide glyph covers
    /// the cell to its right, writing over either half of one blanks the other half, and nothing
    /// else is touched. `""` is a covered cell.
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

        fn put(&mut self, x: u16, y: u16, sym: &str) {
            let i = usize::from(y) * self.w + usize::from(x);
            if self.cells[i].is_empty() && x > 0 {
                self.cells[i - 1] = " ".to_string();
            }
            for k in 1..width::of(&self.cells[i]) {
                if i + k < self.cells.len() {
                    self.cells[i + k] = " ".to_string();
                }
            }
            self.cells[i] = sym.to_string();
            for k in 1..width::of(sym) {
                if usize::from(x) + k < self.w {
                    self.cells[i + k] = String::new();
                }
            }
        }

        /// A buffer as the screen would show it drawn from scratch.
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

    #[test]
    fn scrolling_past_tables_of_wide_symbols_leaves_no_stale_cell_behind() {
        // Frames are sent as ratatui sends them, only what changed since the last one, and the
        // screen that results must be the one a cold draw of that moment shows. A glyph the
        // layout thought narrower than the terminal drew it, or a cell never rewritten when a
        // wide glyph went away, is a character left behind.
        let table = "| Task | Done | Mark |\n|:--|:-:|:-:|\n| Board | ✅ | ● |\n| pi turn | ⚠️ | ◐ |\n| Codex | ❌ | ○ |\n| Heart | ❤️ | ✔️ |\n| Vote | 👍🏽 | 👨‍👩‍👧 |";
        let doc: String = (1..=6)
            .map(|i| format!("{i}. Task-list and status symbols\n\n{table}\n\n"))
            .collect();
        let mut tr = Transcript::default();
        agent(&mut tr, "m", &doc);
        let session = ready_session();
        let composer = Composer::default();
        let (w, h) = (60u16, 16u16);
        let mut warm = View::default();
        let mut shown = Screen::new(w, h);
        let mut prev = Buffer::empty(ratatui::layout::Rect::new(0, 0, w, h));
        for scroll in [0usize, 5, 11, 3, 20, 8, 1, 17, 0, 9, 14, 26, 2] {
            warm.scroll = scroll;
            let next = draw_with(&tr, &session, &composer, Theme::plain(), w, h, &mut warm);
            for (x, y, cell) in prev.diff(&next) {
                shown.put(x, y, cell.symbol());
            }
            prev = next;
            let mut cold = View {
                scroll,
                ..View::default()
            };
            let fresh = draw_with(&tr, &session, &composer, Theme::plain(), w, h, &mut cold);
            let want = Screen::of(&fresh);
            let diff: Vec<(usize, usize, &str, &str)> = shown
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
            assert!(
                diff.is_empty(),
                "left behind at scroll={scroll}: (x, y, shown, cold) {diff:?}"
            );
        }
    }

    #[test]
    fn a_streaming_message_is_not_frozen_at_its_first_chunk() {
        // The cache must not serve a block's old line after its text grows in place: a message
        // that streams shows its whole text, not the first chunk it was first built with.
        let mut tr = Transcript::default();
        agent(&mut tr, "m", "Hello");
        let session = ready_session();
        let (w, h) = (100u16, 30u16);
        let mut view = View::default();
        let first = rows_of(&draw_with(
            &tr,
            &session,
            &Composer::default(),
            Theme::plain(),
            w,
            h,
            &mut view,
        ));
        assert!(first.iter().any(|r| r.contains("Hello")));
        // The same message, same id, keeps streaming: the revision moves, the line must too.
        agent(&mut tr, "m", " there, I am the agent");
        let second = rows_of(&draw_with(
            &tr,
            &session,
            &Composer::default(),
            Theme::plain(),
            w,
            h,
            &mut view,
        ));
        assert!(
            second.iter().any(|r| r.contains("I am the agent")),
            "the cache served the message's first chunk: {second:?}"
        );
    }

    #[test]
    fn wrap_never_exceeds_the_width_even_for_wide_chars_and_long_words() {
        for l in wrap("日本語のテキスト and a_very_long_unbroken_word_here ok", 10) {
            assert!(width_of(&l) <= 10, "{l:?}");
        }
    }

    #[test]
    fn wrap_keeps_blank_lines() {
        assert_eq!(wrap("a\n\nb", 5), vec!["a", "", "b"]);
    }

    #[test]
    fn an_agent_cannot_move_the_cursor_or_clear_the_screen() {
        for l in wrap("safe\u{1b}[2Jtext\u{7}\r!", 80) {
            assert!(!l.chars().any(is_unsafe_control), "{l:?}");
        }
    }

    #[test]
    fn fit_cuts_by_display_width_and_marks_the_cut() {
        assert_eq!(fit("short", 10), "short");
        assert_eq!(width_of(&fit("日本語日本語日本語", 7)), 7);
        assert!(fit("日本語日本語日本語", 7).ends_with('…'));
    }

    #[test]
    fn what_the_person_said_is_a_full_width_tinted_block_with_padding_rows() {
        let theme = Theme::banded((255, 255, 255));
        let rows = user_lines("fix the test", 40, theme);
        assert_eq!(rows.len(), 3, "a padding row above and below");
        for row in &rows {
            let w: usize = row.spans.iter().map(|s| width_of(&s.content)).sum();
            assert_eq!(w, 40, "the band is solid to the edge");
            assert!(row.spans.iter().all(|s| s.style.bg.is_some()));
        }
        assert!(rows[1]
            .spans
            .iter()
            .any(|s| s.content.contains("fix the test")));
        assert!(matches!(
            rows[0].spans[0].style.bg,
            Some(Color::Rgb(242, 242, 242))
        ));
    }

    #[test]
    fn the_tint_reaches_every_cell_of_the_band_on_screen_text_included() {
        let mut tr = Transcript::default();
        tr.user("fix the test");
        let session = ready_session();
        let mut view = View {
            scroll: 0,
            sel: 0,
            ..View::default()
        };
        let buf = draw_with(
            &tr,
            &session,
            &Composer::default(),
            Theme::banded((255, 255, 255)),
            40,
            12,
            &mut view,
        );
        let rows = rows_of(&buf);
        let row = rows
            .iter()
            .position(|r| r.contains("fix the test"))
            .expect("shown") as u16;
        for x in 0..40u16 {
            assert_eq!(
                buf[(x, row)].bg,
                Color::Rgb(242, 242, 242),
                "column {x} of the text row"
            );
        }
        assert_eq!(
            buf[(5, row - 1)].bg,
            Color::Rgb(242, 242, 242),
            "the padding row above"
        );
        assert_ne!(
            buf[(5, row - 3)].bg,
            Color::Rgb(242, 242, 242),
            "nothing beyond the band"
        );
    }

    #[test]
    fn without_a_known_background_the_person_gets_a_bar_instead_of_a_tint() {
        let rows = user_lines("hi", 40, Theme::plain());
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].spans[0].content, "▎ ");
    }

    #[test]
    fn the_agents_words_hang_from_a_bullet_in_the_gutter() {
        let rows = agent_lines(
            "one two three four five six seven",
            14,
            Theme::plain(),
            false,
        );
        let text: Vec<String> = rows
            .iter()
            .map(|l| l.spans.iter().map(|s| s.content.as_ref()).collect())
            .collect();
        assert!(text[0].starts_with("• "), "{text:?}");
        assert!(text[1..].iter().all(|r| r.starts_with("  ")), "{text:?}");
        assert!(text.iter().all(|r| width_of(r) <= 14));
    }

    #[test]
    fn reading_inside_the_message_that_is_still_arriving_does_not_slide_as_it_grows() {
        let mut tr = Transcript::default();
        let paras = |n: usize| {
            (1..=n)
                .map(|i| format!("para {i}"))
                .collect::<Vec<_>>()
                .join("\n\n")
        };
        agent(&mut tr, "m", &paras(30));
        let session = ready_session();
        let mut view = View {
            scroll: 20,
            ..View::default()
        };
        let draw = |tr: &Transcript, view: &mut View| {
            rows_of(&draw_with(
                tr,
                &session,
                &Composer::default(),
                Theme::plain(),
                40,
                12,
                view,
            ))
        };
        let reading = |rows: &[String]| -> Vec<String> {
            rows.iter()
                .filter(|r| r.contains("para "))
                .cloned()
                .collect()
        };
        let before = draw(&tr, &mut view);
        // The same message grows at its end, as an agent's chunks do.
        tr.apply(
            SessionUpdate::from_value(&json!({"sessionUpdate": "agent_message_chunk", "messageId": "m", "content": {"type": "text", "text": "\n\npara 31\n\npara 32\n\npara 33\n\npara 34"}}))
                .expect("update"),
        );
        let after = draw(&tr, &mut view);
        assert!(!reading(&before).is_empty(), "{before:#?}");
        assert_eq!(reading(&before), reading(&after), "{after:#?}");
    }

    #[test]
    fn scrolled_back_what_you_read_stays_put_as_output_arrives_and_a_click_goes_back_down() {
        let mut tr = Transcript::default();
        let many = |tag: &str| {
            (1..=30)
                .map(|i| format!("{tag} {i}"))
                .collect::<Vec<_>>()
                .join("\n\n")
        };
        agent(&mut tr, "a", &many("old"));
        let session = ready_session();
        let mut view = View {
            scroll: 20,
            ..View::default()
        };
        let draw = |tr: &Transcript, view: &mut View| {
            rows_of(&draw_with(
                tr,
                &session,
                &Composer::default(),
                Theme::plain(),
                40,
                16,
                view,
            ))
        };
        let before = draw(&tr, &mut view);
        agent(&mut tr, "b", &many("new"));
        let after = draw(&tr, &mut view);
        let reading = |rows: &[String]| -> Vec<String> {
            rows.iter()
                .filter(|r| r.contains("old "))
                .cloned()
                .collect()
        };
        assert!(!reading(&before).is_empty(), "{before:#?}");
        assert_eq!(
            reading(&before),
            reading(&after),
            "the same lines, in the same rows: {after:#?}"
        );
        let control = after
            .iter()
            .position(|r| r.contains("below · End"))
            .expect("the way back is shown");
        assert!(view.click_newest(u16::try_from(control).expect("on screen")));
        let bottom = draw(&tr, &mut view).join("\n");
        assert!(bottom.contains("new 30"), "{bottom}");
        assert!(!bottom.contains("below · End"), "{bottom}");
    }

    #[test]
    fn the_newest_lines_are_visible_even_when_the_last_message_is_taller_than_the_screen() {
        let mut tr = Transcript::default();
        agent(
            &mut tr,
            "m",
            &(1..=40)
                .map(|i| format!("line {i}"))
                .collect::<Vec<_>>()
                .join("\n\n"),
        );
        let rows = render(&tr, 40, 14, 0);
        assert!(rows.iter().any(|r| r.trim() == "line 40"), "{rows:#?}");
        assert!(!rows.iter().any(|r| r.trim() == "line 1"));
    }

    #[test]
    fn an_enormous_scroll_means_the_very_start_not_an_overflow() {
        let mut tr = Transcript::default();
        agent(
            &mut tr,
            "m",
            &(1..=40)
                .map(|i| format!("line {i}"))
                .collect::<Vec<_>>()
                .join("\n\n"),
        );
        let top = render(&tr, 40, 14, usize::MAX);
        assert!(top.iter().any(|r| r == "• line 1"), "{top:#?}");
    }

    #[test]
    fn scrolling_up_moves_toward_older_lines_and_stops_at_the_oldest() {
        let mut tr = Transcript::default();
        agent(
            &mut tr,
            "m",
            &(1..=40)
                .map(|i| format!("line {i}"))
                .collect::<Vec<_>>()
                .join("\n\n"),
        );
        let up = render(&tr, 40, 14, 6);
        assert!(
            !up.iter().any(|r| r.trim() == "line 40") && up.iter().any(|r| r.trim() == "line 37"),
            "{up:#?}"
        );
    }

    #[test]
    fn several_thoughts_in_a_row_say_thinking_once_and_lead_straight_into_the_tools() {
        let mut tr = Transcript::default();
        for (i, id) in ["a", "b", "c"].iter().enumerate() {
            tr.apply(SessionUpdate::from_value(&json!({"sessionUpdate": "agent_thought_chunk", "messageId": id, "content": {"type": "text", "text": format!("t{i}")}})).expect("update"));
        }
        tr.apply(SessionUpdate::from_value(&json!({"sessionUpdate": "tool_call", "toolCallId": "x", "title": "Listing docs", "status": "completed"})).expect("update"));
        let rows = render(&tr, 40, 14, 0);
        assert_eq!(
            rows.iter().filter(|r| r.contains("thinking")).count(),
            1,
            "{rows:#?}"
        );
        let at = rows
            .iter()
            .position(|r| r.contains("thinking"))
            .expect("shown");
        assert!(
            rows[at + 1].contains("Listing docs"),
            "no blank row between: {rows:#?}"
        );
    }

    #[test]
    fn a_failed_call_shows_its_last_lines_that_say_something() {
        let t = Tool {
            id: "1".into(),
            title: "Run make".into(),
            kind: None,
            status: ToolStatus::Failed,
            subject: None,
            output: crate::transcript::Output {
                head: ["a", "", "b", "", "c", "d", "", "e"]
                    .iter()
                    .map(|s| (*s).to_string())
                    .collect(),
                tail: vec![],
                omitted: 0,
            },
            diffs: vec![],
        };
        let rows: Vec<String> = tool_lines(&t, 40, false, false, Theme::plain())
            .iter()
            .skip(1)
            .map(|l| {
                l.spans
                    .iter()
                    .map(|s| s.content.as_ref())
                    .collect::<String>()
                    .trim()
                    .to_string()
            })
            .collect();
        assert_eq!(rows, ["d", "e"], "one reason, not a stack");
    }

    #[test]
    fn a_finished_call_is_quiet_plain_and_uncoloured() {
        let t = Tool {
            id: "1".into(),
            title: "$ git status --short".into(),
            kind: Some("execute".into()),
            status: ToolStatus::Completed,
            subject: None,
            output: crate::transcript::Output::default(),
            diffs: vec![],
        };
        let theme = Theme::banded((255, 255, 255));
        let rows = tool_lines(&t, 60, false, false, theme);
        let text: String = rows[0].spans.iter().map(|s| s.content.as_ref()).collect();
        assert_eq!(text, "  git status --short");
        for span in rows[0].spans.iter().skip(1) {
            assert_eq!(
                span.style.fg,
                theme.dim().fg,
                "{span:?}: no command colours once it is done"
            );
        }
    }

    #[test]
    fn a_failed_call_with_no_output_gives_its_subject_as_the_reason() {
        let t = Tool {
            id: "1".into(),
            title: "Reading workspace manifest".into(),
            kind: None,
            status: ToolStatus::Failed,
            subject: Some("rust/Cargo.toml".into()),
            output: crate::transcript::Output::default(),
            diffs: vec![],
        };
        let rows: Vec<String> = tool_lines(&t, 60, false, false, Theme::plain())
            .iter()
            .map(|l| {
                l.spans
                    .iter()
                    .map(|s| s.content.as_ref())
                    .collect::<String>()
            })
            .collect();
        assert_eq!(
            rows,
            ["✗ Reading workspace manifest", "    rust/Cargo.toml"]
        );
    }

    #[test]
    fn empty_messages_leave_no_blank_rows_behind() {
        let mut tr = Transcript::default();
        tr.user("go");
        for i in 0..4 {
            agent(&mut tr, &format!("e{i}"), "");
        }
        agent(&mut tr, "real", "answer");
        let rows = render(&tr, 40, 14, 0);
        let at = rows
            .iter()
            .position(|r| r.contains("• answer"))
            .expect("shown");
        let user_at = rows.iter().position(|r| r.contains("go")).expect("shown");
        assert!(
            at - user_at <= 3,
            "one band row below the message, one blank, then the answer: {rows:#?}"
        );
    }

    fn finished_tools(tr: &mut Transcript, ids: &[(&str, &str, &str)]) {
        for (id, title, status) in ids {
            tr.apply(SessionUpdate::from_value(&json!({"sessionUpdate": "tool_call", "toolCallId": id, "title": title, "status": status})).expect("update"));
        }
    }

    #[test]
    fn a_finished_run_of_tool_calls_is_one_line_and_a_failure_stays_in_view() {
        let mut tr = Transcript::default();
        finished_tools(
            &mut tr,
            &[
                ("a", "Reading one", "completed"),
                ("b", "Reading two", "completed"),
                ("c", "Listing docs", "completed"),
                ("d", "Reading gone", "failed"),
            ],
        );
        agent(&mut tr, "m", "done");
        let rows = render(&tr, 70, 16, 0);
        let text = rows.join("\n");
        assert!(
            text.contains("▸ 4 tool calls · 1 failed · Reading ×3 · Listing"),
            "{text}"
        );
        assert!(
            text.contains("✗ Reading gone"),
            "the failure is not folded away: {text}"
        );
        assert!(!text.contains("Reading one"), "the quiet ones are: {text}");
    }

    #[test]
    fn opening_a_run_shows_its_calls_and_the_rows_are_one_line_each() {
        let mut tr = Transcript::default();
        finished_tools(
            &mut tr,
            &[
                ("a", "Reading one", "completed"),
                ("b", "Reading two", "completed"),
                ("c", "Listing docs", "completed"),
            ],
        );
        agent(&mut tr, "m", "done");
        let mut view = View::default();
        view.expanded.insert(tr.items()[0].id | (1 << 63));
        let session = ready_session();
        let rows = rows_of(&draw_with(
            &tr,
            &session,
            &Composer::default(),
            Theme::plain(),
            70,
            16,
            &mut view,
        ));
        let at = rows
            .iter()
            .position(|r| r.contains("▾ 3 tool calls"))
            .expect("open");
        assert!(
            rows[at + 1].contains("Reading one")
                && rows[at + 2].contains("Reading two")
                && rows[at + 3].contains("Listing docs"),
            "{rows:#?}"
        );
    }

    #[test]
    fn a_click_opens_and_closes_the_run_under_it_and_its_first_row_stays_put() {
        let mut tr = Transcript::default();
        for i in 0..6 {
            agent(&mut tr, &format!("f{i}"), &format!("earlier answer {i}"));
        }
        finished_tools(
            &mut tr,
            &[
                ("a", "Reading one", "completed"),
                ("b", "Reading two", "completed"),
                ("c", "Listing docs", "completed"),
            ],
        );
        agent(
            &mut tr,
            "m",
            "line one\n\nline two\n\nline three\n\nline four",
        );
        let session = ready_session();
        let mut view = View::default();
        let draw = |view: &mut View| {
            rows_of(&draw_with(
                &tr,
                &session,
                &Composer::default(),
                Theme::plain(),
                70,
                20,
                view,
            ))
        };
        let rows = draw(&mut view);
        let at = rows
            .iter()
            .position(|r| r.contains("▸ 3 tool calls"))
            .expect("folded");
        let y = u16::try_from(at).expect("on screen");
        let answer = rows
            .iter()
            .position(|r| r.contains("line one"))
            .expect("shown");
        assert!(
            !view.click_fold(u16::try_from(answer).expect("on screen")),
            "an answer does not fold"
        );

        assert!(view.click_fold(y));
        let rows = draw(&mut view);
        assert!(
            rows[at].contains("▾ 3 tool calls"),
            "it stayed where it was clicked: {rows:#?}"
        );
        assert!(rows[at + 1].contains("Reading one"), "{rows:#?}");

        assert!(view.click_fold(y));
        let rows = draw(&mut view);
        assert!(rows[at].contains("▸ 3 tool calls"), "{rows:#?}");
        assert!(!rows.join("\n").contains("Reading one"), "{rows:#?}");
    }

    #[test]
    fn browse_mode_marks_the_focus_and_scrolls_it_into_view() {
        let mut tr = Transcript::default();
        tr.apply(SessionUpdate::from_value(&json!({"sessionUpdate": "agent_thought_chunk", "messageId": "t", "content": {"type": "text", "text": "pondering deeply"}})).expect("update"));
        agent(
            &mut tr,
            "m",
            &(1..=40)
                .map(|i| format!("line {i}"))
                .collect::<Vec<_>>()
                .join("\n\n"),
        );
        let session = ready_session();
        // Focus the thought, far above the newest lines.
        let mut view = View {
            focus: Some(tr.items()[0].id),
            focus_dirty: true,
            ..View::default()
        };
        let rows = rows_of(&draw_with(
            &tr,
            &session,
            &Composer::default(),
            Theme::plain(),
            40,
            14,
            &mut view,
        ));
        assert!(
            rows.iter().any(|r| r.contains("… thinking")),
            "the focused block was brought into view: {rows:#?}"
        );
        assert!(
            rows.last()
                .is_some_and(|r| r.is_empty() || r.contains("omp"))
                && rows.iter().any(|r| r.contains("Browsing")),
            "{rows:#?}"
        );
        assert!(
            !view.focus_dirty,
            "it scrolls to the focus once, not on every frame"
        );
    }

    #[test]
    fn a_thought_opens_to_its_words_and_closes_to_one_line() {
        let mut tr = Transcript::default();
        tr.apply(SessionUpdate::from_value(&json!({"sessionUpdate": "agent_thought_chunk", "messageId": "t", "content": {"type": "text", "text": "I should check the manifest first"}})).expect("update"));
        let session = ready_session();
        let closed = rows_of(&draw_with(
            &tr,
            &session,
            &Composer::default(),
            Theme::plain(),
            50,
            12,
            &mut View::default(),
        ))
        .join("\n");
        assert!(
            closed.contains("… thinking") && !closed.contains("manifest"),
            "{closed}"
        );
        let mut view = View::default();
        view.expanded.insert(tr.items()[0].id);
        let open = rows_of(&draw_with(
            &tr,
            &session,
            &Composer::default(),
            Theme::plain(),
            50,
            12,
            &mut view,
        ))
        .join("\n");
        assert!(open.contains("I should check the manifest first"), "{open}");
    }

    #[test]
    fn a_drag_over_the_conversation_swaps_the_colours_it_covers_and_copies_what_it_shows() {
        let mut tr = Transcript::default();
        agent(&mut tr, "m", "first line\n\nsecond line");
        let session = ready_session();
        let mut view = View::default();
        let screen = |view: &mut View| {
            draw_with(
                &tr,
                &session,
                &Composer::default(),
                Theme::plain(),
                40,
                12,
                view,
            )
        };
        let plain = screen(&mut view);
        let rows = rows_of(&plain);
        let top = u16::try_from(
            rows.iter()
                .position(|r| r.contains("first line"))
                .expect("shown"),
        )
        .expect("a small screen");
        let row = &rows[usize::from(top)];
        // Columns, not bytes: the row starts with a bullet.
        let col = u16::try_from(row[..row.find("first").expect("there")].chars().count())
            .expect("narrow");

        // From "first" to the "d" of "second", two rows down.
        let mut s = Selection::begin((col, top));
        s.drag((col + 5, top + 2));
        view.select = Some(s);
        let marked = screen(&mut view);
        let reversed = |buf: &Buffer, x: u16, y: u16| {
            buf[(x, y)]
                .modifier
                .contains(ratatui::style::Modifier::REVERSED)
        };
        assert!(reversed(&marked, col, top), "the first cell is covered");
        assert!(reversed(&marked, col + 4, top + 2), "and the last");
        assert!(
            !reversed(&marked, col + 7, top + 2),
            "nothing past the end of the drag"
        );
        assert!(
            !reversed(&plain, col, top),
            "the screen without a selection is untouched"
        );
        assert_eq!(
            select::text(&marked, s.range().expect("dragged")),
            "first line\n\nsecond",
            "the copy is the text on screen, not the colours"
        );
    }

    #[test]
    fn a_click_on_the_folded_thinking_opens_it() {
        let mut tr = Transcript::default();
        tr.apply(SessionUpdate::from_value(&json!({"sessionUpdate": "agent_thought_chunk", "messageId": "t", "content": {"type": "text", "text": "I should check the manifest first"}})).expect("update"));
        agent(&mut tr, "m", "done");
        let session = ready_session();
        let mut view = View::default();
        let rows = rows_of(&draw_with(
            &tr,
            &session,
            &Composer::default(),
            Theme::plain(),
            50,
            12,
            &mut view,
        ));
        let at = rows
            .iter()
            .position(|r| r.contains("… thinking"))
            .expect("folded");
        assert!(view.click_fold(u16::try_from(at).expect("on screen")));
        let open = rows_of(&draw_with(
            &tr,
            &session,
            &Composer::default(),
            Theme::plain(),
            50,
            12,
            &mut view,
        ))
        .join("\n");
        assert!(open.contains("I should check the manifest first"), "{open}");
    }

    #[test]
    fn the_context_gauge_warns_then_alarms_as_the_window_fills() {
        let session = ready_session();
        let colour = |pct: u64| {
            let mut tr = Transcript::default();
            tr.apply(
                SessionUpdate::from_value(
                    &json!({"sessionUpdate": "usage_update", "used": pct, "size": 100}),
                )
                .expect("update"),
            );
            let theme = Theme::banded((255, 255, 255));
            let buf = draw_with(
                &tr,
                &session,
                &Composer::default(),
                theme,
                60,
                12,
                &mut View::default(),
            );
            let row = buf.area.height - 1;
            let x = (0..60u16)
                .find(|x| buf[(*x, row)].symbol() == "c" && buf[(*x + 1, row)].symbol() == "t")
                .expect("the gauge is shown");
            buf[(x, row)].fg
        };
        let (hot, full) = (colour(70), colour(95));
        assert_ne!(hot, full, "warn, then alarm");
    }

    #[test]
    fn a_shell_command_title_is_coloured_and_its_dollar_sign_dropped() {
        let t = Tool {
            id: "1".into(),
            title: "$ git status --short".into(),
            kind: Some("execute".into()),
            status: ToolStatus::InProgress,
            subject: None,
            output: crate::transcript::Output::default(),
            diffs: vec![],
        };
        let rows = tool_lines(&t, 60, false, false, Theme::banded((255, 255, 255)));
        let cmd = rows[0]
            .spans
            .iter()
            .find(|s| s.content == "git")
            .expect("the command is its own span");
        assert_eq!(
            cmd.style.fg,
            Some(Color::Rgb(5, 80, 174)),
            "the tuned blue for a light terminal"
        );
        let flag = rows[0]
            .spans
            .iter()
            .find(|s| s.content == "--short")
            .expect("the flag is its own span");
        assert_eq!(flag.style.fg, Some(Color::Rgb(176, 79, 0)));
        assert!(!rows[0].spans.iter().any(|s| s.content.contains('$')));
    }

    fn ask(options: serde_json::Value) -> acp::Message {
        acp::Message::request(
            "kp1",
            "session/request_permission",
            json!({"toolCall": {"toolCallId": "t", "title": "Run it", "kind": "execute", "rawInput": {"command": "pwd; git status --short"}}, "options": options}),
        )
    }

    #[test]
    fn the_permission_panel_shows_the_whole_command_the_choices_and_the_chosen_one() {
        let mut session = ready_session();
        let mut scratch = Transcript::default();
        session.handle(crate::session::Event::Message(ask(json!([{"optionId": "a", "name": "Allow once", "kind": "allow_once"}, {"optionId": "r", "name": "Reject"}]))), 0, &mut scratch);
        let mut view = View {
            scroll: 0,
            sel: 1,
            ..View::default()
        };
        let rows = rows_of(&draw_with(
            &scratch,
            &session,
            &Composer::default(),
            Theme::plain(),
            70,
            24,
            &mut view,
        ));
        let text = rows.join("\n");
        assert!(text.contains("Needs you · Run it"), "{text}");
        assert!(text.contains("$ pwd; git status --short"), "{text}");
        assert!(text.contains("  1. Allow once"), "{text}");
        assert!(
            text.contains("› 2. Reject"),
            "the chosen option is marked: {text}"
        );
        // A click lands on the option drawn on its row, and nowhere else.
        let row_of = |needle: &str| {
            u16::try_from(rows.iter().position(|r| r.contains(needle)).expect(needle))
                .expect("on screen")
        };
        assert_eq!(view.option_at(row_of("1. Allow once")), Some(0));
        assert_eq!(view.option_at(row_of("2. Reject")), Some(1));
        assert_eq!(view.option_at(row_of("Needs you")), None);
    }

    #[test]
    fn a_question_is_drawn_as_a_panel_and_a_click_on_a_choice_row_picks_it() {
        let mut session = ready_session();
        let mut scratch = Transcript::default();
        let q = acp::Message::request(
            "kq",
            "elicitation/create",
            json!({"mode": "form", "message": "Which colour?", "requestedSchema": {"type": "object", "properties": {
                "colour": {"type": "string", "enum": ["red", "green"]}, "fast": {"type": "boolean"}}}}),
        );
        session.handle(crate::session::Event::Message(q), 0, &mut scratch);
        let mut view = View::default();
        let draw = |session: &Session, view: &mut View| {
            rows_of(&draw_with(
                &scratch,
                session,
                &Composer::default(),
                Theme::plain(),
                70,
                24,
                view,
            ))
        };
        let rows = draw(&session, &mut view);
        let text = rows.join("\n");
        assert!(
            text.contains("Needs you · Question") && text.contains("Which colour?"),
            "{text}"
        );
        let row_of = |rows: &[String], needle: &str| {
            u16::try_from(rows.iter().position(|r| r.contains(needle)).expect(needle))
                .expect("on screen")
        };
        let green = view
            .option_at(row_of(&rows, "2. green"))
            .expect("a choice row");
        assert_eq!(view.option_at(row_of(&rows, "Which colour?")), None);
        session
            .question_for(
                &acp::Id::from("kq"),
                crate::question::Act::Click(green),
                1000,
                &mut Transcript::default(),
            )
            .expect("picked");
        let rows = draw(&session, &mut view);
        assert!(rows.iter().any(|r| r.contains("› 2. green")), "{rows:?}");
    }

    #[test]
    fn a_long_form_on_a_short_screen_keeps_the_current_field_and_the_keys_in_view() {
        let mut session = ready_session();
        let mut scratch = Transcript::default();
        let mut props = serde_json::Map::new();
        for i in 0..9 {
            props.insert(
                format!("f{i}"),
                json!({"type": "string", "title": format!("Step {i}"), "enum": ["yes", "no"]}),
            );
        }
        props.insert(
            "last".into(),
            json!({"type": "string", "title": "Final choice",
                   "description": "Pick the one that suits the release. It matters a great deal, so read every word of this long description before choosing, since it wraps over several rows of a narrow screen and has no other job here.",
                   "enum": ["red", "green", "blue"]}),
        );
        let q = acp::Message::request(
            "kq",
            "elicitation/create",
            json!({"mode": "form", "message": "A long questionnaire", "requestedSchema": {"type": "object", "properties": props}}),
        );
        session.handle(crate::session::Event::Message(q), 0, &mut scratch);
        // Each Enter starts the next field's guard window: the clock moves on between them.
        for step in 1..=9_u64 {
            for act in [
                crate::question::Act::Pick(0),
                crate::question::Act::Enter(String::new()),
            ] {
                session
                    .question_for(&acp::Id::from("kq"), act, step * 10_000, &mut scratch)
                    .expect("walked");
            }
        }
        let mut view = View::default();
        let rows = rows_of(&draw_with(
            &scratch,
            &session,
            &Composer::default(),
            Theme::plain(),
            80,
            24,
            &mut view,
        ));
        let text = rows.join("\n");
        for needle in [
            "Final choice",
            "1. red",
            "2. green",
            "3. blue",
            "Esc declines",
        ] {
            assert!(text.contains(needle), "{needle} is on screen:\n{text}");
        }
        let row_of = |needle: &str| {
            u16::try_from(rows.iter().position(|r| r.contains(needle)).expect(needle))
                .expect("on screen")
        };
        assert_eq!(view.option_at(row_of("3. blue")), Some(2), "a click lands");
        assert_eq!(view.option_at(row_of("1. red")), Some(0));
    }

    fn model_choices() -> Transcript {
        let mut tr = Transcript::default();
        tr.apply(SessionUpdate::from_value(&json!({"sessionUpdate": "config_option_update", "configOptions": [
            {"id": "model", "name": "Model", "category": "model", "type": "select", "currentValue": "b", "options": [{"value": "a", "name": "Opus 4.1"}, {"value": "b", "name": "Sonnet 5.5"}]}]})).expect("update"));
        tr
    }

    fn typed(text: &str) -> Composer {
        let mut c = Composer::default();
        c.insert_str(text);
        c
    }

    #[test]
    fn the_command_list_shows_six_rows_follows_the_chosen_one_and_counts_the_rest() {
        let session = ready_session();
        let tr = model_choices();
        let agent: Vec<acp::Command> = (0..10)
            .map(|i| acp::Command {
                name: format!("cmd{i}"),
                description: format!("does {i}"),
                hint: None,
            })
            .collect();
        let entries = slash::entries("/", &agent, &tr, true);
        assert_eq!(entries.len(), 19);
        let mut view = View {
            palette: entries,
            ..View::default()
        };
        let rows = rows_of(&draw_with(
            &tr,
            &session,
            &typed("/"),
            Theme::plain(),
            70,
            24,
            &mut view,
        ));
        let text = rows.join("\n");
        assert!(rows.iter().all(|r| width_of(r) <= 70), "{rows:#?}");
        assert!(
            text.contains("› /model") && text.contains("Switch model"),
            "{text}"
        );
        assert!(text.contains("… 13 more · keep typing"), "{text}");
        assert!(!text.contains("/cmd5"), "only six rows: {text}");
        assert!(
            rows.last().is_some_and(|r| r.contains("Tab complete")),
            "{rows:#?}"
        );
        // Chosen far down, the window follows it and nothing is left to count.
        view.palette_sel = 18;
        let rows = rows_of(&draw_with(
            &tr,
            &session,
            &typed("/"),
            Theme::plain(),
            70,
            24,
            &mut view,
        ));
        let text = rows.join("\n");
        assert!(
            text.contains("› /cmd9") && !text.contains("/model") && !text.contains("more"),
            "{text}"
        );
    }

    #[test]
    fn what_the_agent_calls_its_commands_is_cleaned_before_it_is_drawn() {
        let session = ready_session();
        let tr = Transcript::default();
        let agent = vec![acp::Command {
            name: "de\u{9b}ploy".into(),
            description: "ships\nit\u{1b}[2J now".into(),
            hint: Some("[env]\t\u{9b}".into()),
        }];
        let mut view = View {
            palette: slash::entries("/de", &agent, &tr, false),
            ..View::default()
        };
        let rows = rows_of(&draw_with(
            &tr,
            &session,
            &typed("/de"),
            Theme::plain(),
            70,
            24,
            &mut view,
        ));
        let text = rows.join("\n");
        assert!(
            text.contains("/deploy") && text.contains("[env]  ships it[2J now"),
            "{text}"
        );
        assert!(
            !text.contains('\u{9b}') && !text.contains('\u{1b}'),
            "{text:?}"
        );
    }

    #[test]
    fn the_picker_marks_the_chosen_row_and_the_current_choice_and_a_request_takes_its_place() {
        let mut session = ready_session();
        let tr = model_choices();
        let slash::Pick::Open(p) = slash::pick(tr.option("model").expect("model"), "") else {
            panic!("a picker")
        };
        let mut view = View {
            picker: Some(p),
            ..View::default()
        };
        let rows = rows_of(&draw_with(
            &tr,
            &session,
            &Composer::default(),
            Theme::plain(),
            60,
            20,
            &mut view,
        ));
        let text = rows.join("\n");
        assert!(
            text.contains("› Sonnet 5.5 · current"),
            "opens on the current one: {text}"
        );
        assert!(
            text.contains("  Opus 4.1") && text.contains("Enter set"),
            "{text}"
        );
        // A permission arrives: it is what the panel shows.
        let mut scratch = Transcript::default();
        session.handle(crate::session::Event::Message(ask(json!([{"optionId": "a", "name": "Allow once", "kind": "allow_once"}, {"optionId": "r", "name": "Reject"}]))), 0, &mut scratch);
        let rows = rows_of(&draw_with(
            &tr,
            &session,
            &Composer::default(),
            Theme::plain(),
            60,
            20,
            &mut view,
        ));
        let text = rows.join("\n");
        assert!(
            text.contains("Needs you · Run it") && !text.contains("Opus 4.1"),
            "{text}"
        );
    }

    fn plan_of(statuses: &[&str]) -> Transcript {
        let mut tr = Transcript::default();
        let entries: Vec<serde_json::Value> = statuses
            .iter()
            .enumerate()
            .map(|(i, s)| json!({"content": format!("step {}", i + 1), "status": s}))
            .collect();
        tr.apply(
            SessionUpdate::from_value(&json!({"sessionUpdate": "plan", "entries": entries}))
                .expect("update"),
        );
        tr
    }

    #[test]
    fn the_plan_is_a_checklist_around_the_step_in_progress_and_gives_way_on_a_short_screen() {
        let session = ready_session();
        let tr = plan_of(&[
            "completed",
            "completed",
            "completed",
            "in_progress",
            "pending",
            "pending",
            "pending",
            "pending",
        ]);
        let mut view = View::default();
        let rows = rows_of(&draw_with(
            &tr,
            &session,
            &Composer::default(),
            Theme::plain(),
            60,
            30,
            &mut view,
        ));
        let text = rows.join("\n");
        assert!(text.contains("Plan · 3/8"), "{text}");
        assert!(
            text.contains("✓ step 3") && text.contains("● step 4") && text.contains("○ step 8"),
            "{text}"
        );
        assert!(
            !text.contains("step 1") && !text.contains("more"),
            "the finished steps scroll off, nothing is left to count: {text}"
        );
        // At the start, what does not fit is counted.
        let long = plan_of(&[
            "in_progress",
            "pending",
            "pending",
            "pending",
            "pending",
            "pending",
            "pending",
            "pending",
            "pending",
        ]);
        let text = rows_of(&draw_with(
            &long,
            &session,
            &Composer::default(),
            Theme::plain(),
            60,
            30,
            &mut view,
        ))
        .join("\n");
        assert!(
            text.contains("● step 1") && text.contains("… 3 more") && !text.contains("step 7"),
            "{text}"
        );
        // A short screen keeps the input and the conversation, not the plan.
        let rows = rows_of(&draw_with(
            &tr,
            &session,
            &Composer::default(),
            Theme::plain(),
            60,
            12,
            &mut view,
        ));
        assert!(!rows.join("\n").contains("Plan ·"), "{rows:#?}");
        assert!(rows.iter().all(|r| width_of(r) <= 60));
        // A finished plan says nothing: the end of the turn already did.
        let done = plan_of(&["completed", "completed"]);
        let text = rows_of(&draw_with(
            &done,
            &session,
            &Composer::default(),
            Theme::plain(),
            60,
            30,
            &mut view,
        ))
        .join("\n");
        assert!(
            !text.contains("Plan ·") && !text.contains("step 1"),
            "{text}"
        );
    }

    #[test]
    fn attached_files_show_on_one_row_above_the_input_and_never_overflow() {
        let session = ready_session();
        let tr = Transcript::default();
        let mut view = View {
            chips: vec![
                "src/main.rs".into(),
                "docs/TUI.md".into(),
                "/etc/a-very-long-file-name-indeed.conf".into(),
            ],
            ..View::default()
        };
        for w in [80_u16, 30] {
            let rows = rows_of(&draw_with(
                &tr,
                &session,
                &Composer::default(),
                Theme::plain(),
                w,
                14,
                &mut view,
            ));
            assert!(
                rows.iter().all(|r| width_of(r) <= usize::from(w)),
                "{rows:#?}"
            );
            let at = rows
                .iter()
                .position(|r| r.contains("+ src/main.rs"))
                .expect("the row");
            assert!(
                rows[at + 1].starts_with('─'),
                "the rule is right below: {rows:#?}"
            );
        }
        let rows = rows_of(&draw_with(
            &tr,
            &session,
            &Composer::default(),
            Theme::plain(),
            80,
            14,
            &mut view,
        ));
        assert!(
            rows.iter()
                .any(|r| r.contains("+ docs/TUI.md  + /etc/a-very-long")),
            "{rows:#?}"
        );
        view.chips.clear();
        let rows = rows_of(&draw_with(
            &tr,
            &session,
            &Composer::default(),
            Theme::plain(),
            80,
            14,
            &mut view,
        ));
        assert!(
            !rows.iter().any(|r| r.contains("+ src/main.rs")),
            "no files, no row"
        );
    }

    #[test]
    fn the_footer_says_how_far_an_update_has_got_and_a_request_still_comes_first() {
        let mut session = ready_session();
        let tr = Transcript::default();
        let mut view = View {
            update: Some("herdr-tui-linux-x86_64  ▕██████░░░▏  61%  3.1 MB / 5.1 MB".into()),
            ..View::default()
        };
        let rows = rows_of(&draw_with(
            &tr,
            &session,
            &Composer::default(),
            Theme::plain(),
            100,
            14,
            &mut view,
        ));
        let last = rows.last().expect("a footer");
        assert!(
            last.starts_with("  ↻ updating · herdr-tui-linux-x86_64") && last.contains("61%"),
            "{last}"
        );
        let mut scratch = Transcript::default();
        session.handle(crate::session::Event::Message(ask(json!([{"optionId": "a", "name": "Allow once", "kind": "allow_once"}, {"optionId": "r", "name": "Reject"}]))), 0, &mut scratch);
        let rows = rows_of(&draw_with(
            &tr,
            &session,
            &Composer::default(),
            Theme::plain(),
            100,
            24,
            &mut view,
        ));
        assert!(
            rows.iter().any(|r| r.contains("▲ Needs you")),
            "the request is on the panel: {rows:#?}"
        );
        assert!(
            rows.last().is_some_and(|r| !r.contains("updating")),
            "and it outranks the update line: {rows:#?}"
        );
    }

    #[test]
    fn the_files_row_says_how_to_take_them_off_when_there_is_room_and_the_picker_lists_them() {
        let session = ready_session();
        let tr = Transcript::default();
        let mut view = View {
            chips: vec!["notes.md".into(), "shot.png · picture".into()],
            ..View::default()
        };
        let rows = rows_of(&draw_with(
            &tr,
            &session,
            &Composer::default(),
            Theme::plain(),
            100,
            14,
            &mut view,
        ));
        let row = rows
            .iter()
            .find(|r| r.contains("+ notes.md"))
            .expect("the row");
        assert!(row.contains("+ shot.png · picture"), "{row}");
        assert!(
            row.ends_with("Backspace takes the last off · /files picks"),
            "{row}"
        );
        // Narrow: the names win over the hint.
        let rows = rows_of(&draw_with(
            &tr,
            &session,
            &Composer::default(),
            Theme::plain(),
            40,
            14,
            &mut view,
        ));
        let row = rows
            .iter()
            .find(|r| r.contains("+ notes.md"))
            .expect("the row");
        assert!(!row.contains("Backspace") && width_of(row) <= 40, "{row}");
        // The picker: the last one is chosen, as Backspace would take it.
        view.picker = Some(slash::attached(&view.chips));
        let text = rows_of(&draw_with(
            &tr,
            &session,
            &Composer::default(),
            Theme::plain(),
            100,
            24,
            &mut view,
        ))
        .join("\n");
        assert!(
            text.contains("Attached files")
                && text.contains("› shot.png · picture")
                && text.contains("  notes.md"),
            "{text}"
        );
        assert!(text.contains("Enter takes it off"), "{text}");
    }

    #[test]
    fn the_list_of_settings_shows_each_with_its_current_value() {
        let session = ready_session();
        let mut tr = model_choices();
        tr.apply(SessionUpdate::from_value(&json!({"sessionUpdate": "config_option_update", "configOptions": [
            {"id": "model", "name": "Model", "category": "model", "type": "select", "currentValue": "b", "options": [{"value": "a", "name": "Opus 4.1"}, {"value": "b", "name": "Sonnet 5.5"}]},
            {"id": "mode", "name": "Mode", "category": "mode", "type": "select", "currentValue": "plan", "options": [{"value": "default", "name": "Default"}, {"value": "plan", "name": "Plan"}]}]})).expect("update"));
        let mut view = View {
            picker: slash::settings(&tr),
            ..View::default()
        };
        let text = rows_of(&draw_with(
            &tr,
            &session,
            &Composer::default(),
            Theme::plain(),
            60,
            20,
            &mut view,
        ))
        .join("\n");
        assert!(
            text.contains("Settings")
                && text.contains("› Model · Sonnet 5.5")
                && text.contains("  Mode · Plan"),
            "{text}"
        );
    }

    #[test]
    fn choices_with_the_same_name_are_told_apart_by_their_value() {
        let session = ready_session();
        let mut tr = Transcript::default();
        tr.apply(SessionUpdate::from_value(&json!({"sessionUpdate": "config_option_update", "configOptions": [
            {"id": "model", "name": "Model", "category": "model", "type": "select", "currentValue": "x/opus", "options": [{"value": "x/opus", "name": "Opus"}, {"value": "y/opus", "name": "Opus"}, {"value": "z", "name": "Haiku"}]}]})).expect("update"));
        let slash::Pick::Open(p) = slash::pick(tr.option("model").expect("model"), "") else {
            panic!("a picker")
        };
        let mut view = View {
            picker: Some(p),
            ..View::default()
        };
        let rows = rows_of(&draw_with(
            &tr,
            &session,
            &Composer::default(),
            Theme::plain(),
            60,
            20,
            &mut view,
        ));
        let text = rows.join("\n");
        assert!(
            text.contains("› Opus · x/opus · current") && text.contains("  Opus · y/opus"),
            "{text}"
        );
        assert!(text.contains("  Haiku"), "{text}");
        assert!(
            !text.contains("Haiku · z"),
            "a name that is alone needs no value: {text}"
        );
    }

    #[test]
    fn a_long_choice_wraps_under_its_text_instead_of_running_off_the_edge() {
        let mut session = ready_session();
        let mut scratch = Transcript::default();
        let long = "Yes, and don't ask again for commands that start with `pwd; git rev-parse --show-toplevel`";
        session.handle(crate::session::Event::Message(ask(json!([{"optionId": "a", "name": long, "kind": "allow_always"}, {"optionId": "r", "name": "No"}]))), 0, &mut scratch);
        let mut view = View {
            scroll: 0,
            sel: 0,
            ..View::default()
        };
        let rows = rows_of(&draw_with(
            &scratch,
            &session,
            &Composer::default(),
            Theme::plain(),
            40,
            24,
            &mut view,
        ));
        assert!(rows.iter().all(|r| width_of(r) <= 40), "{rows:#?}");
        let text = rows.join(" ");
        assert!(
            text.contains("--show-toplevel") && text.contains("stays allowed"),
            "nothing was cut: {rows:#?}"
        );
        let at = rows
            .iter()
            .position(|r| r.contains("1. Yes"))
            .expect("shown");
        assert!(
            rows[at + 1].starts_with("▎      "),
            "the continuation hangs past the number: {rows:#?}"
        );
    }

    #[test]
    fn a_standing_reject_says_it_stays_rejected_not_allowed() {
        let mut session = ready_session();
        let mut scratch = Transcript::default();
        session.handle(crate::session::Event::Message(ask(json!([{"optionId": "a", "name": "Always allow", "kind": "allow_always"}, {"optionId": "r", "name": "Always reject", "kind": "reject_always"}]))), 0, &mut scratch);
        let mut view = View {
            scroll: 0,
            sel: 0,
            ..View::default()
        };
        let text = rows_of(&draw_with(
            &scratch,
            &session,
            &Composer::default(),
            Theme::plain(),
            70,
            24,
            &mut view,
        ))
        .join("\n");
        assert!(text.contains("Always allow  · stays allowed"), "{text}");
        assert!(text.contains("Always reject  · stays rejected"), "{text}");
    }

    #[test]
    fn the_rule_is_plain_and_the_footer_says_where_and_the_mode() {
        let session = ready_session();
        let mut tr = Transcript::default();
        tr.apply(
            SessionUpdate::from_value(
                &json!({"sessionUpdate": "session_info_update", "title": "Fix the flaky test"}),
            )
            .expect("update"),
        );
        tr.apply(
            SessionUpdate::from_value(
                &json!({"sessionUpdate": "current_mode_update", "currentModeId": "plan"}),
            )
            .expect("update"),
        );
        tr.apply(
            SessionUpdate::from_value(
                &json!({"sessionUpdate": "usage_update", "used": 47, "size": 100}),
            )
            .expect("update"),
        );
        let mut view = View {
            scroll: 0,
            sel: 0,
            ..View::default()
        };
        let rows = rows_of(&draw_with(
            &tr,
            &session,
            &Composer::default(),
            Theme::plain(),
            70,
            12,
            &mut view,
        ));
        assert!(
            !rows.iter().any(|r| r.contains("Fix the flaky test")),
            "the title is in the window title, not on a rule: {rows:#?}"
        );
        assert!(
            rows.iter()
                .any(|r| r.chars().all(|c| c == '─') && !r.is_empty()),
            "{rows:#?}"
        );
        assert!(rows.last().is_some_and(|r| r.starts_with("  Enter send") && r.ends_with("omp · /w · plan")), "one footer row: the hint on the left, where it runs and the mode on the right: {rows:#?}");
    }

    #[test]
    fn the_model_leads_the_footer_with_the_thinking_level_after_it() {
        let session = ready_session();
        let mut tr = Transcript::default();
        tr.apply(SessionUpdate::from_value(&json!({"sessionUpdate": "config_option_update", "configOptions": [
            {"id": "model", "category": "model", "type": "select", "currentValue": "a", "options": [{"value": "a", "name": "Sonnet 5.5"}]},
            {"id": "thinking", "category": "thought_level", "type": "select", "currentValue": "hi", "options": [{"value": "hi", "name": "high"}]}]})).expect("update"));
        tr.apply(
            SessionUpdate::from_value(
                &json!({"sessionUpdate": "usage_update", "used": 61, "size": 100}),
            )
            .expect("update"),
        );
        let mut view = View {
            scroll: 0,
            sel: 0,
            ..View::default()
        };
        let rows = rows_of(&draw_with(
            &tr,
            &session,
            &Composer::default(),
            Theme::plain(),
            80,
            12,
            &mut view,
        ));
        assert!(
            rows.last().is_some_and(|r| r.starts_with("  Enter send")
                && r.ends_with("Sonnet 5.5 · thinking high · ctx 61%")),
            "the model leads the facts, on the right: {rows:#?}"
        );
        // On a narrow screen the hint shortens and the facts do too, down to the gauge: the row never overflows.
        let narrow = rows_of(&draw_with(
            &tr,
            &session,
            &Composer::default(),
            Theme::plain(),
            30,
            12,
            &mut view,
        ));
        assert!(
            narrow
                .last()
                .is_some_and(|r| r.ends_with("ctx 61%") && width_of(r) <= 30),
            "{narrow:#?}"
        );
    }

    #[test]
    fn the_input_is_its_own_tinted_block_with_a_row_of_padding_either_side() {
        let session = ready_session();
        let mut composer = Composer::default();
        "hello".chars().for_each(|c| composer.insert(c));
        let mut view = View {
            scroll: 0,
            sel: 0,
            ..View::default()
        };
        let buf = draw_with(
            &Transcript::default(),
            &session,
            &composer,
            Theme::banded((255, 255, 255)),
            40,
            14,
            &mut view,
        );
        let rows = rows_of(&buf);
        let at = rows
            .iter()
            .position(|r| r.contains("› hello"))
            .expect("shown") as u16;
        let tint = Color::Rgb(242, 242, 242);
        for (row, what) in [
            (at - 1, "padding above"),
            (at, "the text"),
            (at + 1, "padding below"),
        ] {
            for x in [0u16, 10, 39] {
                assert_eq!(buf[(x, row)].bg, tint, "{what}, column {x}");
            }
        }
        assert_ne!(buf[(5, at + 2)].bg, tint, "the status line is not tinted");
    }

    #[test]
    fn without_a_tint_the_input_sits_between_two_rules() {
        let session = ready_session();
        let mut composer = Composer::default();
        "hello".chars().for_each(|c| composer.insert(c));
        let mut view = View {
            scroll: 0,
            sel: 0,
            ..View::default()
        };
        let rows = rows_of(&draw_with(
            &Transcript::default(),
            &session,
            &composer,
            Theme::plain(),
            40,
            14,
            &mut view,
        ));
        let at = rows
            .iter()
            .position(|r| r.contains("› hello"))
            .expect("shown");
        assert!(
            rows[at - 1].chars().all(|c| c == '─'),
            "a rule above: {rows:#?}"
        );
        assert!(
            rows[at + 1].chars().all(|c| c == '─'),
            "a rule below: {rows:#?}"
        );
    }

    #[test]
    fn no_screen_size_makes_the_untinted_input_paint_outside_the_screen() {
        let session = ready_session();
        for lines in [1usize, 3, 9] {
            let mut composer = Composer::default();
            for i in 0..lines {
                if i > 0 {
                    composer.insert('\n');
                }
                "word ".chars().for_each(|c| composer.insert(c));
            }
            for h in 1..=12u16 {
                for w in [1u16, 8, 40] {
                    // A panic here aborts the real program, so each size must simply draw.
                    draw_with(
                        &Transcript::default(),
                        &session,
                        &composer,
                        Theme::plain(),
                        w,
                        h,
                        &mut View::default(),
                    );
                    draw_with(
                        &Transcript::default(),
                        &session,
                        &composer,
                        Theme::banded((255, 255, 255)),
                        w,
                        h,
                        &mut View::default(),
                    );
                }
            }
        }
    }

    #[test]
    fn a_permission_panel_on_a_short_screen_does_not_paint_outside_it() {
        let mut session = ready_session();
        let mut scratch = Transcript::default();
        session.handle(
            crate::session::Event::Message(ask(
                json!([{"optionId": "a", "name": "Allow once", "kind": "allow_once"}]),
            )),
            0,
            &mut scratch,
        );
        for h in 1..=14u16 {
            for w in [1u16, 20, 70] {
                draw_with(
                    &Transcript::default(),
                    &session,
                    &Composer::default(),
                    Theme::plain(),
                    w,
                    h,
                    &mut View::default(),
                );
            }
        }
    }

    /// Where on screen the terminal's cursor was put, and the text of the row it is on.
    fn cursor_of(text: &str, at: usize, w: u16, h: u16) -> ((u16, u16), String) {
        let session = ready_session();
        let mut composer = Composer::default();
        text.chars().for_each(|c| composer.insert(c));
        while composer.cursor > at {
            composer.left();
        }
        let mut term = Terminal::new(TestBackend::new(w, h)).expect("a test terminal");
        let tr = Transcript::default();
        let queue = Queue::default();
        let ctx = Frame_ {
            transcript: &tr,
            session: &session,
            composer: &composer,
            header: Header {
                agent: "omp",
                cwd: "/w",
            },
            theme: Theme::plain(),
            hint: None,
            working_secs: None,
            queue: &queue,
            newer: None,
        };
        term.draw(|f| draw(f, &ctx, &mut View::default()))
            .expect("drawn");
        let pos = term.get_cursor_position().expect("a cursor");
        let rows = rows_of(term.backend().buffer());
        (
            (pos.x, pos.y),
            rows.get(usize::from(pos.y)).cloned().unwrap_or_default(),
        )
    }

    #[test]
    fn the_cursor_sits_on_the_letter_it_edits_even_when_a_word_wrapped() {
        // "hello world" at width 12: the input shows `› hello` then `  world`.
        let (pos, row) = cursor_of("hello world", 9, 12, 12);
        assert!(
            row.contains("world"),
            "the cursor is on the row that holds the word, not after `hello`: {pos:?} {row:?}"
        );
        assert_eq!(usize::from(pos.0), "  wor".len(), "between `wor` and `ld`");
    }

    #[test]
    fn a_full_row_moves_the_cursor_to_the_start_of_the_next_row_not_off_the_screen() {
        let ((x, _), _) = cursor_of("abcdefghij", 10, 12, 12);
        assert!(x < 12, "x = {x} is on screen");
        assert_eq!(x, 2, "the next row, after the gutter");
    }

    #[test]
    fn the_cursor_is_always_on_the_screen_even_when_it_is_tiny() {
        for (w, h) in [(1u16, 1u16), (3, 2), (5, 3), (2, 12)] {
            let ((x, y), _) = cursor_of("abc def ghi", 11, w, h);
            assert!(x < w && y < h, "{w}x{h}: cursor at ({x}, {y})");
        }
    }

    #[expect(
        clippy::too_many_arguments,
        reason = "a test helper: each argument is one thing a frame depends on"
    )]
    fn draw_state(
        tr: &Transcript,
        session: &Session,
        composer: &Composer,
        queue: &Queue,
        theme: Theme,
        w: u16,
        h: u16,
        working_secs: Option<u64>,
    ) -> Buffer {
        let mut term = Terminal::new(TestBackend::new(w, h)).expect("a test terminal");
        let ctx = Frame_ {
            transcript: tr,
            session,
            composer,
            header: Header {
                agent: "omp",
                cwd: "/w",
            },
            theme,
            hint: None,
            working_secs,
            queue,
            newer: None,
        };
        term.draw(|f| draw(f, &ctx, &mut View::default()))
            .expect("drawn");
        term.backend().buffer().clone()
    }

    fn working() -> Transcript {
        let mut tr = Transcript::default();
        tr.apply(
            SessionUpdate::from_value(
                &json!({"sessionUpdate": "state_update", "state": "running"}),
            )
            .expect("update"),
        );
        tr
    }

    fn queued(texts: &[&str]) -> Queue {
        let mut q = Queue::default();
        for t in texts {
            q.push((*t).to_string(), Vec::new());
        }
        q
    }

    fn state_rows(
        tr: &Transcript,
        composer: &Composer,
        queue: &Queue,
        w: u16,
        h: u16,
    ) -> Vec<String> {
        rows_of(&draw_state(
            tr,
            &ready_session(),
            composer,
            queue,
            Theme::plain(),
            w,
            h,
            Some(12),
        ))
    }

    #[test]
    fn the_working_row_is_plain_and_says_how_to_queue_only_when_something_is_typed() {
        let tr = working();
        let rows = state_rows(&tr, &Composer::default(), &Queue::default(), 90, 10);
        let row = rows
            .iter()
            .find(|r| r.contains("Ctrl-C stops"))
            .expect("the working row");
        assert!(
            row.trim_start().starts_with("● Working 12s · Ctrl-C stops"),
            "{row:?}"
        );
        for decoration in ["⠋", "Untangling", "Tip"] {
            assert!(!row.contains(decoration), "{decoration}: {row:?}");
        }
        let mut typing = Composer::default();
        typing.insert_str("also the docs");
        let rows = state_rows(&tr, &typing, &Queue::default(), 90, 10);
        assert!(
            rows.iter()
                .any(|r| r.contains("Working 12s · Enter queues · Ctrl-C stops")),
            "{rows:#?}"
        );
    }

    #[test]
    fn a_waiting_request_is_said_once_and_the_footer_leaves_its_keys_to_the_panel() {
        let mut session = ready_session();
        let mut scratch = Transcript::default();
        session.handle(
            crate::session::Event::Message(ask(
                json!([{"optionId": "a", "name": "Allow once", "kind": "allow_once"}]),
            )),
            0,
            &mut scratch,
        );
        let rows = rows_of(&draw_state(
            &Transcript::default(),
            &session,
            &Composer::default(),
            &Queue::default(),
            Theme::plain(),
            70,
            24,
            None,
        ));
        let text = rows.join("\n");
        assert_eq!(text.matches("Needs you").count(), 1, "{text}");
        assert!(
            text.contains("▲ Needs you") && !text.contains('△'),
            "{text}"
        );
        let footer = rows.last().expect("a footer");
        assert!(footer.contains("omp"), "the facts stay: {footer:?}");
        assert!(
            !footer.contains("choose") && !footer.contains("Enter"),
            "the footer does not repeat the panel's keys: {footer:?}"
        );
    }

    #[test]
    fn a_finished_call_carries_no_mark_and_a_failed_one_does() {
        let mut tr = Transcript::default();
        for (id, title, status) in [("a", "Read ok.rs", "completed"), ("b", "Run bad", "failed")] {
            tr.apply(SessionUpdate::from_value(&json!({"sessionUpdate": "tool_call", "toolCallId": id, "title": title, "status": status})).expect("update"));
        }
        agent(&mut tr, "m", "that is all");
        let rows = state_rows(&tr, &Composer::default(), &Queue::default(), 60, 16);
        let ok = rows.iter().find(|r| r.contains("Read ok.rs")).expect("ok");
        let bad = rows.iter().find(|r| r.contains("Run bad")).expect("bad");
        assert!(!ok.contains('✓'), "success is the default: {ok:?}");
        assert!(bad.contains('✗'), "{bad:?}");
    }

    #[test]
    fn the_context_gauge_waits_until_the_window_is_filling() {
        for (used, shown) in [(47, false), (59, false), (60, true), (90, true)] {
            let mut tr = Transcript::default();
            tr.apply(
                SessionUpdate::from_value(
                    &json!({"sessionUpdate": "usage_update", "used": used, "size": 100}),
                )
                .expect("update"),
            );
            let rows = state_rows(&tr, &Composer::default(), &Queue::default(), 70, 12);
            let footer = rows.last().expect("a footer");
            assert_eq!(
                footer.contains(&format!("ctx {used}%")),
                shown,
                "{footer:?}"
            );
        }
    }

    #[test]
    fn queued_messages_sit_in_order_above_the_box_and_the_rest_are_counted() {
        let q = queued(&["first", "second", "third", "fourth", "fifth"]);
        let tr = working();
        for w in [40u16, 100] {
            let rows = state_rows(&tr, &Composer::default(), &q, w, 20);
            let at = |n: &str| {
                rows.iter()
                    .position(|r| r.contains(n))
                    .unwrap_or_else(|| panic!("{n}: {rows:#?}"))
            };
            assert!(at("↳ first") < at("↳ second") && at("↳ second") < at("↳ third"));
            assert!(at("↳ third") < at("2 more queued"));
            assert!(at("2 more queued") < at("Queue a message"));
            assert!(!rows.iter().any(|r| r.contains("fourth")), "{rows:#?}");
            assert!(
                rows.iter().all(|r| width_of(r) <= usize::from(w)),
                "{rows:#?}"
            );
        }
    }

    #[test]
    fn a_queued_message_shows_its_first_line_and_its_files() {
        let mut q = Queue::default();
        q.push(
            "check the build\nthen the tests".to_string(),
            vec![crate::attach::attachment("/w/src/a.rs", "/w")],
        );
        let rows = state_rows(&working(), &Composer::default(), &q, 60, 20);
        let row = rows.iter().find(|r| r.contains("↳")).expect("a queued row");
        assert!(
            row.contains("check the build…") && row.ends_with(" · 1 file"),
            "{row:?}"
        );
        assert!(!rows.join("\n").contains("then the tests"));
    }

    #[test]
    fn a_click_on_a_queued_row_names_that_message_and_nothing_else_does() {
        let mut q = queued(&["first", "second", "third", "fourth", "fifth"]);
        q.hold_all("the turn failed");
        let ids: Vec<u64> = q.entries().iter().map(|e| e.id).collect();
        let (tr, session, composer) = (working(), ready_session(), Composer::default());
        let mut view = View::default();
        let mut term = Terminal::new(TestBackend::new(80, 24)).expect("a test terminal");
        let ctx = Frame_ {
            transcript: &tr,
            session: &session,
            composer: &composer,
            header: Header {
                agent: "omp",
                cwd: "/w",
            },
            theme: Theme::plain(),
            hint: None,
            working_secs: Some(1),
            queue: &q,
            newer: None,
        };
        term.draw(|f| draw(f, &ctx, &mut view)).expect("drawn");
        let rows = rows_of(term.backend().buffer());
        let at = |needle: &str| {
            u16::try_from(rows.iter().position(|r| r.contains(needle)).expect(needle))
                .expect("on screen")
        };
        assert_eq!(view.queued_at(at("↳ first")), Some(ids[0]));
        assert_eq!(view.queued_at(at("↳ third")), Some(ids[2]));
        assert_eq!(
            view.queued_at(at("Held ·")),
            None,
            "the header is not a message"
        );
        assert_eq!(view.queued_at(at("2 more queued")), None);
        assert_eq!(
            view.queued_at(at("Queue a message")),
            None,
            "nor is the box"
        );
        assert_eq!(view.queued_at(0), None);
    }

    #[test]
    fn the_way_back_is_said_beside_the_queue_when_there_is_room_and_ctrl_c_says_it_sends_it() {
        let q = queued(&["first"]);
        let wide = state_rows(&working(), &Composer::default(), &q, 100, 20).join("\n");
        assert!(wide.contains("Backspace takes the newest back"), "{wide}");
        let narrow = state_rows(&working(), &Composer::default(), &q, 50, 20).join("\n");
        assert!(!narrow.contains("Backspace"), "{narrow}");
        assert!(wide.contains("Ctrl-C stops and sends queued"), "{wide}");
        let none = state_rows(&working(), &Composer::default(), &Queue::default(), 100, 20);
        let none = none.join("\n");
        assert!(
            none.contains("Ctrl-C stops") && !none.contains("sends queued"),
            "{none}"
        );
        // A held queue is not sent by Ctrl-C's end of turn: the row does not promise it.
        let mut held = queued(&["first"]);
        held.hold_all("the turn failed");
        let text = state_rows(&working(), &Composer::default(), &held, 100, 20).join("\n");
        assert!(!text.contains("sends queued"), "{text}");
    }
    #[test]
    fn a_held_queue_says_why_and_how_to_go_on() {
        let mut q = queued(&["first", "second"]);
        q.hold_all("the turn failed");
        let rows = state_rows(&Transcript::default(), &Composer::default(), &q, 70, 20);
        let held = rows
            .iter()
            .position(|r| r.contains("Held · the turn failed · Enter resumes"))
            .expect("the held row");
        let first = rows
            .iter()
            .position(|r| r.contains("↳ first"))
            .expect("first");
        assert!(held < first, "{rows:#?}");
    }

    #[test]
    fn a_short_terminal_gives_up_the_queue_before_the_box() {
        let q = queued(&["first", "second"]);
        let rows = state_rows(&working(), &Composer::default(), &q, 60, 10);
        assert!(!rows.iter().any(|r| r.contains('↳')), "{rows:#?}");
        assert!(
            rows.iter().any(|r| r.contains("› Queue a message")),
            "{rows:#?}"
        );
        // The rows had no room, so the footer is where a message is not swallowed silently.
        let footer = rows.last().expect("a footer");
        assert!(footer.contains("2 queued"), "{footer:?}");
        let mut held = queued(&["first", "second"]);
        held.hold_all("the turn failed");
        let rows = state_rows(&Transcript::default(), &Composer::default(), &held, 60, 10);
        assert!(
            rows.last()
                .is_some_and(|r| r.contains("2 queued, held · Enter resumes")),
            "{rows:#?}"
        );
    }

    #[test]
    fn the_empty_box_invites_a_message_to_queue_only_while_a_turn_runs() {
        let idle = state_rows(
            &Transcript::default(),
            &Composer::default(),
            &Queue::default(),
            60,
            12,
        );
        assert!(
            idle.iter().any(|r| r.contains("› Message the agent")),
            "{idle:#?}"
        );
        let busy = state_rows(&working(), &Composer::default(), &Queue::default(), 60, 12);
        assert!(
            busy.iter()
                .any(|r| r.contains("› Queue a message for when this turn ends")),
            "{busy:#?}"
        );
    }

    #[test]
    fn the_footer_is_one_row_and_a_mode_that_says_nothing_is_left_out() {
        let session = ready_session();
        let mut tr = Transcript::default();
        tr.apply(SessionUpdate::from_value(&json!({"sessionUpdate": "config_option_update", "configOptions": [
            {"id": "model", "category": "model", "type": "select", "currentValue": "a", "options": [{"value": "a", "name": "Claude Sonnet 5.5"}]},
            {"id": "mode", "category": "mode", "type": "select", "currentValue": "d", "options": [{"value": "d", "name": "Default"}]}]})).expect("update"));
        tr.apply(
            SessionUpdate::from_value(
                &json!({"sessionUpdate": "usage_update", "used": 61, "size": 100}),
            )
            .expect("update"),
        );
        let rows = rows_of(&draw_with(
            &tr,
            &session,
            &Composer::default(),
            Theme::plain(),
            90,
            14,
            &mut View::default(),
        ));
        let last = rows.last().expect("a footer");
        assert!(
            last.contains("Claude Sonnet 5.5")
                && last.contains("ctx 61%")
                && last.contains("Enter send"),
            "{last:?}"
        );
        assert!(
            !last.contains("Default"),
            "a mode that says nothing is noise: {last:?}"
        );
        // Nothing else sits under the input: the footer is the only row of text there.
        assert!(
            !rows[rows.len() - 2].contains("Enter send") && !rows[rows.len() - 2].contains("ctx"),
            "{rows:#?}"
        );
        // Aligned to the same two-column gutter, and not touching the right edge.
        assert!(
            last.starts_with("  Enter") && width_of(last) <= 88,
            "{last:?} is {}",
            width_of(last)
        );
    }

    #[test]
    fn the_key_list_opens_with_a_question_mark_and_a_waiting_request_outranks_it() {
        let session = ready_session();
        let mut view = View {
            help: true,
            ..View::default()
        };
        let text = rows_of(&draw_with(
            &Transcript::default(),
            &session,
            &Composer::default(),
            Theme::plain(),
            70,
            30,
            &mut view,
        ))
        .join("\n");
        for want in [
            "Keys",
            "Ctrl-J",
            "browse what the agent did",
            "Ctrl-D",
            "leave; the session keeps running",
        ] {
            assert!(text.contains(want), "{want}: {text}");
        }
        let mut asking = ready_session();
        let mut scratch = Transcript::default();
        asking.handle(
            crate::session::Event::Message(ask(
                json!([{"optionId": "a", "name": "Allow once", "kind": "allow_once"}]),
            )),
            0,
            &mut scratch,
        );
        let mut view = View {
            help: true,
            ..View::default()
        };
        let text = rows_of(&draw_with(
            &Transcript::default(),
            &asking,
            &Composer::default(),
            Theme::plain(),
            70,
            30,
            &mut view,
        ))
        .join("\n");
        assert!(
            text.contains("Needs you") && !text.contains("Keys"),
            "a request is never hidden behind help: {text}"
        );
    }

    #[test]
    fn a_session_with_nothing_in_it_yet_welcomes_the_person() {
        let session = ready_session();
        let text = rows_of(&draw_with(
            &Transcript::default(),
            &session,
            &Composer::default(),
            Theme::plain(),
            60,
            16,
            &mut View {
                scroll: 0,
                sel: 0,
                ..View::default()
            },
        ))
        .join("\n");
        assert!(text.contains("• Ready when you are."), "{text}");
        assert!(text.contains("Try"), "{text}");
        assert!(!text.contains("Tip:"), "no tips: {text}");
    }

    #[test]
    fn a_short_conversation_sits_just_above_the_input() {
        let mut tr = Transcript::default();
        tr.user("hello");
        let rows = render(&tr, 40, 12, 0);
        let hello = rows
            .iter()
            .position(|r| r.contains("hello"))
            .expect("shown");
        assert!(hello >= 5, "bottom-aligned, got row {hello}: {rows:#?}");
    }
}
