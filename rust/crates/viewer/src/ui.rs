//! Drawing. Only the lines that can be seen are built: a long history costs
//! nothing until it is scrolled to.
//!
//! The layout keeps one left gutter of two columns: what the person said sits in a tinted band
//! behind a `›`, what the agent said hangs from a `•`, and every tool call, note and result
//! opens with its mark in the same column. Below the conversation sit the permission panel
//! (when one waits), the rule that carries the session's title, the input, a status line and
//! one line of facts about the session.

use crate::composer::Composer;
use crate::delight;
use crate::fold::{self, Block};
use crate::md::{self, clean};
use crate::session::{Phase, Session, Waiting};
use crate::shell;
use crate::theme::Theme;
use crate::transcript::{Entry, Item, Role, Tool, Transcript};
use acp::ToolStatus;
use ratatui::{
    layout::{Constraint, Layout, Position, Rect},
    style::{Modifier, Style},
    text::{Line, Span},
    widgets::Paragraph,
    Frame,
};
use std::collections::{HashMap, HashSet, VecDeque};
use unicode_width::UnicodeWidthChar;

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
    /// Blocks that were just opened, by key, and the animation time they began: they grow into place.
    pub reveal: HashMap<u64, u64>,
    /// The lines of the blocks, kept from one frame to the next, and the width they were built at.
    line_cache: LineCache,
    last_width: usize,
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

    /// What just opened: the lines it had before, for the unfold animation. Parked out of the
    /// open blocks under its own key with the content revision set to `u64::MAX` (a value a real
    /// revision never takes), so a second block mid-reveal reads its own height, not a neighbour's.
    fn closed_lines(
        &mut self,
        b: Block,
        items: &VecDeque<Item>,
        width: usize,
        expanded: &HashSet<u64>,
        look: Look,
    ) -> Vec<Line<'static>> {
        let mut closed = expanded.clone();
        let bkey = fold::key(b, items);
        closed.remove(&bkey);
        let was = match b {
            Block::Run { start, end, .. } => Block::Run {
                start,
                end,
                open: false,
            },
            one => one,
        };
        let key = LineKey {
            block: bkey,
            rev: u64::MAX,
            width,
            gen: self.gen,
        };
        if !self.lines.contains_key(&key) {
            self.order.push_back(key);
            let l = block_lines(
                was,
                items,
                width,
                Look {
                    expanded: &closed,
                    ..look
                },
            );
            self.chars += line_size(&l);
            self.lines.insert(key, l);
            self.enforce();
        }
        self.lines.get(&key).expect("just inserted").clone()
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
    /// How many turns this run has finished (varies the waiting word).
    pub turn: usize,
    /// Milliseconds on the animation clock: what the spinner, shimmer, pulse and unfolds read.
    pub anim_ms: u64,
    /// Whether things move at all (`HERDR_TUI_MOTION=off` and friends turn it off).
    pub motion: bool,
}

