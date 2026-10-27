//! Markdown to styled, wrapped terminal lines.
//!
//! Headings keep their `#` signs, inline code is accented, code blocks sit
//! behind a quiet gutter and are never reflowed, lists hang their wrapped
//! lines under the text, and a table that fits is aligned (otherwise it is
//! listed row by row). Everything is wrapped to the width given, by display
//! width, so wide characters never overflow a row.

use crate::theme::Theme;
use crate::width;
use acp::is_unsafe_control;
use pulldown_cmark::{Alignment, CodeBlockKind, Event, HeadingLevel, Options, Parser, Tag, TagEnd};
use ratatui::{
    style::{Modifier, Style},
    text::{Line, Span},
};

/// `text` without the characters a terminal would act on (newlines and tabs stay), and without
/// the joiners and variation selectors terminals disagree about: `⚠️` (a symbol and U+FE0F) is
/// two columns in a terminal that honours the selector and one in one that does not, and the
/// screen is only right when every row is as wide as the terminal draws it. Without them the
/// symbol is one column everywhere and a joined emoji is the emoji it joins, side by side.
#[must_use]
pub fn clean(text: &str) -> String {
    text.chars()
        .filter(|c| !is_unsafe_control(*c) || *c == '\n' || *c == '\t')
        .filter(|c| !matches!(c, '\u{fe0e}' | '\u{fe0f}' | '\u{200d}'))
        .collect()
}

/// `text` as one line that is safe to hand the terminal outside the interface (the window title, a
/// message printed after leaving): every control character becomes a space, bidirectional
/// overrides are dropped, and it is cut to `max` characters.
#[must_use]
pub fn one_line(text: &str, max: usize) -> String {
    let spaced: String = text
        .chars()
        .filter(|c| !is_bidi(*c))
        .map(|c| if c.is_control() { ' ' } else { c })
        .collect();
    spaced.trim().chars().take(max).collect()
}

fn is_bidi(c: char) -> bool {
    matches!(c, '\u{200e}' | '\u{200f}' | '\u{202a}'..='\u{202e}' | '\u{2066}'..='\u{2069}' | '\u{61c}')
}

fn width_of(s: &str) -> usize {
    width::of(s)
}

/// One paragraph-like run of text and the prefixes its lines wear.
struct Flow {
    first: Vec<Span<'static>>,
    rest: Vec<Span<'static>>,
    body: Vec<Span<'static>>,
}

fn prefix_width(p: &[Span]) -> usize {
    p.iter().map(|s| width_of(&s.content)).sum()
}

/// Wraps a flow to `width`, word by word, keeping each word's style. Never narrower than 8
/// columns: prose squeezed thinner than that reads as noise.
fn wrap_flow(flow: &Flow, width: usize) -> Vec<Line<'static>> {
    wrap_flow_at(flow, width.max(8))
}

/// [`wrap_flow`] at exactly `width` columns (at least one), for a table cell.
fn wrap_flow_at(flow: &Flow, width: usize) -> Vec<Line<'static>> {
    let width = width.max(1);
    let mut lines: Vec<Line<'static>> = Vec::new();
    let mut cur: Vec<Span<'static>> = flow.first.clone();
    let mut w = prefix_width(&flow.first);
    let rest_w = prefix_width(&flow.rest);
    let mut at_start = true;
    // Spans at the end of `cur` that make one word with no space between them (`code`, then a
    // comma), and how many spans of `cur` are the row's prefix: a word is wrapped whole, so a
    // comma never starts a row on its own.
    let mut glued = 0usize;
    let mut lead = flow.first.len();
    let newline = |cur: &mut Vec<Span<'static>>,
                   w: &mut usize,
                   lines: &mut Vec<Line<'static>>,
                   at_start: &mut bool| {
        lines.push(Line::from(std::mem::replace(cur, flow.rest.clone())));
        *w = rest_w;
        *at_start = true;
    };
    for span in &flow.body {
        // A hard break is carried as a lone newline span.
        if span.content == "\n" {
            newline(&mut cur, &mut w, &mut lines, &mut at_start);
            glued = 0;
            lead = flow.rest.len();
            continue;
        }
        for token in split_keep_spaces(&span.content) {
            let tw = width_of(token);
            let is_space = token.chars().all(char::is_whitespace);
            if is_space {
                if !at_start && w + tw <= width {
                    cur.push(Span::styled(token.to_string(), span.style));
                    w += tw;
                }
                glued = 0;
                continue;
            }
            if w + tw > width && !at_start {
                // The start of this word, when it began in an earlier span, moves down with it.
                let mut carried = Vec::new();
                if glued > 0 && cur.len() - glued > lead {
                    let tail = cur.split_off(cur.len() - glued);
                    let tail_w = prefix_width(&tail);
                    if rest_w + tail_w + tw <= width {
                        w -= tail_w;
                        carried = tail;
                    } else {
                        cur.extend(tail);
                    }
                }
                // Do not carry the space that ended the previous row.
                if cur
                    .last()
                    .is_some_and(|s| s.content.chars().all(char::is_whitespace))
                {
                    cur.pop();
                }
                newline(&mut cur, &mut w, &mut lines, &mut at_start);
                lead = flow.rest.len();
                glued = carried.len();
                if !carried.is_empty() {
                    w += prefix_width(&carried);
                    cur.extend(carried);
                    at_start = false;
                }
            }
            if tw > width.saturating_sub(w) {
                // A word longer than a row: cut it by display width.
                let mut piece = String::new();
                let mut pw = 0;
                for (g, cw) in width::clusters(token) {
                    if w + pw + cw > width && !piece.is_empty() {
                        cur.push(Span::styled(std::mem::take(&mut piece), span.style));
                        newline(&mut cur, &mut w, &mut lines, &mut at_start);
                        pw = 0;
                    }
                    piece.push_str(g);
                    pw += cw;
                }
                cur.push(Span::styled(piece, span.style));
                w += pw;
                glued = 1;
                lead = cur.len() - 1;
            } else {
                cur.push(Span::styled(token.to_string(), span.style));
                w += tw;
                glued += 1;
            }
            at_start = false;
        }
    }
    if cur
        .last()
        .is_some_and(|s| s.content.chars().all(char::is_whitespace))
        && cur.len() > flow.first.len().min(cur.len())
    {
        cur.pop();
    }
    lines.push(Line::from(cur));
    lines
}

