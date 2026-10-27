//! Markdown to styled, wrapped terminal lines.
//!
//! Headings keep their `#` signs, inline code is accented, code blocks sit
//! behind a quiet gutter and are never reflowed, lists hang their wrapped
//! lines under the text, and a table that fits is aligned (otherwise it is
//! listed row by row). Everything is wrapped to the width given, by display
//! width, so wide characters never overflow a row.

use crate::theme::Theme;
use acp::is_unsafe_control;
use pulldown_cmark::{Alignment, CodeBlockKind, Event, HeadingLevel, Options, Parser, Tag, TagEnd};
use ratatui::{
    style::{Modifier, Style},
    text::{Line, Span},
};
use unicode_width::UnicodeWidthChar;

/// `text` without the characters a terminal would act on (newlines and tabs stay).
#[must_use]
pub fn clean(text: &str) -> String {
    text.chars()
        .filter(|c| !is_unsafe_control(*c) || *c == '\n' || *c == '\t')
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
    s.chars().map(|c| c.width().unwrap_or(0)).sum()
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

/// Wraps a flow to `width`, word by word, keeping each word's style.
fn wrap_flow(flow: &Flow, width: usize) -> Vec<Line<'static>> {
    let width = width.max(8);
    let mut lines: Vec<Line<'static>> = Vec::new();
    let mut cur: Vec<Span<'static>> = flow.first.clone();
    let mut w = prefix_width(&flow.first);
    let rest_w = prefix_width(&flow.rest);
    let mut at_start = true;
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
                continue;
            }
            if w + tw > width && !at_start {
                // Do not carry the space that ended the previous row.
                if cur
                    .last()
                    .is_some_and(|s| s.content.chars().all(char::is_whitespace))
                {
                    cur.pop();
                }
                newline(&mut cur, &mut w, &mut lines, &mut at_start);
            }
            if tw > width.saturating_sub(w) {
                // A word longer than a row: cut it by display width.
                let mut piece = String::new();
                let mut pw = 0;
                for c in token.chars() {
                    let cw = c.width().unwrap_or(0);
                    if w + pw + cw > width && !piece.is_empty() {
                        cur.push(Span::styled(std::mem::take(&mut piece), span.style));
                        newline(&mut cur, &mut w, &mut lines, &mut at_start);
                        pw = 0;
                    }
                    piece.push(c);
                    pw += cw;
                }
                cur.push(Span::styled(piece, span.style));
                w += pw;
            } else {
                cur.push(Span::styled(token.to_string(), span.style));
                w += tw;
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
}

struct Table {
    aligns: Vec<Alignment>,
    rows: Vec<Vec<String>>,
    head_rows: usize,
    cell: String,
    row: Vec<String>,
    in_head: bool,
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

