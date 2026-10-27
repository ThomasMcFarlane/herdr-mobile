//! Syntax colour for code: a fenced block in the agent's words, and the changed lines of a diff.
//!
//! The grammars are syntect's defaults (Sublime's); the colours are not a bundled theme but the
//! palette everything else is drawn with (`theme.rs`), so a keyword is the blue a shell command
//! is, a string the green, and every colour holds its contrast on the terminal's background. The
//! grammars load once, on a thread of their own at start ([`warm`]), so the first code block
//! never waits for them.

use crate::theme::Theme;
use ratatui::{style::Style, text::Span};
use std::cell::RefCell;
use std::collections::hash_map::DefaultHasher;
use std::collections::VecDeque;
use std::hash::{Hash, Hasher};
use std::sync::LazyLock;
use syntect::easy::ScopeRangeIterator;
use syntect::parsing::{ParseState, Scope, ScopeStack, SyntaxReference, SyntaxSet};

/// Lines of one block coloured before the rest is left plain: a pasted log is not worth a stall.
const MAX_LINES: usize = 2000;
/// A line longer than this is left plain (a minified file would cost far more than it shows).
const MAX_LINE: usize = 1000;

static SYNTAXES: LazyLock<SyntaxSet> = LazyLock::new(SyntaxSet::load_defaults_nonewlines);

/// Loads the grammars in the background, so they are ready by the time code is drawn.
pub fn warm() {
    std::thread::spawn(|| {
        LazyLock::force(&SYNTAXES);
    });
}

/// What a scope is drawn as, most specific scope first.
#[derive(Clone, Copy)]
enum Role {
    Comment,
    Text,
    Number,
    Keyword,
    Function,
    Type,
    Added,
    Removed,
}

static RULES: LazyLock<Vec<(Scope, Role)>> = LazyLock::new(|| {
    [
        ("comment", Role::Comment),
        ("punctuation.definition.comment", Role::Comment),
        ("string", Role::Text),
        ("constant.character", Role::Text),
        ("constant.numeric", Role::Number),
        ("constant.language", Role::Number),
        ("constant.other", Role::Number),
        ("entity.other.attribute-name", Role::Number),
        ("keyword", Role::Keyword),
        ("storage.modifier", Role::Keyword),
        ("entity.name.tag", Role::Keyword),
        ("storage.type", Role::Type),
        // Words that declare (`fn`, `def`, `class`, `struct`, `let`) read as keywords, not types.
        ("storage.type.function", Role::Keyword),
        ("storage.type.class", Role::Keyword),
        ("storage.type.struct", Role::Keyword),
        ("storage.type.enum", Role::Keyword),
        ("storage.type.trait", Role::Keyword),
        ("storage.type.impl", Role::Keyword),
        ("storage.type.module", Role::Keyword),
        ("storage.type.type", Role::Keyword),
        ("storage.type.variable", Role::Keyword),
        ("entity.name.type", Role::Type),
        ("entity.name.class", Role::Type),
        ("entity.name.struct", Role::Type),
        ("entity.name.enum", Role::Type),
        ("support.type", Role::Type),
        ("support.class", Role::Type),
        ("entity.name.function", Role::Function),
        ("support.function", Role::Function),
        ("variable.function", Role::Function),
        ("markup.inserted", Role::Added),
        ("markup.deleted", Role::Removed),
    ]
    .into_iter()
    .filter_map(|(s, r)| Scope::new(s).ok().map(|s| (s, r)))
    .collect()
});

fn style_for(stack: &ScopeStack, theme: Theme) -> Style {
    for scope in stack.as_slice().iter().rev() {
        // The most specific rule wins: `storage.type.function` (`fn`, `def`) over `storage.type`.
        let hit = RULES
            .iter()
            .filter(|(s, _)| s.is_prefix_of(*scope))
            .max_by_key(|(s, _)| s.len());
        if let Some((_, role)) = hit {
            return match role {
                Role::Comment => theme.dim(),
                Role::Text => theme.string(),
                Role::Number => theme.flag(),
                Role::Keyword => theme.cmd(),
                Role::Function => theme.code(),
                Role::Type => theme.var(),
                Role::Added => theme.ok(),
                Role::Removed => theme.bad(),
            };
        }
    }
    Style::default()
}