/// Splits into alternating runs of non-space and space characters.
fn split_keep_spaces(s: &str) -> Vec<&str> {
    let mut out = Vec::new();
    let mut start = 0;
    let mut prev: Option<bool> = None;
    for (i, c) in s.char_indices() {
        let sp = c.is_whitespace();
        if prev.is_some_and(|p| p != sp) {
            out.push(&s[start..i]);
            start = i;
        }
        prev = Some(sp);
    }
    if start < s.len() {
        out.push(&s[start..]);
    }
    out
}

/// Wraps styled `body` to `width`, the first row led by `first` and the others by `rest`.
#[must_use]
pub fn wrap_spans(
    body: Vec<Span<'static>>,
    first: Vec<Span<'static>>,
    rest: Vec<Span<'static>>,
    width: usize,
) -> Vec<Line<'static>> {
    wrap_flow(&Flow { first, rest, body }, width)
}

struct ListCtx {
    next: Option<u64>,
    /// Columns the widest number of an ordered list takes.
    digits: usize,
}

/// How many items the list whose events start at `events` has (its own, not nested lists').
fn items_in(events: &[Event]) -> usize {
    let mut depth = 0usize;
    let mut n = 0;
    for ev in events {
        match ev {
            Event::Start(Tag::List(_)) => depth += 1,
            Event::End(TagEnd::List(_)) if depth == 0 => break,
            Event::End(TagEnd::List(_)) => depth -= 1,
            Event::Start(Tag::Item) if depth == 0 => n += 1,
            _ => {}
        }
    }
    n
}

/// One table cell: its text, with the inline styles it was written with (code, bold, a link).
type Cell = Vec<Span<'static>>;

struct Table {
    aligns: Vec<Alignment>,
    rows: Vec<Vec<Cell>>,
    head_rows: usize,
    cell: Cell,
    row: Vec<Cell>,
}

/// [`render`] for a message that is still arriving. A table is held back until it is whole: its
/// header would first read as a line of pipes, and every row that lands would re-measure the
/// columns and shift the box under the reader's eyes. In its place, one quiet line says it is
/// coming and how far it has got. Everything else shows as it arrives.
#[must_use]
pub fn render_live(text: &str, width: usize, theme: Theme) -> Vec<Line<'static>> {
    let Some((before, rows)) = table_in_progress(text) else {
        return render(text, width, theme);
    };
    let mut out = render(before, width, theme);
    if !out.is_empty() {
        out.push(Line::default());
    }
    let what = match rows {
        0 => "… a table".to_string(),
        1 => "… a table, 1 row so far".to_string(),
        n => format!("… a table, {n} rows so far"),
    };
    out.push(Line::from(Span::styled(what, theme.dim())));
    out
}

fn is_table_line(line: &str) -> bool {
    line.trim_start().starts_with('|')
}

fn is_fence(line: &str) -> bool {
    let t = line.trim_start();
    t.starts_with("```") || t.starts_with("~~~")
}

/// When `text` ends inside a table (its last line, finished or not, is a row: a table runs to a
/// blank line), the text before the table and how many rows it has (the `|---|` line is not a
/// row). Not inside a code block, where a `|` is only a character.
fn table_in_progress(text: &str) -> Option<(&str, usize)> {
    let lines: Vec<&str> = text.split_inclusive('\n').collect();
    let last = lines.iter().rposition(|l| !l.trim().is_empty())?;
    // A blank line after the last row ended the table.
    if last + 1 < lines.len() {
        return None;
    }
    if !is_table_line(lines[last]) {
        return None;
    }
    let start = lines[..=last]
        .iter()
        .rposition(|l| !is_table_line(l))
        .map_or(0, |i| i + 1);
    if lines[..start].iter().filter(|l| is_fence(l)).count() % 2 == 1 {
        return None;
    }
    let rows = lines[start..=last]
        .iter()
        .filter(|l| {
            !l.chars()
                .all(|c| matches!(c, '|' | '-' | ':' | ' ' | '\n' | '\t'))
        })
        .count()
        .saturating_sub(1);
    let at: usize = lines[..start].iter().map(|l| l.len()).sum();
    Some((&text[..at], rows))
}

