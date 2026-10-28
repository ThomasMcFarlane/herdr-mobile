//! What reaches the input box from outside the keyboard: a paste, and the terminal's own replies
//! that are not typing. Pure, so each is testable.

use acp::is_unsafe_control;
use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

/// The most text one paste inserts: more than a person writes, less than a stall.
pub const MAX_PASTE: usize = 256 * 1024;

/// A paste made safe to put in the input box: line ends become `\n`, tabs become spaces, and
/// controls and bidirectional overrides are dropped (a paste is the one way to put an escape
/// sequence into the box). `true` when it was cut at [`MAX_PASTE`].
#[must_use]
pub fn clean_paste(raw: &str) -> (String, bool) {
    let mut out = String::with_capacity(raw.len().min(MAX_PASTE));
    let mut chars = raw.chars().peekable();
    let mut cut = false;
    while let Some(c) = chars.next() {
        if out.len() >= MAX_PASTE {
            cut = true;
            break;
        }
        match c {
            '\r' => {
                if chars.peek() == Some(&'\n') {
                    chars.next();
                }
                out.push('\n');
            }
            '\n' => out.push('\n'),
            '\t' => out.push_str("    "),
            c if is_unsafe_control(c) => {}
            c => out.push(c),
        }
    }
    (out, cut)
}

/// The longest string swallowed after an OSC opener: a terminal's reply is short, this only bounds
/// the damage of a terminator that never comes.
const OSC_MAX: usize = 96;

/// Spots the terminal's own replies in the stream of keys. We ask the terminal for its background
/// colour (an OSC string); an answer that comes after we stopped waiting would otherwise be typed into
/// the input box, character by character, and its escapes would act as keys. A reply starts as
/// Alt-`]` and ends with Ctrl-G (BEL) or Alt-`\` (ST), and nobody types either.
#[derive(Debug, Default)]
pub struct OscFilter {
    inside: usize,
}

impl OscFilter {
    /// Whether this key is part of a terminal reply and must be dropped.
    pub fn drops(&mut self, k: &KeyEvent) -> bool {
        let opens = k.code == KeyCode::Char(']') && k.modifiers == KeyModifiers::ALT;
        if self.inside == 0 && !opens {
            return false;
        }
        self.inside += 1;
        let ends = (k.code == KeyCode::Char('g') && k.modifiers.contains(KeyModifiers::CONTROL))
            || (k.code == KeyCode::Char('\\') && k.modifiers == KeyModifiers::ALT);
        if ends || self.inside > OSC_MAX {
            self.inside = 0;
        }
        true
    }
}

/// Asks the terminal for clicks, the wheel and drags (button events, SGR coordinates). Not plain
/// motion (`?1003`): a moving pointer would wake the screen for nothing. `?1002` reports motion
/// only while a button is held, which is a drag, and a drag is what selects text (`select.rs`).
pub const MOUSE_ON: &[u8] = b"\x1b[?1002h\x1b[?1006h";
pub const MOUSE_OFF: &[u8] = b"\x1b[?1006l\x1b[?1002l\x1b[?1000l";

/// Whether to take the mouse: yes, unless `HERDR_TUI_MOUSE` says `off`, `0` or `false` (then the
/// wheel arrives as Up and Down, and a plain drag selects, as before clicks did anything).
#[must_use]
pub fn mouse_wanted(env: impl Fn(&str) -> Option<String>) -> bool {
    !env("HERDR_TUI_MOUSE").is_some_and(|v| {
        let v = v.trim();
        v == "0" || v.eq_ignore_ascii_case("off") || v.eq_ignore_ascii_case("false")
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key(c: char) -> KeyEvent {
        KeyEvent::new(KeyCode::Char(c), KeyModifiers::NONE)
    }

    #[test]
    fn a_paste_keeps_its_lines_as_text_and_drops_what_could_act() {
        let (got, cut) = clean_paste("alpha\r\nbeta\rgamma\n\tindented\u{1b}[2J\u{7} \u{202e}end");
        assert_eq!(got, "alpha\nbeta\ngamma\n    indented[2J end");
        assert!(!cut);
    }

    #[test]
    fn a_huge_paste_is_cut_and_says_so() {
        let (got, cut) = clean_paste(&"x".repeat(MAX_PASTE * 2));
        assert!(cut && got.len() <= MAX_PASTE + 4, "{}", got.len());
        assert_eq!(clean_paste("日本語").0, "日本語");
    }

    #[test]
    fn a_late_colour_reply_is_swallowed_whole_and_typing_before_and_after_is_not() {
        let mut f = OscFilter::default();
        assert!(!f.drops(&key('h')));
        // ESC ] 11 ; rgb:1e1e/1e1e/2e2e BEL
        assert!(f.drops(&KeyEvent::new(KeyCode::Char(']'), KeyModifiers::ALT)));
        for c in "11;rgb:1e1e/1e1e/2e2e".chars() {
            assert!(f.drops(&key(c)), "{c}");
        }
        assert!(f.drops(&KeyEvent::new(KeyCode::Char('g'), KeyModifiers::CONTROL)));
        assert!(!f.drops(&key('i')), "typing resumes");
    }

    #[test]
    fn the_string_terminator_form_ends_it_too_and_a_lost_terminator_is_bounded() {
        let mut f = OscFilter::default();
        assert!(f.drops(&KeyEvent::new(KeyCode::Char(']'), KeyModifiers::ALT)));
        assert!(f.drops(&key('x')));
        assert!(f.drops(&KeyEvent::new(KeyCode::Char('\\'), KeyModifiers::ALT)));
        assert!(!f.drops(&key('a')));
        let mut g = OscFilter::default();
        assert!(g.drops(&KeyEvent::new(KeyCode::Char(']'), KeyModifiers::ALT)));
        let swallowed = (0..500).take_while(|_| g.drops(&key('x'))).count();
        assert!(
            swallowed <= OSC_MAX,
            "{swallowed}: a missing terminator cannot eat the keyboard"
        );
    }
}