    for ev in Parser::new_ext(&text, opts) {
        if let Some(t) = table.as_mut() {
            match &ev {
                Event::Text(s) | Event::Code(s) => t.cell.push_str(s),
                Event::SoftBreak | Event::HardBreak => t.cell.push(' '),
                Event::End(TagEnd::TableCell) => {
                    t.row.push(std::mem::take(&mut t.cell).trim().to_string())
                }
                Event::End(TagEnd::TableHead) => {
                    t.rows.push(std::mem::take(&mut t.row));
                    t.in_head = false;
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
                lists.push(ListCtx { next: start });
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
                    Some(ListCtx { next: Some(n) }) => {
                        let m = format!("{n}. ");
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
                    cell: String::new(),
                    row: Vec::new(),
                    in_head: false,
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
            Event::Start(Tag::Link { .. }) => {
                style_stack.push(top(&style_stack).add_modifier(Modifier::UNDERLINED))
            }
            Event::End(
                TagEnd::Emphasis | TagEnd::Strong | TagEnd::Strikethrough | TagEnd::Link,
            ) => {
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
                    theme.dim(),
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
    for raw in text.trim_end_matches('\n').split('\n') {
        // Code is never reflowed; a line longer than the row continues on the next.
        let raw = raw.replace('\t', "    ");
        let mut piece = String::new();
        let mut pw = 0;
        let mut first = true;
        let emit = |p: String, out: &mut Vec<Line<'static>>| {
            out.push(Line::from(vec![
                Span::styled(format!("{lead}{gutter}"), theme.dim()),
                Span::styled(p, theme.code()),
            ]));
        };
        for c in raw.chars() {
            let cw = c.width().unwrap_or(0);
            if pw + cw > inner {
                emit(std::mem::take(&mut piece), &mut out);
                first = false;
                pw = 0;
            }
            piece.push(c);
            pw += cw;
        }
        let _ = first;
        emit(piece, &mut out);
    }
    out
}

/// Cells of a column this wide or less keep their natural width when the table is squeezed.
const SHORT_CELL: usize = 10;
/// Columns wider than that may wrap, but no narrower than this.
const MIN_WRAPPED: usize = 4;
const CELL_GAP: usize = 3;
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
        for c in word.chars() {
            let cw = c.width().unwrap_or(0);
            if w + cw > width {
                lines.push(std::mem::take(&mut cur));
                w = 0;
            }
            cur.push(c);
            w += cw;
        }
    }
    lines.push(cur);
    lines
}

/// Pads `text` to `width` by the column's alignment.
fn align_cell(text: &str, width: usize, align: Option<&Alignment>) -> String {
    let pad = width.saturating_sub(width_of(text));
    let (l, r) = match align {
        Some(Alignment::Right) => (pad, 0),
        Some(Alignment::Center) => (pad / 2, pad - pad / 2),
        _ => (0, pad),
    };
    format!("{}{}{}", " ".repeat(l), text, " ".repeat(r))
}

fn render_table(t: &Table, width: usize, theme: Theme) -> Vec<Line<'static>> {
    let cols = t.rows.iter().map(Vec::len).max().unwrap_or(0);
    if cols == 0 {
        return Vec::new();
    }
    let rows: Vec<Vec<String>> = t
        .rows
        .iter()
        .map(|r| {
            (0..cols)
                .map(|i| r.get(i).cloned().unwrap_or_default())
                .collect()
        })
        .collect();
    let natural: Vec<usize> = (0..cols)
        .map(|i| rows.iter().map(|r| width_of(&r[i])).max().unwrap_or(0))
        .collect();
    let gaps = CELL_GAP * (cols - 1);
    if natural.iter().sum::<usize>() + gaps <= width {
        return grid(&rows, t, &natural, theme);
    }
    // Squeezed: short columns keep their width, long ones may wrap down to their longest word.
    let min: Vec<usize> = (0..cols)
        .map(|i| {
            if natural[i] <= SHORT_CELL {
                natural[i]
            } else {
                let word = rows
                    .iter()
                    .flat_map(|r| r[i].split_whitespace())
                    .map(width_of)
                    .max()
                    .unwrap_or(0);
                word.clamp(MIN_WRAPPED, 12).min(natural[i])
            }
        })
        .collect();
    let avail = width.saturating_sub(gaps);
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
    grid(&rows, t, &widths, theme)
}

/// The table as an aligned grid; a cell wider than its column wraps within it.
fn grid(rows: &[Vec<String>], t: &Table, widths: &[usize], theme: Theme) -> Vec<Line<'static>> {
    let wrapped: Vec<Vec<Vec<String>>> = rows
        .iter()
        .map(|r| {
            r.iter()
                .enumerate()
                .map(|(i, c)| wrap_plain(c, widths[i]))
                .collect()
        })
        .collect();
    let any_wrapped = wrapped.iter().any(|r| r.iter().any(|c| c.len() > 1));
    let rule = |fill: &str, join: &str| -> Line<'static> {
        Line::from(Span::styled(
            widths
                .iter()
                .map(|w| fill.repeat(*w))
                .collect::<Vec<_>>()
                .join(join),
            theme.dim(),
        ))
    };
    let mut out = Vec::new();
    for (r, cells) in wrapped.iter().enumerate() {
        let height = cells.iter().map(Vec::len).max().unwrap_or(1);
        let style = if r < t.head_rows {
            theme.bold()
        } else {
            Style::default()
        };
        for k in 0..height {
            let mut spans = Vec::new();
            for (i, w) in widths.iter().enumerate() {
                if i > 0 {
                    spans.push(Span::styled(" │ ", theme.dim()));
                }
                let text = cells[i].get(k).map_or("", String::as_str);
                spans.push(Span::styled(align_cell(text, *w, t.aligns.get(i)), style));
            }
            out.push(Line::from(spans));
        }
        if r + 1 == t.head_rows {
            out.push(rule("─", "─┼─"));
        } else if any_wrapped && r + 1 < wrapped.len() && r >= t.head_rows {
            // Wrapped rows run together without a line between them.
            out.push(rule("┄", "┄┼┄"));
        }
    }
    out
}

/// Too many columns to fit at any size: one card per row, a `header  value` pair per line.
fn cards(rows: &[Vec<String>], t: &Table, width: usize, theme: Theme) -> Vec<Line<'static>> {
    let cols = rows.first().map_or(0, Vec::len);
    let headers: Vec<String> = if t.head_rows > 0 {
        rows[0].clone()
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
            (format!("{} · {}", row[0], row[1]), 2)
        } else {
            (row[0].clone(), 1)
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
            for (k, line) in wrap_plain(&row[i], value_w).into_iter().enumerate() {
                let label = if k == 0 {
                    align_cell(&fit_label(&headers[i], label_w), label_w, None)
                } else {
                    " ".repeat(label_w)
                };
                out.push(Line::from(vec![
                    Span::raw("  "),
                    Span::styled(label, theme.dim()),
                    Span::raw("  "),
                    Span::raw(line),
                ]));
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

    #[test]
    fn a_table_that_fits_is_aligned_and_one_that_does_not_is_listed() {
        let t = "| name | n |\n|:-----|--:|\n| ab | 5 |\n| c | 10 |";
        assert_eq!(
            md(t, 40),
            ["name │  n", "─────┼───", "ab   │  5", "c    │ 10"]
        );
        let long = "| a very long header cell | another long header cell |\n|--|--|\n| x | y |";
        assert!(md(long, 20).iter().all(|r| width_of(r) <= 20));
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
            got[0].starts_with("id │ name  │ notes"),
            "short columns keep their width: {got:#?}"
        );
        let all = got.join(" ");
        for word in ["rather", "long", "note", "cannot", "fit", "line"] {
            assert!(all.contains(word), "nothing is lost: {word} in {got:#?}");
        }
        assert!(
            got.iter().any(|r| r.contains('┄')),
            "wrapped rows are told apart: {got:#?}"
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