/// Renders markdown. Output lines are at most `width` columns wide.
#[must_use]
pub fn render(text: &str, width: usize, theme: Theme) -> Vec<Line<'static>> {
    let text = clean(text);
    let mut opts = Options::empty();
    opts.insert(Options::ENABLE_TABLES);
    opts.insert(Options::ENABLE_STRIKETHROUGH);
    let mut out: Vec<Line<'static>> = Vec::new();
    let mut style_stack: Vec<Style> = vec![Style::default()];
    let mut body: Vec<Span<'static>> = Vec::new();
    let mut lists: Vec<ListCtx> = Vec::new();
    // Prefixes of the open containers: (first-line prefix, continuation prefix).
    let mut quote_depth = 0usize;
    let mut item_prefix: Option<(String, String)> = None;
    let mut heading: Option<HeadingLevel> = None;
    let mut code: Option<(String, String)> = None;
    let mut table: Option<Table> = None;
    // The open links: where each goes, and where its label starts in `body`.
    let mut links: Vec<(String, usize)> = Vec::new();
    let mut gap_pending = false;

    let quote_prefix = |depth: usize| -> Vec<Span<'static>> {
        (0..depth)
            .map(|_| Span::styled("│ ", theme.dim()))
            .collect()
    };

    macro_rules! flush {
        () => {{
            if !body.is_empty() || item_prefix.is_some() {
                let indent: String = " ".repeat(lists.len().saturating_sub(1) * 2);
                let mut first = quote_prefix(quote_depth);
                let mut rest = quote_prefix(quote_depth);
                match item_prefix.take() {
                    Some((f, r)) => {
                        first.push(Span::raw(format!("{indent}{f}")));
                        rest.push(Span::raw(format!("{indent}{r}")));
                    }
                    None if !lists.is_empty() => {
                        let pad = " ".repeat(lists.len() * 2);
                        rest.push(Span::raw(pad.clone()));
                        first.push(Span::raw(pad));
                    }
                    None => {}
                }
                if !body.is_empty() {
                    if std::mem::take(&mut gap_pending) && !out.is_empty() {
                        out.push(Line::default());
                    }
                    out.extend(wrap_flow(
                        &Flow {
                            first,
                            rest,
                            body: std::mem::take(&mut body),
                        },
                        width,
                    ));
                }
            }
        }};
    }

    // Held whole so a list can look ahead to its last number; each event is taken out as it is
    // handled (what is left behind is never read again), so nothing is copied.
    let mut events: Vec<Event> = Parser::new_ext(&text, opts).collect();
    for at in 0..events.len() {
        let ev = std::mem::replace(&mut events[at], Event::Rule);
        if let Some(t) = table.as_mut() {
            match &ev {
                Event::Text(s) => t.cell.push(Span::styled(s.to_string(), top(&style_stack))),
                Event::Code(s) => t.cell.push(Span::styled(
                    s.to_string(),
                    theme.code().patch(top(&style_stack)),
                )),
                Event::SoftBreak | Event::HardBreak => t.cell.push(Span::raw(" ")),
                Event::Start(Tag::Emphasis) => {
                    style_stack.push(top(&style_stack).add_modifier(Modifier::ITALIC))
                }
                Event::Start(Tag::Strong) => {
                    style_stack.push(top(&style_stack).add_modifier(Modifier::BOLD))
                }
                Event::Start(Tag::Strikethrough) => {
                    style_stack.push(top(&style_stack).add_modifier(Modifier::CROSSED_OUT))
                }
                Event::Start(Tag::Link { .. }) => {
                    style_stack.push(top(&style_stack).add_modifier(Modifier::UNDERLINED))
                }
                Event::End(
                    TagEnd::Emphasis | TagEnd::Strong | TagEnd::Strikethrough | TagEnd::Link,
                ) => {
                    style_stack.pop();
                }
                Event::End(TagEnd::TableCell) => t.row.push(trim_cell(std::mem::take(&mut t.cell))),
                Event::End(TagEnd::TableHead) => {
                    t.rows.push(std::mem::take(&mut t.row));
                    t.head_rows = t.rows.len();
                }
                Event::End(TagEnd::TableRow) => t.rows.push(std::mem::take(&mut t.row)),
                Event::End(TagEnd::Table) => {
                    if std::mem::take(&mut gap_pending) && !out.is_empty() {
                        out.push(Line::default());
                    }
                    if let Some(t) = table.take() {
                        out.extend(render_table(&t, width, theme));
                    }
                    gap_pending = true;
                }
                _ => {}
            }
            continue;
        }
        match ev {
            Event::Start(Tag::Paragraph) => {}
            Event::End(TagEnd::Paragraph) => {
                flush!();
                gap_pending = true;
            }
            Event::Start(Tag::Heading { level, .. }) => {
                heading = Some(level);
                style_stack.push(theme.bold());
                let hashes = "#".repeat(level as usize);
                body.push(Span::styled(format!("{hashes} "), theme.dim()));
            }
            Event::End(TagEnd::Heading(_)) => {
                style_stack.pop();
                heading = None;
                flush!();
                gap_pending = true;
            }
            Event::Start(Tag::BlockQuote(_)) => {
                flush!();
                quote_depth += 1;
            }
            Event::End(TagEnd::BlockQuote(_)) => {
                flush!();
                quote_depth = quote_depth.saturating_sub(1);
                gap_pending = true;
            }
            Event::Start(Tag::List(start)) => {
                flush!();
                // Numbers line up on the right, `9.` under `10.`, so every item's text starts in
                // one column: the widest number the list reaches sets the width.
                let digits = start.map_or(0, |n| {
                    let last = n + items_in(&events[at + 1..]).saturating_sub(1) as u64;
                    last.to_string().len()
                });
                lists.push(ListCtx {
                    next: start,
                    digits,
                });
            }
            Event::End(TagEnd::List(_)) => {
                flush!();
                lists.pop();
                if lists.is_empty() {
                    gap_pending = true;
                }
            }
            Event::Start(Tag::Item) => {
                flush!();
                let marker = match lists.last_mut() {
                    Some(ListCtx {
                        next: Some(n),
                        digits,
                    }) => {
                        let m = format!("{n:>w$}. ", w = *digits);
                        *n += 1;
                        m
                    }
                    _ => "• ".to_string(),
                };
                let rest = " ".repeat(width_of(&marker));
                item_prefix = Some((marker, rest));
            }
            Event::End(TagEnd::Item) => flush!(),
            Event::Start(Tag::CodeBlock(kind)) => {
                flush!();
                let lang = match kind {
                    CodeBlockKind::Fenced(l) => {
                        l.split_whitespace().next().unwrap_or("").to_string()
                    }
                    CodeBlockKind::Indented => String::new(),
                };
                code = Some((lang, String::new()));
            }
            Event::End(TagEnd::CodeBlock) => {
                if let Some((lang, text)) = code.take() {
                    if std::mem::take(&mut gap_pending) && !out.is_empty() {
                        out.push(Line::default());
                    }
                    out.extend(render_code(&text, &lang, width, quote_depth, theme));
                    gap_pending = true;
                }
            }
            Event::Start(Tag::Table(aligns)) => {
                flush!();
                table = Some(Table {
                    aligns,
                    rows: Vec::new(),
                    head_rows: 0,
                    cell: Vec::new(),
                    row: Vec::new(),
                });
            }
            Event::Start(Tag::Emphasis) => {
                style_stack.push(top(&style_stack).add_modifier(Modifier::ITALIC))
            }
            Event::Start(Tag::Strong) => {
                style_stack.push(top(&style_stack).add_modifier(Modifier::BOLD))
            }
            Event::Start(Tag::Strikethrough) => {
                style_stack.push(top(&style_stack).add_modifier(Modifier::CROSSED_OUT))
            }
            Event::Start(Tag::Link { dest_url, .. }) => {
                style_stack.push(top(&style_stack).add_modifier(Modifier::UNDERLINED));
                links.push((dest_url.to_string(), body.len()));
            }
            Event::End(TagEnd::Link) => {
                style_stack.pop();
                // A label never hides where it goes: the person can read or copy the address.
                if let Some((dest, from)) = links.pop() {
                    let label: String = body[from.min(body.len())..]
                        .iter()
                        .map(|s| s.content.as_ref())
                        .collect();
                    if shows_destination(&label, &dest) {
                        body.push(Span::styled(format!(" ({dest})"), theme.dim()));
                    }
                }
            }
            Event::End(TagEnd::Emphasis | TagEnd::Strong | TagEnd::Strikethrough) => {
                style_stack.pop();
            }
            Event::Text(s) => match code.as_mut() {
                Some((_, buf)) => buf.push_str(&s),
                None => body.push(Span::styled(s.to_string(), top(&style_stack))),
            },
            Event::Code(s) => body.push(Span::styled(
                s.to_string(),
                theme.code().patch(top(&style_stack)),
            )),
            Event::SoftBreak => body.push(Span::styled(" ", top(&style_stack))),
            Event::HardBreak => body.push(Span::raw("\n")),
            Event::Rule => {
                flush!();
                if std::mem::take(&mut gap_pending) && !out.is_empty() {
                    out.push(Line::default());
                }
                out.push(Line::from(Span::styled(
                    "─".repeat(width.min(48)),
                    theme.faint(),
                )));
                gap_pending = true;
            }
            Event::Html(s) | Event::InlineHtml(s) => {
                body.push(Span::styled(s.to_string(), theme.dim()))
            }
            Event::TaskListMarker(done) => body.push(Span::raw(if done { "☑ " } else { "☐ " })),
            _ => {}
        }
    }
    let _ = heading;
    flush!();
    out
}