/// The grammar for a fence's language (`rust`, `py`, `ts`, `sh`...), or a file's extension.
fn syntax(token: &str) -> Option<&'static SyntaxReference> {
    let token = token.trim().trim_start_matches('.');
    if token.is_empty() {
        return None;
    }
    let set = &*SYNTAXES;
    set.find_syntax_by_token(token)
        .or_else(|| set.find_syntax_by_extension(&token.to_ascii_lowercase()))
        .filter(|s| s.name != "Plain Text")
}

/// The grammar for a path, by its extension or, for `Makefile`-like names, its file name.
#[must_use]
pub fn for_path(path: &str) -> Option<&str> {
    let name = path.rsplit('/').next().unwrap_or(path);
    let token = name.rsplit_once('.').map_or(name, |(_, ext)| ext);
    syntax(token)
        .map(|_| token)
        .or_else(|| syntax(name).map(|_| name))
}

/// Where a block's colouring stopped: the parser's state after its first lines, and what they
/// were drawn as. A message that streams in grows its code block line by line and is drawn again
/// on every chunk; with this, each new line is parsed once instead of the whole block each time.
struct Done {
    lang: String,
    theme: Theme,
    hashes: Vec<u64>,
    state: ParseState,
    stack: ScopeStack,
    out: Vec<Vec<Span<'static>>>,
}

/// Blocks whose colouring is kept: enough for the few code blocks on screen. Per thread, because
/// a parser's state holds the regex engine's own (not `Send`) memory, and only the thread that
/// draws ever colours.
const KEPT: usize = 8;
thread_local! {
    static KEPT_BLOCKS: RefCell<VecDeque<Done>> = const { RefCell::new(VecDeque::new()) };
}

fn hash_line(line: &str) -> u64 {
    let mut h = DefaultHasher::new();
    line.hash(&mut h);
    h.finish()
}

/// `lines` coloured as `lang`, one span list per line (tabs already expanded by the caller).
/// `None` when the language is unknown or the terminal shows no colour: the caller draws it
/// plain, as before.
#[must_use]
pub fn lines(lang: &str, lines: &[&str], theme: Theme) -> Option<Vec<Vec<Span<'static>>>> {
    if !theme.colored() || lines.is_empty() {
        return None;
    }
    let syntax = syntax(lang)?;
    let set = &*SYNTAXES;
    let hashes: Vec<u64> = lines.iter().map(|l| hash_line(l)).collect();
    // The longest block kept that this one starts with and goes past, taken out (it is put back
    // grown).
    let resumed = KEPT_BLOCKS.with_borrow_mut(|kept| {
        let best = kept
            .iter()
            .enumerate()
            .filter(|(_, d)| {
                d.lang == lang
                    && d.theme == theme
                    && d.hashes.len() < hashes.len()
                    && hashes.starts_with(&d.hashes)
            })
            .max_by_key(|(_, d)| d.hashes.len())
            .map(|(i, _)| i);
        best.and_then(|i| kept.remove(i))
    });
    let (mut state, mut stack, mut out) = match resumed {
        Some(d) => (d.state, d.stack, d.out),
        None => (
            ParseState::new(syntax),
            ScopeStack::new(),
            Vec::with_capacity(lines.len()),
        ),
    };
    let mut snapshot = None;
    for i in out.len()..lines.len() {
        // The last line may still be growing: what comes before it is what is kept.
        if i + 1 == lines.len() {
            snapshot = Some((state.clone(), stack.clone(), out.clone()));
        }
        out.push(colour_line(lines[i], i, &mut state, &mut stack, set, theme));
    }
    if let Some((state, stack, kept_out)) = snapshot {
        KEPT_BLOCKS.with_borrow_mut(|kept| {
            if kept.len() >= KEPT {
                kept.pop_front();
            }
            kept.push_back(Done {
                lang: lang.to_string(),
                theme,
                hashes: hashes[..lines.len() - 1].to_vec(),
                state,
                stack,
                out: kept_out,
            });
        });
    }
    Some(out)
}

