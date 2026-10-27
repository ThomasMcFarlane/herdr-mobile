//! Colours a shell command for reading: the command names, their flags, strings and
//! variables. A reading aid, not a parser: what it cannot tell stays plain, and the text is
//! never changed.

use crate::theme::Theme;
use ratatui::{style::Style, text::Span};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Command,
    Flag,
    Str,
    Var,
    Plain,
}

/// Splits `cmd` into runs and says what each is.
#[must_use]
pub fn tokens(cmd: &str) -> Vec<(String, Kind)> {
    let chars: Vec<char> = cmd.chars().collect();
    let mut out: Vec<(String, Kind)> = Vec::new();
    let mut i = 0;
    let mut expect_command = true;
    while i < chars.len() {
        let c = chars[i];
        if c.is_whitespace() {
            let start = i;
            while i < chars.len() && chars[i].is_whitespace() {
                i += 1;
            }
            out.push((chars[start..i].iter().collect(), Kind::Plain));
        } else if matches!(c, ';' | '|' | '&' | '(' | ')' | '{' | '}') {
            let start = i;
            while i < chars.len() && matches!(chars[i], ';' | '|' | '&' | '(' | ')' | '{' | '}') {
                i += 1;
            }
            out.push((chars[start..i].iter().collect(), Kind::Plain));
            expect_command = true;
        } else if c == '\'' || c == '"' {
            let start = i;
            i += 1;
            while i < chars.len() && chars[i] != c {
                if chars[i] == '\\' && c == '"' {
                    i += 1;
                }
                i += 1;
            }
            i = (i + 1).min(chars.len());
            out.push((chars[start..i].iter().collect(), Kind::Str));
            expect_command = false;
        } else {
            let start = i;
            while i < chars.len()
                && !chars[i].is_whitespace()
                && !matches!(
                    chars[i],
                    ';' | '|' | '&' | '(' | ')' | '{' | '}' | '\'' | '"'
                )
            {
                i += 1;
            }
            let word: String = chars[start..i].iter().collect();
            let kind = if word.starts_with('$') {
                Kind::Var
            } else if word.starts_with('-')
                || word.starts_with("2>")
                || word.starts_with("1>")
                || word.starts_with('>')
                || word.starts_with('<')
            {
                Kind::Flag
            } else if word.contains('=') && expect_command && !word.starts_with('=') {
                // VAR=value before the command: the command is still to come.
                Kind::Var
            } else if expect_command {
                expect_command = false;
                Kind::Command
            } else {
                Kind::Plain
            };
            out.push((word, kind));
        }
    }
    out
}

/// The command as styled spans.
#[must_use]
pub fn highlight(cmd: &str, theme: Theme) -> Vec<Span<'static>> {
    tokens(cmd)
        .into_iter()
        .map(|(text, kind)| {
            let style = match kind {
                Kind::Command => theme.cmd(),
                Kind::Flag => theme.flag(),
                Kind::Str => theme.string(),
                Kind::Var => theme.var(),
                Kind::Plain => Style::default(),
            };
            Span::styled(text, style)
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn kinds(cmd: &str) -> Vec<(String, Kind)> {
        tokens(cmd)
            .into_iter()
            .filter(|(t, _)| !t.trim().is_empty())
            .collect()
    }

    #[test]
    fn commands_flags_and_operators_are_told_apart() {
        let got = kinds("pwd; git rev-parse --show-toplevel 2>/dev/null; git status --short");
        let cmds: Vec<&str> = got
            .iter()
            .filter(|(_, k)| *k == Kind::Command)
            .map(|(t, _)| t.as_str())
            .collect();
        assert_eq!(cmds, ["pwd", "git", "git"]);
        let flags: Vec<&str> = got
            .iter()
            .filter(|(_, k)| *k == Kind::Flag)
            .map(|(t, _)| t.as_str())
            .collect();
        assert_eq!(flags, ["--show-toplevel", "2>/dev/null", "--short"]);
    }

    #[test]
    fn a_command_follows_each_separator_and_strings_and_variables_stand_out() {
        let got = kinds("cd /tmp && FOO=1 make -j4 | grep \"a b\" $HOME");
        let by = |k: Kind| {
            got.iter()
                .filter(|(_, x)| *x == k)
                .map(|(t, _)| t.as_str())
                .collect::<Vec<_>>()
        };
        assert_eq!(by(Kind::Command), ["cd", "make", "grep"]);
        assert_eq!(by(Kind::Str), ["\"a b\""]);
        assert_eq!(by(Kind::Var), ["FOO=1", "$HOME"]);
    }

    #[test]
    fn the_text_is_never_changed_whatever_it_holds() {
        for cmd in [
            "",
            "  ls   -la  ",
            "echo 'unterminated",
            "a;;b&&&c",
            "echo \"esc \\\" q\" x",
            "日本語 --флаг",
        ] {
            let joined: String = tokens(cmd).into_iter().map(|(t, _)| t).collect();
            assert_eq!(joined, cmd);
        }
    }
}