/// Whether a link's destination is worth printing after its label: not when the label already is
/// the address (an autolink, a bare `mailto:`), nor for an anchor inside the same text.
fn shows_destination(label: &str, dest: &str) -> bool {
    let label = label.trim();
    let bare = dest
        .strip_prefix("mailto:")
        .or_else(|| dest.strip_prefix("https://"))
        .or_else(|| dest.strip_prefix("http://"))
        .unwrap_or(dest);
    !dest.is_empty() && !dest.starts_with('#') && label != dest && label != bare
}

fn top(stack: &[Style]) -> Style {
    stack.last().copied().unwrap_or_default()
}

fn render_code(
    text: &str,
    lang: &str,
    width: usize,
    quote_depth: usize,
    theme: Theme,
) -> Vec<Line<'static>> {
    let gutter = "▏ ";
    let lead = "│ ".repeat(quote_depth);
    let inner = width
        .saturating_sub(width_of(gutter) + width_of(&lead))
        .max(4);
    let mut out = Vec::new();
    if !lang.is_empty() {
        out.push(Line::from(vec![
            Span::styled(lead.clone(), theme.dim()),
            Span::styled(format!("{gutter}{lang}"), theme.dim()),
        ]));
    }
    // Tabs become four spaces; a line without one is borrowed, not copied.
    let raw: Vec<std::borrow::Cow<str>> = text
        .trim_end_matches('\n')
        .split('\n')
        .map(|l| {
            if l.contains('\t') {
                l.replace('\t', "    ").into()
            } else {
                l.into()
            }
        })
        .collect();
    let refs: Vec<&str> = raw.iter().map(AsRef::as_ref).collect();
    let coloured = crate::highlight::lines(lang, &refs, theme).unwrap_or_else(|| {
        refs.iter()
            .map(|l| vec![Span::styled((*l).to_string(), theme.code())])
            .collect()
    });
    let mark = format!("{lead}{gutter}");
    for spans in coloured {
        // Code is never reflowed; a line longer than the row continues on the next.
        for row in cut_spans(spans, inner) {
            let mut line = Vec::with_capacity(row.len() + 1);
            line.push(Span::styled(mark.clone(), theme.dim()));
            line.extend(row);
            out.push(Line::from(line));
        }
    }
    out
}