fn colour_line(
    line: &str,
    i: usize,
    state: &mut ParseState,
    stack: &mut ScopeStack,
    set: &SyntaxSet,
    theme: Theme,
) -> Vec<Span<'static>> {
    if i >= MAX_LINES {
        return vec![Span::styled(line.to_string(), theme.code())];
    }
    // A long line is read only as far as MAX_LINE, so the grammar is not left behind (a comment
    // opened on it stays open after it); the rest of it is drawn plain.
    let mut cut = line.len().min(MAX_LINE);
    while !line.is_char_boundary(cut) {
        cut -= 1;
    }
    let (head, tail) = line.split_at(cut);
    let Ok(ops) = state.parse_line(head, set) else {
        return vec![Span::raw(line.to_string())];
    };
    let mut spans: Vec<Span<'static>> = Vec::new();
    for (range, op) in ScopeRangeIterator::new(&ops, head) {
        let _ = stack.apply(op);
        if range.is_empty() {
            continue;
        }
        let style = style_for(stack, theme);
        let text = &head[range];
        match spans.last_mut() {
            Some(last) if last.style == style => last.content.to_mut().push_str(text),
            _ => spans.push(Span::styled(text.to_string(), style)),
        }
    }
    if !tail.is_empty() {
        spans.push(Span::styled(tail.to_string(), theme.code()));
    }
    spans
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dark() -> Theme {
        Theme::banded((24, 24, 24))
    }

    fn style_of<'a>(rows: &'a [Vec<Span<'static>>], text: &str) -> &'a Span<'static> {
        rows.iter()
            .flatten()
            .find(|s| s.content.contains(text))
            .unwrap_or_else(|| panic!("{text} in {rows:?}"))
    }

    #[test]
    fn a_keyword_a_string_and_a_comment_each_get_the_palettes_colour() {
        let t = dark();
        let rows = lines(
            "rust",
            &["fn main() {", "    let s = \"hi\"; // greet", "}"],
            t,
        )
        .expect("rust is known");
        assert_eq!(style_of(&rows, "fn").style.fg, t.cmd().fg);
        assert_eq!(style_of(&rows, "\"hi\"").style.fg, t.string().fg);
        assert_eq!(style_of(&rows, "greet").style.fg, t.dim().fg);
        // Nothing is lost or added: each row is its line.
        assert_eq!(
            rows[1]
                .iter()
                .map(|s| s.content.as_ref())
                .collect::<String>(),
            "    let s = \"hi\"; // greet"
        );
    }

    #[test]
    fn a_comment_that_spans_lines_stays_a_comment_on_the_next_line() {
        let t = dark();
        let rows = lines("c", &["/* one", "two */ int x;"], t).expect("c is known");
        assert_eq!(style_of(&rows, "two").style.fg, t.dim().fg);
        assert_eq!(style_of(&rows, "int").style.fg, t.var().fg);
    }

    #[test]
    fn a_comment_opened_on_a_very_long_line_stays_open_on_the_next() {
        let t = dark();
        let long = format!("/* {}", "x".repeat(MAX_LINE * 2));
        let rows = lines("c", &[long.as_str(), "still comment */ int y;"], t).expect("c");
        assert_eq!(style_of(&rows[1..], "still").style.fg, t.dim().fg);
        assert_eq!(style_of(&rows[1..], "int").style.fg, t.var().fg);
    }

    #[test]
    fn a_block_that_grows_line_by_line_is_coloured_as_if_read_whole() {
        let t = dark();
        let _ = lines("c", &["/* one", "two"], t);
        let _ = lines("c", &["/* one", "two", "thr"], t);
        let rows = lines("c", &["/* one", "two", "three */ int x;"], t).expect("c is known");
        assert_eq!(rows.len(), 3);
        assert_eq!(
            style_of(&rows, "three").style.fg,
            t.dim().fg,
            "still in the comment"
        );
        assert_eq!(style_of(&rows, "int").style.fg, t.var().fg);
    }

    #[test]
    fn an_unknown_language_or_no_colour_is_drawn_plain() {
        assert!(lines("no-such-language", &["x"], dark()).is_none());
        assert!(lines("", &["x"], dark()).is_none());
        assert!(lines("rust", &["fn x() {}"], Theme::plain()).is_none());
    }

    #[test]
    fn a_path_names_its_grammar_by_its_extension() {
        assert_eq!(
            for_path("lib/sync.dart").is_some(),
            syntax("dart").is_some()
        );
        assert_eq!(for_path("src/main.rs"), Some("rs"));
        assert_eq!(for_path("README"), None);
    }
}