fn width_of(s: &str) -> usize {
    s.chars().map(|c| c.width().unwrap_or(0)).sum()
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
            for (i, c) in word.char_indices() {
                let cw = c.width().unwrap_or(0);
                if w + cw > width && at + i > row_start {
                    rows.push((row_start, at + i));
                    row_start = at + i;
                    w = 0;
                }
                w += cw;
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
    for c in s.chars() {
        let cw = c.width().unwrap_or(0);
        if w + cw + 1 > width {
            break;
        }
        out.push(c);
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

/// What the agent said: markdown hanging from a bullet.
fn agent_lines(text: &str, width: usize, theme: Theme) -> Vec<Line<'static>> {
    md::render(text, width.saturating_sub(GUTTER), theme)
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
        ToolStatus::Completed => ("✓ ", theme.ok()),
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
        for (mark, text) in rows.into_iter().take(show) {
            let style = match mark {
                '+' => theme.ok(),
                '-' => theme.bad(),
                _ => theme.dim(),
            };
            out.push(Line::from(vec![
                Span::styled(format!("    {mark} "), style),
                Span::styled(fit(&clean(&text), width.saturating_sub(6)), style),
            ]));
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
        let verb = t
            .title
            .trim_start_matches("$ ")
            .split_whitespace()
            .next()
            .unwrap_or("tool")
            .to_string();
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
        } => agent_lines(text, width, theme),
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
fn welcome(ctx: &Frame_, theme: Theme) -> Vec<Line<'static>> {
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
        Line::from(Span::styled(
            format!("  Tip: {}", delight::tip(ctx.turn)),
            theme.dim(),
        )),
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

/// The panel that asks the person: what, the command whole, the choices, how to answer.
fn panel_lines(
    lit: bool,
    w: &Waiting,
    total: usize,
    sel: usize,
    width: usize,
    max_subject: usize,
    theme: Theme,
) -> Vec<Line<'static>> {
    let inner = width.saturating_sub(GUTTER * 2);
    let tc = w.request.tool_call.as_ref();
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
            Span::styled(
                if lit {
                    "▲ Needs you"
                } else {
                    "△ Needs you"
                },
                theme.warn(),
            ),
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
    for (i, o) in w.request.options.iter().enumerate() {
        let chosen = i == sel.min(w.request.options.len().saturating_sub(1));
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
        rows.extend(md::wrap_spans(
            body,
            vec![Span::raw("  "), Span::styled(mark, style)],
            vec![Span::raw("       ")],
            width.saturating_sub(GUTTER),
        ));
    }
    rows.push(Line::default());
    rows.push(Line::from(vec![
        Span::raw("  "),
        Span::styled(
            "Tab chooses · Enter confirms · a number answers · Esc cancels",
            theme.dim(),
        ),
    ]));
    rows.push(Line::default());
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
    let panel = waiting
        .first()
        .map(|first| {
            let max_subject =
                ((area.height as usize / 2).saturating_sub(9)).clamp(2, SUBJECT_MAX_ROWS);
            v.sel = v.sel.min(first.request.options.len().saturating_sub(1));
            panel_lines(
                !ctx.motion || delight::pulse(ctx.anim_ms),
                first,
                waiting.len(),
                v.sel,
                w,
                max_subject,
                theme,
            )
        })
        .or_else(|| v.help.then(|| help_lines(w, theme)));
    let panel_h = panel
        .as_ref()
        .map_or(0, |p| p.len() as u16)
        .min(area.height.saturating_sub(7));
    // The input sits in its own zone: a tinted block where the terminal's background is known,
    // else a rule above it and below it. `HERDR_TUI_INPUT=rules` asks for the rules.
    let tinted = theme
        .band()
        .filter(|_| std::env::var("HERDR_TUI_INPUT").map_or(true, |v| v != "rules"));
    let title = ctx.transcript.title().map(clean);
    // The rule above carries the session's title; a tinted input needs no rule unless there is one.
    let rule_h = u16::from(!(tinted.is_some() && title.is_none()));
    let zone_h = comp_h + if tinted.is_some() { 2 } else { 1 };
    let [hist, perm, rule, zone, footer] = Layout::vertical([
        Constraint::Min(1),
        Constraint::Length(panel_h),
        Constraint::Length(rule_h),
        Constraint::Length(zone_h),
        Constraint::Length(1),
    ])
    .areas(area);

    let welcome = if ctx.transcript.items().is_empty() && ctx.session.ready() {
        welcome(ctx, theme)
    } else {
        Vec::new()
    };
    draw_history(f, hist, ctx, v, welcome);
    if let Some(rows) = panel {
        f.render_widget(Paragraph::new(rows), perm);
    }

    if rule_h > 0 {
        let rule_line = match title {
            Some(t) => {
                let t = fit(&t, w.saturating_sub(8));
                let left = w.saturating_sub(width_of(&t) + 4 + 2);
                Line::from(vec![
                    Span::styled("─".repeat(left), theme.dim()),
                    Span::styled(format!(" {t} "), theme.dim()),
                    Span::styled("──", theme.dim()),
                ])
            }
            None => Line::from(Span::styled("─".repeat(w), theme.dim())),
        };
        f.render_widget(Paragraph::new(rule_line), rule);
    }

    // What the input shows. When it is taller than the room, the rows around the cursor.
    let skip = (cur_row + 1)
        .saturating_sub(usize::from(comp_h))
        .min(ranges.len().saturating_sub(usize::from(comp_h)));
    let lines: Vec<Line<'static>> = if text.is_empty() {
        let hint = if ctx.session.ready() {
            "Message the agent"
        } else {
            "Opening the session…"
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
    let mut left = footer_left(
        ctx,
        v,
        !waiting.is_empty(),
        waiting
            .first()
            .map_or(1, |w| w.request.options.len().max(1)),
    );
    if v.scroll > 0 {
        left.push(Span::styled("   ↓ End: newest", theme.dim()));
    }
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

/// What the left of the footer says, by what the person is doing. Only the keys needed to act now;
/// the rest are behind `?`.
fn footer_left(ctx: &Frame_, v: &View, asking: bool, options: usize) -> Vec<Span<'static>> {
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
    if asking {
        let mark = if !ctx.motion || delight::pulse(ctx.anim_ms) {
            "▲ "
        } else {
            "△ "
        };
        return vec![
            Span::styled(mark, theme.warn()),
            Span::styled(format!("choose 1–{options} and press Enter"), theme.warn()),
        ];
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
        let verb = format!("{}…", delight::verb(secs, ctx.turn));
        let mut out: Vec<Span<'static>> = Vec::new();
        if ctx.motion {
            // A spinner, and a sheen that crosses the word, then rests a beat. Only while a turn runs.
            out.push(Span::styled(
                format!("{} ", delight::spinner(ctx.anim_ms)),
                theme.accent(),
            ));
            let lit = delight::shimmer(verb.chars().count(), ctx.anim_ms);
            out.extend(verb.chars().zip(lit).map(|(c, on)| {
                Span::styled(
                    c.to_string(),
                    if on {
                        theme.accent().add_modifier(Modifier::BOLD)
                    } else {
                        theme.bold()
                    },
                )
            }));
        } else {
            out.push(Span::styled("● ", theme.accent()));
            out.push(Span::styled(verb, theme.bold()));
        }
        out.push(Span::styled(
            format!(" {}", delight::duration(secs)),
            theme.dim(),
        ));
        out.push(Span::styled(" · Ctrl-C stops", theme.dim()));
        if let Some(tip) = delight::tip_for_turn(secs, ctx.turn) {
            out.push(Span::styled(format!(" · Tip: {tip}"), theme.dim()));
        }
        return out;
    }
    vec![Span::styled(
        "Enter send · Ctrl-J newline · ? keys",
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
    let gauge = tr.context().map(|c| {
        let style = match c {
            0..=59 => theme.dim(),
            60..=84 => theme.warn(),
            _ => theme.bad(),
        };
        (format!("ctx {c}%"), style)
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
    const KEYS: [(&str, &str); 12] = [
        ("Enter", "send"),
        ("Ctrl-J", "new line"),
        ("↑ ↓  wheel", "scroll"),
        ("PgUp PgDn", "page"),
        ("Home  End", "oldest, newest"),
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
    let (tr, theme, anim_ms, motion) = (ctx.transcript, ctx.theme, ctx.anim_ms, ctx.motion);
    v.page = (area.height as usize).saturating_sub(2).max(1);
    let need = (area.height as usize).saturating_add(v.scroll);
    let items = tr.items();
    let blocks = fold::blocks(items, &v.expanded);
    let look = Look {
        expanded: &v.expanded,
        focus: v.focus,
        thoughts: v.thoughts,
        theme,
    };
    let width = area.width as usize;
    if width != v.last_width {
        v.last_width = width;
        v.line_cache.clear();
    }
    let h = area.height as usize;
    let mut reached_start = true;
    let mut reveals: HashMap<u64, u64> = if motion {
        v.reveal.clone()
    } else {
        HashMap::new()
    };
    for b in &blocks {
        if let Block::Run {
            start,
            end,
            open: true,
        } = *b
        {
            if let Some(&t) = reveals.get(&fold::key(*b, items)) {
                for item in items.iter().skip(start).take(end - start) {
                    reveals.entry(item.id).or_insert(t);
                }
            }
        }
    }
    // Pass 1, newest first: how many lines each block draws, and where, counted up from the
    // newest. A scroll walks this per block, so a long history costs a lookup each, not a
    // clone. The count of a block that is mid-unfold is the height it has at this moment.
    let mut spans: Vec<(Block, usize, usize)> = Vec::new();
    let mut found: Option<(usize, usize)> = None;
    let total = if items.is_empty() {
        welcome.len()
    } else {
        let mut count = 0usize;
        for (bi, b) in blocks.iter().enumerate().rev() {
            let bkey = fold::key(*b, items);
            let mut n = v.line_cache.count_for(*b, items, width, look);
            if let Some(&started) = reveals.get(&bkey) {
                let elapsed = anim_ms.saturating_sub(started);
                if elapsed < delight::REVEAL_MS {
                    let before = if v.reveal.contains_key(&bkey) {
                        v.line_cache
                            .closed_lines(*b, items, width, &v.expanded, look)
                            .len()
                    } else {
                        0
                    };
                    // A block can shrink as it opens (a run folds from its calls to one line),
                    // and the easing may ask for more rows than the block has now: cap at the
                    // block's real height, so the pass-2 slice of its lines never runs off the end.
                    n = delight::reveal_rows(before, n, elapsed).min(n);
                }
            }
            if v.focus == Some(bkey) {
                found = Some((count, count + n));
            }
            spans.push((*b, count, count + n));
            count += n;
            if count >= need && (!v.focus_dirty || found.is_some()) {
                reached_start = bi == 0;
                break;
            }
        }
        count
    };
    // The "not shown" line sits oldest, just past the last built line.
    let has_drop = reached_start && tr.dropped() > 0;
    let all = total + usize::from(has_drop);
    // Unfolds that have finished are forgotten, so the loop can go back to sleep.
    v.reveal
        .retain(|_, started| motion && anim_ms.saturating_sub(*started) < delight::REVEAL_MS);
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
    // Do not scroll past the oldest line built.
    v.scroll = v.scroll.min(all.saturating_sub(h));
    let end = (v.scroll + h).min(all);
    // Pass 2: the lines the window `v.scroll..end` shows, oldest first, and nothing else.
    // A block spans newest-first index `from..to`, so the part the window shows, oldest
    // first, is its own lines `to - hi .. to - lo`, where `lo..hi` is that overlap.
    let mut out_window: Vec<Line> = Vec::new();
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
                let lines = v.line_cache.ensure(b, items, width, look);
                out_window.extend(lines[(to - hi)..(to - lo)].iter().cloned());
            }
        }
    }
    // Bottom-align: short history sits just above the input.
    let pad = h - out_window.len().min(h);
    let mut out = vec![Line::default(); pad];
    out.extend(out_window);
    f.render_widget(Paragraph::new(out), area);
}

#[cfg(test)]
mod tests {
    use super::*;
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
            turn: 0,
            anim_ms: 0,
            motion: false,
        };
        term.draw(|f| draw(f, &ctx, view)).expect("drawn");
        term.backend().buffer().clone()
    }

    /// `draw_with`, with the unfold animation's clock and motion set, for the reveal tests.
    #[allow(clippy::too_many_arguments)] // a test helper, like draw_with
    fn draw_with_m(
        tr: &Transcript,
        session: &Session,
        composer: &Composer,
        theme: Theme,
        w: u16,
        h: u16,
        view: &mut View,
        motion: bool,
        anim_ms: u64,
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
            turn: 0,
            anim_ms,
            motion,
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
    /// Three finished tool calls that fold into one run, and a line after, so the run is the
    /// block that opens.
    fn run_transcript() -> Transcript {
        let mut tr = Transcript::default();
        for (k, title) in ["Read a", "Read b", "Read c"].into_iter().enumerate() {
            tr.apply(
                SessionUpdate::from_value(
                    &json!({"sessionUpdate": "tool_call", "toolCallId": format!("r{k}"), "title": title, "status": "completed"}),
                )
                .expect("update"),
            );
        }
        agent(&mut tr, "after", "done with the reads");
        tr
    }

    #[test]
    fn opening_a_run_that_shrinks_never_runs_off_its_lines() {
        // The crash: a run opens by folding from its calls to one line, so mid-reveal the easing
        // can ask for more rows than the open run has. The count must cap at the block's real
        // height, and the frame must match a cold build of the same moment.
        let tr = run_transcript();
        let session = ready_session();
        let (w, h) = (100u16, 30u16);
        let rk = tr.items()[0].id | (1u64 << 63); // the run key (the run starts at item 0)
        let mut warm = View::default();
        warm.expanded.insert(rk);
        warm.reveal.insert(rk, 0);
        // A few frames into the unfold, before it settles.
        for anim_ms in [10u64, 40u64, 90u64] {
            let a = rows_of(&draw_with_m(
                &tr,
                &session,
                &Composer::default(),
                Theme::plain(),
                w,
                h,
                &mut warm,
                true,
                anim_ms,
            ));
            let mut cold = View {
                expanded: HashSet::from([rk]),
                reveal: HashMap::from([(rk, 0u64)]),
                ..View::default()
            };
            let b = rows_of(&draw_with_m(
                &tr,
                &session,
                &Composer::default(),
                Theme::plain(),
                w,
                h,
                &mut cold,
                true,
                anim_ms,
            ));
            assert_eq!(
                a, b,
                "the cache changed the reveal frame at anim_ms={anim_ms}"
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
    fn closed_lines_are_kept_per_block_not_shared() {
        // The unfold animation keeps "what the block had before it opened" for each opening
        // block. That was once kept under one shared key, so a block that opened first parked
        // its closed height there, and a second block read the first's. Each block must keep
        // its own: run A has a failed call (taller closed height) than run B, so a block that
        // read the neighbour's height would come back the wrong size.
        let mut tr = Transcript::default();
        for (id, title, status) in [
            ("a0", "Read a", "completed"),
            ("a1", "Read b", "failed"),
            ("a2", "Read c", "completed"),
        ] {
            tr.apply(SessionUpdate::from_value(&json!({"sessionUpdate": "tool_call", "toolCallId": id, "title": title, "status": status})).expect("update"));
        }
        agent(&mut tr, "between", "a line between the two runs");
        for (k, id) in ["b0", "b1", "b2"].into_iter().enumerate() {
            tr.apply(SessionUpdate::from_value(&json!({"sessionUpdate": "tool_call", "toolCallId": id, "title": format!("B {k}"), "status": "completed"})).expect("update"));
        }
        let items = tr.items();
        let run_a = Block::Run {
            start: 0,
            end: 3,
            open: true,
        };
        let run_b = Block::Run {
            start: 4,
            end: 7,
            open: true,
        };
        let mut cache = LineCache::default();
        let look = Look {
            expanded: &HashSet::new(),
            focus: None,
            thoughts: false,
            theme: Theme::plain(),
        };
        let wa = cache.closed_lines(run_a, items, 100, &HashSet::new(), look);
        let wb = cache.closed_lines(run_b, items, 100, &HashSet::new(), look);
        assert_ne!(
            wa.len(),
            wb.len(),
            "the two runs should have different closed heights: A={} B={}",
            wa.len(),
            wb.len()
        );
        // Reading A again must give A's height, not the B that was parked in between.
        let wa2 = cache.closed_lines(run_a, items, 100, &HashSet::new(), look);
        assert_eq!(
            wa2.len(),
            wa.len(),
            "A read B's closed height after B opened"
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
        let rows = agent_lines("one two three four five six seven", 14, Theme::plain());
        let text: Vec<String> = rows
            .iter()
            .map(|l| l.spans.iter().map(|s| s.content.as_ref()).collect())
            .collect();
        assert!(text[0].starts_with("• "), "{text:?}");
        assert!(text[1..].iter().all(|r| r.starts_with("  ")), "{text:?}");
        assert!(text.iter().all(|r| width_of(r) <= 14));
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
        assert_eq!(text, "✓ git status --short");
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
    fn the_context_gauge_warns_as_the_window_fills() {
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
        let (calm, hot, full) = (colour(40), colour(70), colour(95));
        assert_ne!(calm, hot);
        assert_ne!(hot, full);
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
        assert!(text.contains("Tab chooses · Enter confirms"), "{text}");
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
    fn the_rule_carries_the_title_and_the_footer_says_where_and_how_full() {
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
            rows.iter().any(|r| r.contains("─ Fix the flaky test ──")),
            "{rows:#?}"
        );
        assert!(rows.last().is_some_and(|r| r.starts_with("  Enter send") && r.ends_with("omp · /w · plan · ctx 47%")), "one footer row: the hint on the left, where it runs and how full on the right: {rows:#?}");
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
            80,
            12,
            &mut view,
        ));
        assert!(
            rows.last().is_some_and(|r| r.starts_with("  Enter send")
                && r.ends_with("Sonnet 5.5 · thinking high · ctx 47%")),
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
                .is_some_and(|r| r.ends_with("ctx 47%") && width_of(r) <= 30),
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
            turn: 0,
            anim_ms: 0,
            motion: false,
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
    fn draw_anim(
        tr: &Transcript,
        session: &Session,
        theme: Theme,
        w: u16,
        h: u16,
        view: &mut View,
        anim_ms: u64,
        motion: bool,
    ) -> Buffer {
        let mut term = Terminal::new(TestBackend::new(w, h)).expect("a test terminal");
        let composer = Composer::default();
        let ctx = Frame_ {
            transcript: tr,
            session,
            composer: &composer,
            header: Header {
                agent: "omp",
                cwd: "/w",
            },
            theme,
            hint: None,
            working_secs: Some(3),
            turn: 0,
            anim_ms,
            motion,
        };
        term.draw(|f| draw(f, &ctx, view)).expect("drawn");
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

    fn row_with(buf: &Buffer, needle: &str) -> Option<u16> {
        rows_of(buf)
            .iter()
            .position(|r| r.contains(needle))
            .map(|i| i as u16)
    }

    #[test]
    fn the_spinner_turns_with_the_clock_and_stands_still_without_motion() {
        let (tr, session) = (working(), ready_session());
        let status = |ms: u64, motion: bool| {
            let buf = draw_anim(
                &tr,
                &session,
                Theme::plain(),
                70,
                10,
                &mut View::default(),
                ms,
                motion,
            );
            let row = row_with(&buf, "Ctrl-C stops").expect("the working line");
            rows_of(&buf)[usize::from(row)].clone()
        };
        let (a, b) = (status(0, true), status(90, true));
        assert_ne!(a, b, "the spinner moved");
        assert_eq!(
            a.chars().skip(3).collect::<String>(),
            b.chars().skip(3).collect::<String>(),
            "only the spinner changed, the words did not"
        );
        assert_eq!(
            status(0, false),
            status(5000, false),
            "no motion: a still dot"
        );
        assert!(status(0, false).trim_start().starts_with('●'));
    }

    #[test]
    fn a_sheen_lights_a_few_letters_of_the_word_and_never_the_whole_of_it() {
        let (tr, session) = (working(), ready_session());
        let verb_len = format!("{}…", delight::verb(3, 0)).chars().count();
        let theme = Theme::banded((255, 255, 255));
        let mut saw_lit = false;
        for ms in (0..3000).step_by(70) {
            let buf = draw_anim(&tr, &session, theme, 80, 10, &mut View::default(), ms, true);
            let row = row_with(&buf, "Ctrl-C stops").expect("the working line");
            let colours: Vec<Color> = (2..2 + verb_len as u16).map(|x| buf[(x, row)].fg).collect();
            let lit = colours
                .iter()
                .filter(|c| **c == theme.accent().fg.expect("an accent"))
                .count();
            assert!(lit < verb_len, "the sheen is never the whole word");
            saw_lit |= lit > 0;
        }
        assert!(saw_lit, "and it does cross the word");
    }

    #[test]
    fn the_needs_you_mark_pulses_and_holds_still_without_motion() {
        let mut session = ready_session();
        let mut scratch = Transcript::default();
        session.handle(
            crate::session::Event::Message(ask(
                json!([{"optionId": "a", "name": "Allow once", "kind": "allow_once"}]),
            )),
            0,
            &mut scratch,
        );
        let text = |ms: u64, motion: bool| {
            rows_of(&draw_anim(
                &Transcript::default(),
                &session,
                Theme::plain(),
                70,
                24,
                &mut View::default(),
                ms,
                motion,
            ))
            .join("\n")
        };
        assert!(
            text(0, true).contains("▲ Needs you") && text(600, true).contains("△ Needs you"),
            "it pulses"
        );
        assert!(
            text(600, false).contains("▲ Needs you") && !text(600, false).contains("△"),
            "and holds still when motion is off"
        );
    }

    fn foldable_output() -> Transcript {
        let mut tr = Transcript::default();
        tr.apply(SessionUpdate::from_value(&json!({"sessionUpdate": "tool_call", "toolCallId": "t", "title": "Run build", "status": "completed",
            "content": [{"type": "content", "content": {"type": "text", "text": "out-1\nout-2\nout-3\nout-4"}}]})).expect("update"));
        agent(&mut tr, "m", "done");
        tr
    }

    #[test]
    fn an_opened_block_grows_into_place_and_the_loop_is_told_when_it_is_done() {
        let tr = foldable_output();
        let session = ready_session();
        let id = tr.items()[0].id;
        let frame = |ms: u64, motion: bool, view: &mut View| {
            rows_of(&draw_anim(
                &tr,
                &session,
                Theme::plain(),
                60,
                16,
                view,
                ms,
                motion,
            ))
            .join("\n")
        };
        let opening = |view: &mut View| {
            view.expanded.insert(id);
            view.reveal.insert(id, 0);
        };
        let mut view = View::default();
        opening(&mut view);
        assert!(
            !frame(0, true, &mut view).contains("out-4"),
            "it starts at the height it had"
        );
        assert!(
            !view.reveal.is_empty(),
            "and the loop keeps drawing while it grows"
        );
        assert!(
            frame(delight::REVEAL_MS, true, &mut view).contains("out-4"),
            "it ends whole"
        );
        assert!(view.reveal.is_empty(), "then the loop can sleep again");
        // Without motion it is simply open.
        let mut still = View::default();
        opening(&mut still);
        assert!(frame(0, false, &mut still).contains("out-4"));
        assert!(still.reveal.is_empty());
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
                &json!({"sessionUpdate": "usage_update", "used": 1, "size": 100}),
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
                && last.contains("ctx 1%")
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
        let ready = text.find("Ready when you are.").expect("the greeting");
        let tip = text.find("Tip:").expect("the tip");
        assert!(
            ready < tip,
            "the greeting sits above the tip, not below it: {text}"
        );
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