/// `spans` cut into rows of at most `width` columns, each piece keeping its style. An empty line
/// is one empty row.
pub fn cut_spans(spans: Vec<Span<'static>>, width: usize) -> Vec<Vec<Span<'static>>> {
    let width = width.max(1);
    let mut rows = vec![Vec::with_capacity(spans.len())];
    let mut w = 0;
    for span in spans {
        // Most spans fit whole on the row they start on: kept as they are, nothing copied.
        let sw = width_of(&span.content);
        if w + sw <= width {
            w += sw;
            rows.last_mut().expect("a row").push(span);
            continue;
        }
        let mut piece = String::new();
        for (g, cw) in width::clusters(&span.content) {
            if w + cw > width {
                if !piece.is_empty() {
                    rows.last_mut()
                        .expect("a row")
                        .push(Span::styled(std::mem::take(&mut piece), span.style));
                }
                rows.push(Vec::new());
                w = 0;
            }
            piece.push_str(g);
            w += cw;
        }
        if !piece.is_empty() {
            rows.last_mut()
                .expect("a row")
                .push(Span::styled(piece, span.style));
        }
    }
    rows
}

/// Cells of a column this wide or less keep their natural width when the table is squeezed.
const SHORT_CELL: usize = 10;
/// Columns wider than that may wrap, but no narrower than this.
const MIN_WRAPPED: usize = 4;
/// A column whose cells average this many words is prose, and never squeezed below PROSE_MIN.
const PROSE_WORDS: usize = 4;
const PROSE_MIN: usize = 16;
/// Columns a table's box takes besides its cells: a bar and a space either side of every cell,
/// with the bars between two cells shared.
fn box_width(cols: usize) -> usize {
    3 * cols + 1
}
/// A label column on a record card is never wider than this.
const LABEL_MAX: usize = 16;

/// Plain word-wrap of one cell by display width (a word longer than the width is cut).
fn wrap_plain(text: &str, width: usize) -> Vec<String> {
    let width = width.max(1);
    let mut lines = Vec::new();
    let mut cur = String::new();
    let mut w = 0;
    for word in text.split_whitespace() {
        let ww = width_of(word);
        if !cur.is_empty() && w + 1 + ww <= width {
            cur.push(' ');
            cur.push_str(word);
            w += 1 + ww;
            continue;
        }
        if !cur.is_empty() {
            lines.push(std::mem::take(&mut cur));
            w = 0;
        }
        for (g, cw) in width::clusters(word) {
            if w + cw > width {
                lines.push(std::mem::take(&mut cur));
                w = 0;
            }
            cur.push_str(g);
            w += cw;
        }
    }
    lines.push(cur);
    lines
}

/// A cell without the blanks around its text.
fn trim_cell(mut cell: Cell) -> Cell {
    if let Some(first) = cell.first_mut() {
        first.content = first.content.trim_start().to_string().into();
    }
    if let Some(last) = cell.last_mut() {
        last.content = last.content.trim_end().to_string().into();
    }
    cell.retain(|s| !s.content.is_empty());
    cell
}

fn plain(cell: &[Span]) -> String {
    cell.iter().map(|s| s.content.as_ref()).collect()
}

/// Whether a cell reads as a number (`12`, `+6 -2`, `1.5%`, `$3`), so its column lines up on
/// the right the way figures are compared.
fn numeric(text: &str) -> bool {
    text.chars().any(|c| c.is_ascii_digit())
        && text
            .chars()
            .all(|c| c.is_ascii_digit() || " +-−.,%$€£×".contains(c))
}

/// The alignment each column is drawn with: what the table asked for, and on the right for a
/// column of figures that asked for nothing.
fn column_aligns(rows: &[Vec<Cell>], t: &Table, cols: usize) -> Vec<Alignment> {
    (0..cols)
        .map(|i| match t.aligns.get(i) {
            Some(a) if *a != Alignment::None => *a,
            _ => {
                let mut body = rows.iter().skip(t.head_rows).map(|r| plain(&r[i]));
                let mut any = false;
                let figures = body.all(|c| {
                    let c = c.trim();
                    any |= !c.is_empty();
                    c.is_empty() || numeric(c)
                });
                if figures && any {
                    Alignment::Right
                } else {
                    Alignment::None
                }
            }
        })
        .collect()
}

/// A cell's styled text wrapped to its column, one row per line.
fn wrap_cell(cell: &Cell, width: usize) -> Vec<Vec<Span<'static>>> {
    wrap_flow_at(
        &Flow {
            first: Vec::new(),
            rest: Vec::new(),
            body: cell.clone(),
        },
        width,
    )
    .into_iter()
    .map(|l| l.spans)
    .collect()
}

/// `spans` padded to `width` by `align`.
fn align_spans(spans: Vec<Span<'static>>, width: usize, align: Alignment) -> Vec<Span<'static>> {
    let pad = width.saturating_sub(prefix_width(&spans));
    let (l, r) = match align {
        Alignment::Right => (pad, 0),
        Alignment::Center => (pad / 2, pad - pad / 2),
        _ => (0, pad),
    };
    let mut out = Vec::with_capacity(spans.len() + 2);
    if l > 0 {
        out.push(Span::raw(" ".repeat(l)));
    }
    out.extend(spans);
    if r > 0 {
        out.push(Span::raw(" ".repeat(r)));
    }
    out
}

fn render_table(t: &Table, width: usize, theme: Theme) -> Vec<Line<'static>> {
    let cols = t.rows.iter().map(Vec::len).max().unwrap_or(0);
    if cols == 0 {
        return Vec::new();
    }
    let rows: Vec<Vec<Cell>> = t
        .rows
        .iter()
        .map(|r| {
            (0..cols)
                .map(|i| r.get(i).cloned().unwrap_or_default())
                .collect()
        })
        .collect();
    let natural: Vec<usize> = (0..cols)
        .map(|i| rows.iter().map(|r| prefix_width(&r[i])).max().unwrap_or(0))
        .collect();
    let aligns = column_aligns(&rows, t, cols);
    let chrome = box_width(cols);
    if natural.iter().sum::<usize>() + chrome <= width {
        return grid(&rows, t, &natural, &aligns, theme);
    }
    // Squeezed: short columns keep their width, long ones may wrap down to their longest word,
    // and a column of sentences no narrower than PROSE_MIN: prose a few words wide is a column of
    // fragments, and reads better as one card per row.
    let min: Vec<usize> = (0..cols)
        .map(|i| {
            if natural[i] <= SHORT_CELL {
                return natural[i];
            }
            let texts: Vec<String> = rows
                .iter()
                .skip(t.head_rows)
                .map(|r| plain(&r[i]))
                .collect();
            let word = rows
                .iter()
                .map(|r| plain(&r[i]))
                .flat_map(|c| c.split_whitespace().map(width_of).collect::<Vec<_>>())
                .max()
                .unwrap_or(0);
            let filled = texts.iter().filter(|c| !c.trim().is_empty()).count().max(1);
            let words: usize = texts.iter().map(|c| c.split_whitespace().count()).sum();
            let floor = if words >= PROSE_WORDS * filled {
                PROSE_MIN
            } else {
                MIN_WRAPPED
            };
            word.clamp(floor, floor.max(12)).min(natural[i])
        })
        .collect();
    let avail = width.saturating_sub(chrome);
    if min.iter().sum::<usize>() > avail {
        return cards(&rows, t, width, theme);
    }
    // Give what is left to the column that most wants it, one column at a time.
    let mut widths = min;
    let mut spare = avail - widths.iter().sum::<usize>();
    while spare > 0 {
        let Some(i) = (0..cols)
            .filter(|i| widths[*i] < natural[*i])
            .max_by_key(|i| natural[*i] - widths[*i])
        else {
            break;
        };
        widths[i] += 1;
        spare -= 1;
    }
    grid(&rows, t, &widths, &aligns, theme)
}

