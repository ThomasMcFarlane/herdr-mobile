//! Asks the terminal what its background colour is (OSC 11), so tints can be derived from it
//! and read on a light terminal as well as a dark one. Terminals that do not answer cost a
//! short wait and the caller falls back.

use crossterm::event::{self, Event, KeyCode};
use std::time::{Duration, Instant};

/// How long to wait for an answer.
const WAIT: Duration = Duration::from_millis(180);

/// `rgb:RRRR/GGGG/BBBB` (any hex width per channel) from an OSC 11 reply.
#[must_use]
pub fn parse(reply: &str) -> Option<(u8, u8, u8)> {
    let body = reply.split("rgb:").nth(1)?;
    let mut ch = body.split('/').map(|part| {
        let hex: String = part.chars().take_while(char::is_ascii_hexdigit).collect();
        if hex.is_empty() || hex.len() > 4 {
            return None;
        }
        let v = u32::from_str_radix(&hex, 16).ok()?;
        let max = 16u32.pow(u32::try_from(hex.len()).ok()?) - 1;
        u8::try_from(v * 255 / max).ok()
    });
    Some((ch.next()??, ch.next()??, ch.next()??))
}

/// Queries the terminal. Must run in raw mode, before the keyboard thread starts: the reply
/// arrives as key events, which are read here and not passed on.
#[must_use]
pub fn query() -> Option<(u8, u8, u8)> {
    use std::io::Write;
    let mut out = std::io::stdout();
    out.write_all(b"\x1b]11;?\x1b\\").ok()?;
    out.flush().ok()?;
    let end = Instant::now() + WAIT;
    let mut reply = String::new();
    while let Some(left) = end.checked_duration_since(Instant::now()) {
        if !event::poll(left).ok()? {
            break;
        }
        if let Event::Key(k) = event::read().ok()? {
            // Only characters matter: the terminator (BEL as Ctrl-G, ST as Esc then a backslash)
            // ends the string and adds nothing to the colour.
            if let KeyCode::Char(c) = k.code {
                reply.push(c);
            }
            if let Some(rgb) = parse(&reply) {
                // Give the last channel its terminator, then stop.
                if reply
                    .rsplit('/')
                    .next()
                    .is_some_and(|b| b.chars().take_while(char::is_ascii_hexdigit).count() >= 2)
                {
                    while event::poll(Duration::from_millis(15)).unwrap_or(false) {
                        let _ = event::read();
                    }
                    return Some(rgb);
                }
            }
        }
    }
    parse(&reply)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn replies_of_any_width_are_read() {
        assert_eq!(parse("]11;rgb:ffff/ffff/ffff"), Some((255, 255, 255)));
        assert_eq!(parse("]11;rgb:1a1b/1b26/2626"), Some((26, 27, 38)));
        assert_eq!(parse("rgb:ff/00/80"), Some((255, 0, 128)));
        assert_eq!(parse("rgb:f/0/8"), Some((255, 0, 136)));
    }

    #[test]
    fn anything_else_is_nothing() {
        assert_eq!(parse(""), None);
        assert_eq!(parse("rgb:zz/00/00"), None);
        assert_eq!(parse("rgb:ff/00"), None);
        assert_eq!(parse("rgb:fffff/00/00"), None);
    }
}