/// The table as a box of connected lines: rounded corners, a bar between columns, a rule under
/// the header and, when a cell wraps, between rows (so a row's second line never reads as the next
/// row). The lines are faint, so the box frames the text without competing with it.
fn grid(
    rows: &[Vec<Cell>],
    t: &Table,
    widths: &[usize],
    aligns: &[Alignment],
    theme: Theme,
) -> Vec<Line<'static>> {
    let wrapped: Vec<Vec<Vec<Vec<Span<'static>>>>> = rows
        .iter()
        .map(|r| {
            r.iter()
                .enumerate()
                .map(|(i, c)| wrap_cell(c, widths[i]))
                .collect()
        })
        .collect();
    let any_wrapped = wrapped
        .iter()
        .skip(t.head_rows)
        .any(|r| r.iter().any(|c| c.len() > 1));
    let line = theme.faint();
    let rule = |left: &str, join: &str, right: &str| -> Line<'static> {
        let mut s = String::from(left);
        for (i, w) in widths.iter().enumerate() {
            if i > 0 {
                s.push_str(join);
            }
            s.push_str(&"─".repeat(w + 2));
        }
        s.push_str(right);
        Line::from(Span::styled(s, line))
    };
    let mut out = vec![rule("╭", "┬", "╮")];
    for (r, cells) in wrapped.iter().enumerate() {
        let height = cells.iter().map(Vec::len).max().unwrap_or(1);
        let head = r < t.head_rows;
        for k in 0..height {
            let mut spans = vec![Span::styled("│ ", line)];
            for (i, w) in widths.iter().enumerate() {
                if i > 0 {
                    spans.push(Span::styled(" │ ", line));
                }
                let mut text = cells[i].get(k).cloned().unwrap_or_default();
                if head {
                    for s in &mut text {
                        s.style = s.style.patch(theme.bold());
                    }
                }
                spans.extend(align_spans(text, *w, aligns[i]));
            }
            spans.push(Span::styled(" │", line));
            out.push(Line::from(spans));
        }
        let last = r + 1 == wrapped.len();
        if !last && (r + 1 == t.head_rows || (any_wrapped && r >= t.head_rows)) {
            out.push(rule("├", "┼", "┤"));
        }
    }
    out.push(rule("╰", "┴", "╯"));
    out
}

/// Too many columns to fit at any size: one card per row, a `header  value` pair per line.
fn cards(rows: &[Vec<Cell>], t: &Table, width: usize, theme: Theme) -> Vec<Line<'static>> {
    let cols = rows.first().map_or(0, Vec::len);
    let headers: Vec<String> = if t.head_rows > 0 {
        rows[0].iter().map(|c| plain(c)).collect()
    } else {
        (1..=cols).map(|i| format!("col {i}")).collect()
    };
    // The label column never takes more than half of what is left after the indents.
    let label_w = headers
        .iter()
        .map(|h| width_of(h))
        .max()
        .unwrap_or(0)
        .min(LABEL_MAX)
        .min(width.saturating_sub(4) / 2)
        .max(1);
    let value_w = width.saturating_sub(2 + label_w + 2).max(1);
    let mut out = Vec::new();
    for row in rows.iter().skip(t.head_rows) {
        // A narrow first column (`#`, `No`) is a row number: the title is that and the next cell.
        let numbered = cols > 1 && width_of(&headers[0]) <= 2;
        let (title, first_field) = if numbered {
            (format!("{} · {}", plain(&row[0]), plain(&row[1])), 2)
        } else {
            (plain(&row[0]), 1)
        };
        out.extend(
            wrap_plain(&title, width)
                .into_iter()
                .map(|l| Line::from(Span::styled(l, theme.bold()))),
        );
        for i in first_field..cols {
            if row[i].is_empty() {
                continue;
            }
            for (k, line) in wrap_cell(&row[i], value_w).into_iter().enumerate() {
                let label = if k == 0 {
                    let l = fit_label(&headers[i], label_w);
                    let pad = label_w.saturating_sub(width_of(&l));
                    format!("{l}{}", " ".repeat(pad))
                } else {
                    " ".repeat(label_w)
                };
                let mut spans = vec![
                    Span::raw("  "),
                    Span::styled(label, theme.dim()),
                    Span::raw("  "),
                ];
                spans.extend(line);
                out.push(Line::from(spans));
            }
        }
        out.push(Line::default());
    }
    out.pop();
    out
}

/// A header cut to the label column, with an ellipsis where it was cut.
fn fit_label(h: &str, width: usize) -> String {
    if width_of(h) <= width {
        return h.to_string();
    }
    let mut out: String = h.chars().take(width.saturating_sub(1)).collect();
    out.push('…');
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text(lines: &[Line]) -> Vec<String> {
        lines
            .iter()
            .map(|l| l.spans.iter().map(|s| s.content.as_ref()).collect())
            .collect()
    }

    fn md(s: &str, w: usize) -> Vec<String> {
        text(&render(s, w, Theme::plain()))
    }

    #[test]
    fn paragraphs_wrap_at_the_width_and_are_separated_by_a_blank_row() {
        let got = md("one two three four five six\n\nsecond", 12);
        assert_eq!(got, ["one two", "three four", "five six", "", "second"]);
    }

    #[test]
    fn no_row_is_wider_than_the_width_whatever_the_content() {
        let src = "# 日本語の見出しはとても長いです\n\n- a_very_long_unbroken_word_that_cannot_wrap_anywhere_at_all\n- 日本語日本語日本語日本語日本語\n\n> quote with `inline code that is long` and **bold text here**\n\n```\nlet x = 1234567890123456789012345678901234567890;\n```\n\n| a | b |\n|---|---|\n| 1 | 2 |";
        for w in [10, 20, 33, 80] {
            for row in md(src, w) {
                assert!(
                    width_of(&row) <= w,
                    "width {w}: {row:?} is {}",
                    width_of(&row)
                );
            }
        }
    }

    #[test]
    fn punctuation_after_code_wraps_with_its_word_never_alone() {
        assert_eq!(
            md("approve `cargo test`, waiting", 18),
            ["approve cargo", "test, waiting"]
        );
    }

    #[test]
    fn a_wrapped_list_item_hangs_under_its_text() {
        let got = md("- alpha beta gamma delta epsilon\n- second", 14);
        assert_eq!(
            got,
            ["• alpha beta", "  gamma delta", "  epsilon", "• second"]
        );
    }

    #[test]
    fn ordered_lists_count_and_nested_lists_indent() {
        let got = md("1. first\n2. second\n   - inner\n3. third", 40);
        assert_eq!(got, ["1. first", "2. second", "  • inner", "3. third"]);
    }

    #[test]
    fn numbers_line_up_on_the_right_so_the_text_starts_in_one_column() {
        let got = md("8. eight\n9. nine wraps here\n10. ten", 14);
        assert_eq!(got, [" 8. eight", " 9. nine wraps", "    here", "10. ten"]);
    }

    #[test]
    fn headings_keep_their_hashes() {
        assert_eq!(md("## Plan\n\ntext", 40), ["## Plan", "", "text"]);
    }

    #[test]
    fn code_is_not_reflowed_and_a_long_line_continues_on_the_next_row() {
        let got = md(
            "```rust\nfn main() { call_something_quite_long(argument); }\n```",
            20,
        );
        assert_eq!(got[0], "▏ rust");
        assert!(got.len() > 3, "{got:?}");
        assert!(got[1].starts_with("▏ fn main()"));
    }

    /// What the terminal and ratatui's buffer make of a row: grapheme clusters, so `⚠️` (a symbol
    /// and an emoji selector) is one two-column cell, not a one-column char and a nothing.
    fn cells(row: &str) -> usize {
        unicode_width::UnicodeWidthStr::width(row)
    }

    #[test]
    fn a_table_with_emoji_keeps_every_row_as_wide_as_the_terminal_draws_it() {
        // `⚠️` is U+26A0 U+FE0F: two columns on screen, though each char alone says 1 and 0.
        let t = "| Task | Done | Mark |\n|:--|:-:|:-:|\n| Board | ✅ | ● |\n| pi turn | ⚠️ | ◐ |\n| Codex | ❌ | ○ |\n| Heart | ❤️ | ✔️ |";
        for w in [60, 25] {
            let got = md(t, w);
            let table: Vec<&String> = got
                .iter()
                .filter(|r| r.contains(['│', '╭', '╰', '├']))
                .collect();
            assert!(table.len() >= 8, "a box at {w}: {got:#?}");
            let first = cells(table[0]);
            assert!(
                table
                    .iter()
                    .all(|r| cells(r) == first && width_of(r) == first),
                "every row as wide as the terminal draws it ({first}): {:?}",
                table
                    .iter()
                    .map(|r| (cells(r), width_of(r), r.as_str()))
                    .collect::<Vec<_>>()
            );
        }
        // Squeezed (wrapped cells) or listed as cards, no row is wider than the screen says.
        for w in [24, 18, 12] {
            let got = md(t, w);
            assert!(
                got.iter().all(|r| cells(r) <= w && width_of(r) == cells(r)),
                "{w}: {got:#?}"
            );
        }
    }

    #[test]
    fn a_table_that_fits_is_aligned_and_one_that_does_not_is_listed() {
        let t = "| name | n |\n|:-----|--:|\n| ab | 5 |\n| c | 10 |";
        assert_eq!(
            md(t, 40),
            [
                "╭──────┬────╮",
                "│ name │  n │",
                "├──────┼────┤",
                "│ ab   │  5 │",
                "│ c    │ 10 │",
                "╰──────┴────╯",
            ]
        );
        let long = "| a very long header cell | another long header cell |\n|--|--|\n| x | y |";
        assert!(md(long, 20).iter().all(|r| width_of(r) <= 20));
    }

    #[test]
    fn a_column_of_figures_lines_up_on_the_right_unless_the_table_says_otherwise() {
        let t = "| file | change |\n|--|--|\n| a.dart | +6 −2 |\n| b.dart | +120 −14 |";
        assert_eq!(
            md(t, 40),
            [
                "╭────────┬──────────╮",
                "│ file   │   change │",
                "├────────┼──────────┤",
                "│ a.dart │    +6 −2 │",
                "│ b.dart │ +120 −14 │",
                "╰────────┴──────────╯",
            ]
        );
        let left = "| file | change |\n|--|:--|\n| a | 5 |\n| b | 10 |";
        assert_eq!(md(left, 40)[3], "│ a    │ 5      │");
    }

    #[test]
    fn a_cell_keeps_its_inline_code_and_bold() {
        let theme = Theme::banded((24, 24, 24));
        let lines = render(
            "| file | what |\n|--|--|\n| a.dart | calls `reconnect()` **twice** |",
            60,
            theme,
        );
        let spans: Vec<&Span> = lines.iter().flat_map(|l| l.spans.iter()).collect();
        let code = spans
            .iter()
            .find(|s| s.content == "reconnect()")
            .expect("the code is its own span");
        assert_eq!(code.style.fg, theme.code().fg);
        let strong = spans
            .iter()
            .find(|s| s.content == "twice")
            .expect("the bold is its own span");
        assert!(strong.style.add_modifier.contains(Modifier::BOLD));
    }

    #[test]
    fn a_link_says_where_it_goes_unless_its_label_already_does() {
        assert_eq!(
            md("See [the docs](https://x.io/a) now.", 60),
            ["See the docs (https://x.io/a) now."]
        );
        assert_eq!(md("<https://x.io/a>", 60), ["https://x.io/a"]);
        assert_eq!(md("[x.io](https://x.io)", 60), ["x.io"]);
        assert_eq!(md("[up](#top)", 60), ["up"]);
    }

    fn table_src(cols: usize, rows: usize) -> String {
        let head = (0..cols)
            .map(|c| format!("Header{c}"))
            .collect::<Vec<_>>()
            .join(" | ");
        let rule = (0..cols).map(|_| "---").collect::<Vec<_>>().join("|");
        let body = (0..rows)
            .map(|r| {
                (0..cols)
                    .map(|c| format!("cell {r}x{c} some words"))
                    .collect::<Vec<_>>()
                    .join(" | ")
            })
            .collect::<Vec<_>>()
            .join("\n");
        format!("| {head} |\n|{rule}|\n| {body} |")
    }

    #[test]
    fn a_table_too_wide_to_align_wraps_its_long_cells_and_keeps_its_short_columns() {
        let src = "| id | name | notes |\n|--:|:--|:--|\n| 1 | alpha | this is a rather long note that cannot fit on one line |\n| 22 | beta | short |";
        let got = md(src, 36);
        assert!(got.iter().all(|r| width_of(r) <= 36), "{got:#?}");
        assert!(
            got[1].starts_with("│ id │ name  │ notes"),
            "short columns keep their width: {got:#?}"
        );
        let all = got.join(" ");
        for word in ["rather", "long", "note", "cannot", "fit", "line"] {
            assert!(all.contains(word), "nothing is lost: {word} in {got:#?}");
        }
        assert!(
            got.iter().filter(|r| r.starts_with('├')).count() >= 2,
            "a rule under the header and between the wrapped rows: {got:#?}"
        );
        // One closed box: every row starts and ends on its lines, all the same width.
        let w = width_of(&got[0]);
        assert!(
            got.iter().all(|r| width_of(r) == w
                && r.starts_with(['╭', '│', '├', '╰'])
                && r.ends_with(['╮', '│', '┤', '╯'])),
            "{got:#?}"
        );
    }

    #[test]
    fn a_table_with_too_many_columns_becomes_one_card_per_row() {
        let src = "| # | Machine | Agent | Workspace | Status | Needs me | Link | Uptime | Last event | Tokens | Cost | Version |\n|--|--|--|--|--|--|--|--|--|--|--|--|\n| 1 | dev-box | claude | herdr-mobile | working | no | live | 3h 12m | edited board.dart | 412 | 1.2% | 0.1.4 |\n| 2 | nas | omp | backups | error | yes (fatal) | attention | 5d 3h | SSH auth failed | 12 | 0.0% | 0.1.2 |";
        let got = md(src, 60);
        assert!(got.iter().all(|r| width_of(r) <= 60), "{got:#?}");
        assert_eq!(got[0], "1 · dev-box");
        assert!(
            got.iter()
                .any(|r| r.trim_start().starts_with("Workspace") && r.ends_with("herdr-mobile")),
            "{got:#?}"
        );
        assert!(got.iter().any(|r| r == "2 · nas"), "{got:#?}");
        assert!(got.iter().any(|r| r.contains("SSH auth failed")));
        assert!(
            !got.iter()
                .any(|r| r.contains(" · ") && r.matches(" · ").count() > 1),
            "no dot-joined rows: {got:#?}"
        );
    }

    #[test]
    fn a_card_wraps_a_long_value_under_its_own_text() {
        let src = "| name | notes |\n|--|--|\n| alpha | a very long note that has to wrap onto several lines of a narrow card |";
        let got = md(src, 14);
        assert!(got.iter().all(|r| width_of(r) <= 14), "{got:#?}");
        let at = got
            .iter()
            .position(|r| r.contains("notes"))
            .expect("labelled");
        assert!(
            got[at + 1].starts_with("  ")
                && got[at + 1]
                    .trim_start()
                    .starts_with(|c: char| c.is_alphabetic()),
            "{got:#?}"
        );
    }

    #[test]
    fn no_table_overflows_at_any_width_or_shape() {
        for cols in 1..=12 {
            for width in [8, 16, 30, 60, 100, 160] {
                for row in md(&table_src(cols, 3), width) {
                    assert!(
                        width_of(&row) <= width,
                        "{cols} columns at {width}: {row:?}"
                    );
                }
            }
        }
    }

    #[test]
    fn quotes_wear_a_bar_and_rules_are_drawn() {
        assert_eq!(md("> hello there", 40), ["│ hello there"]);
        assert_eq!(md("a\n\n---\n\nb", 10), ["a", "", "──────────", "", "b"]);
    }

    #[test]
    fn a_table_still_arriving_is_held_back_and_said_to_be_coming() {
        let live = |s: &str| text(&render_live(s, 40, Theme::plain()));
        assert_eq!(
            live("Here:\n\n| a | b |\n|--|--|\n| 1 | 2 |\n| 3"),
            ["Here:", "", "… a table, 2 rows so far"]
        );
        assert_eq!(live("| a | b"), ["… a table"]);
        // A blank line ends it: drawn as the table it is.
        let done = live("| a | b |\n|--|--|\n| 1 | 2 |\n\n");
        assert_eq!(
            done,
            text(&render("| a | b |\n|--|--|\n| 1 | 2 |", 40, Theme::plain()))
        );
        // A pipe inside an open code block is only a character.
        let code = live("```\n| not a table");
        assert!(code.iter().any(|r| r.contains("| not a table")), "{code:?}");
    }

    #[test]
    fn a_title_or_reason_becomes_one_safe_line() {
        let evil = "fix\u{7}\u{1b}]0;PWNED\u{7}\u{1b}[2J\nsecond\tline\u{202e}!";
        let got = one_line(evil, 200);
        assert!(
            !got.chars().any(|c| c.is_control() || is_bidi(c)),
            "{got:?}"
        );
        assert!(got.starts_with("fix") && got.contains("second"), "{got:?}");
        assert_eq!(one_line(&"x".repeat(500), 100).chars().count(), 100);
        assert_eq!(one_line("  \n ", 10), "");
    }

    #[test]
    fn terminal_control_characters_never_reach_the_output() {
        for row in md("hi \u{1b}[2J there\u{7} `a\u{1b}b`", 40) {
            assert!(!row.chars().any(is_unsafe_control), "{row:?}");
        }
    }

    #[test]
    fn text_that_is_not_finished_still_renders() {
        // A message mid-stream: an unclosed fence, bold and list.
        for s in ["```rust\nlet x =", "**bold", "- item\n  - ", "| a |\n|--"] {
            assert!(!md(s, 30).is_empty(), "{s:?}");
        }
    }
}
