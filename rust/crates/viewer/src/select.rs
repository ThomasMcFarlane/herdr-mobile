//! Selecting text on the screen and copying it.
//!
//! The viewer takes the mouse for clicks, and a terminal that has handed its mouse to an
//! application selects nothing itself: herdr forwards the drag to the pane instead of copying,
//! and Shift-drag in the outer terminal cuts a rectangle across the sidebar and the other
//! panes. So the viewer selects. What is selected is the screen as drawn (rows and columns), not
//! the messages behind it: the same text a terminal's own selection would give, which is also
//! why it can be taken from the finished frame with no help from the transcript.
//!
//! The copy leaves as an OSC 52 write, which herdr (and any terminal that allows it) puts on the
//! clipboard of the machine the person sits at, over SSH too.

use crate::theme::Theme;
use ratatui::{buffer::Buffer, style::Modifier};
use unicode_width::UnicodeWidthStr;

/// A cell, as (column, row).
pub type Cell = (u16, u16);

/// What the pointer has done since the button went down.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Selection {
    anchor: Cell,
    head: Cell,
    /// The button is up: the text was copied, and the highlight stays until the person does
    /// something else.
    pub done: bool,
}

impl Selection {
    /// The button went down on `at`: nothing is selected until the pointer moves to another cell.
    #[must_use]
    pub fn begin(at: Cell) -> Self {
        Self {
            anchor: at,
            head: at,
            done: false,
        }
    }

    pub fn drag(&mut self, to: Cell) {
        self.head = to;
    }

    /// The first and the last selected cell in reading order, or `None` while the pointer has
    /// not left the cell it went down on (that is a click).
    #[must_use]
    pub fn range(&self) -> Option<(Cell, Cell)> {
        if self.anchor == self.head {
            return None;
        }
        let (a, h) = (self.anchor, self.head);
        // Reading order: by row, then by column.
        Some(if (a.1, a.0) <= (h.1, h.0) {
            (a, h)
        } else {
            (h, a)
        })
    }
}

/// The column after the last cell of `row` that holds something to read: blank cells at the end
/// of a row are not text, neither highlighted nor copied.
fn text_end(buf: &Buffer, row: u16) -> u16 {
    let width = buf.area.width;
    (0..width)
        .rev()
        .find(|&x| {
            buf.cell((x, row))
                .is_some_and(|c| !c.symbol().trim().is_empty())
        })
        .map_or(0, |x| x + 1)
}

/// The columns of `row` that `range` covers, as `from..to` (half open, within the text).
fn row_span(buf: &Buffer, range: (Cell, Cell), row: u16) -> (u16, u16) {
    let ((c0, r0), (c1, r1)) = range;
    let from = if row == r0 { c0 } else { 0 };
    let to = if row == r1 {
        c1.saturating_add(1)
    } else {
        buf.area.width
    };
    (from, to.min(text_end(buf, row)))
}

/// Shows the selection: its cells get the theme's selection background and keep their text colour,
/// so what is selected reads as it did and the band is seen on a light terminal as on a dark one.
/// Where the terminal's background is not known (or colour is off) the cells swap foreground and
/// background instead.
pub fn paint(buf: &mut Buffer, range: (Cell, Cell), theme: Theme) {
    let band = theme.selection();
    let last = buf.area.height.saturating_sub(1);
    for row in range.0 .1.min(last)..=range.1 .1.min(last) {
        let (from, to) = row_span(buf, range, row);
        for x in from..to {
            if let Some(cell) = buf.cell_mut((x, row)) {
                if let Some(bg) = band {
                    // Reversed, the band would become the text colour.
                    cell.modifier.remove(Modifier::REVERSED);
                    cell.bg = bg;
                } else if cell.modifier.contains(Modifier::REVERSED) {
                    // A cell the screen already draws reversed would vanish into its neighbours.
                    cell.modifier.remove(Modifier::REVERSED);
                } else {
                    cell.modifier.insert(Modifier::REVERSED);
                }
            }
        }
    }
}

/// The text of the selection: one line per row, nothing trailing, and the indentation every row
/// shares (the screen's own two-column margin) taken off.
#[must_use]
pub fn text(buf: &Buffer, range: (Cell, Cell)) -> String {
    let last = buf.area.height.saturating_sub(1);
    let mut rows: Vec<(String, bool)> = Vec::new();
    for row in range.0 .1.min(last)..=range.1 .1.min(last) {
        let (from, to) = row_span(buf, range, row);
        let mut line = String::new();
        // The cells a wide character covers after its own hold a blank that is not text.
        let mut covered = 0u16;
        for x in 0..to {
            if covered > 0 {
                covered -= 1;
                continue;
            }
            let Some(cell) = buf.cell((x, row)) else {
                break;
            };
            let symbol = cell.symbol();
            covered = u16::try_from(symbol.width().saturating_sub(1)).unwrap_or(0);
            if x >= from {
                line.push_str(symbol);
            }
        }
        // A row that starts partway in keeps its own indentation: it is not the margin.
        rows.push((line.trim_end().to_string(), from == 0));
    }
    let margin = rows
        .iter()
        .filter(|(line, whole)| *whole && !line.is_empty())
        .map(|(line, _)| line.len() - line.trim_start_matches(' ').len())
        .min()
        .unwrap_or(0);
    let lines: Vec<&str> = rows
        .iter()
        .map(|(line, whole)| {
            if *whole {
                line.get(margin..).unwrap_or("")
            } else {
                line.as_str()
            }
        })
        .collect();
    lines.join("\n").trim_matches('\n').to_string()
}

/// The escape sequence that asks the terminal to put `text` on the clipboard (OSC 52).
#[must_use]
pub fn osc52(text: &str) -> Vec<u8> {
    let mut out = b"\x1b]52;c;".to_vec();
    out.extend_from_slice(base64(text.as_bytes()).as_bytes());
    out.push(0x07);
    out
}

fn base64(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let n = chunk
            .iter()
            .enumerate()
            .fold(0u32, |n, (i, b)| n | (u32::from(*b) << (16 - 8 * i)));
        for i in 0..4 {
            if i <= chunk.len() {
                out.push(char::from(ALPHABET[((n >> (18 - 6 * i)) & 63) as usize]));
            } else {
                out.push('=');
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratatui::{layout::Rect, style::Style};

    fn screen(rows: &[&str]) -> Buffer {
        let width = rows.iter().map(|r| r.width()).max().unwrap_or(0);
        let mut buf = Buffer::empty(Rect::new(
            0,
            0,
            u16::try_from(width + 4).expect("in range"),
            u16::try_from(rows.len()).expect("in range"),
        ));
        for (y, row) in rows.iter().enumerate() {
            buf.set_string(
                0,
                u16::try_from(y).expect("in range"),
                row,
                Style::default(),
            );
        }
        buf
    }

    #[test]
    fn a_click_selects_nothing_and_a_drag_in_either_direction_gives_the_same_range() {
        let mut s = Selection::begin((3, 1));
        assert_eq!(
            s.range(),
            None,
            "a button that has not left its cell is a click"
        );
        s.drag((1, 0));
        assert_eq!(s.range(), Some(((1, 0), (3, 1))));
        s.drag((5, 1));
        assert_eq!(s.range(), Some(((3, 1), (5, 1))));
    }

    #[test]
    fn rows_run_from_the_first_cell_to_the_last_with_whole_rows_between() {
        let buf = screen(&["alpha beta", "gamma", "delta epsilon"]);
        assert_eq!(text(&buf, ((6, 0), (4, 2))), "beta\ngamma\ndelta");
        assert_eq!(text(&buf, ((2, 0), (4, 0))), "pha");
    }

    #[test]
    fn nothing_blank_at_the_end_of_a_row_is_copied_or_painted() {
        let mut buf = screen(&["ab", "", "cd"]);
        // The drag ends far to the right of the text.
        assert_eq!(text(&buf, ((0, 0), (30, 2))), "ab\n\ncd");
        paint(&mut buf, ((0, 0), (30, 2)), Theme::plain());
        assert!(buf
            .cell((1, 0))
            .expect("in range")
            .modifier
            .contains(Modifier::REVERSED));
        assert!(!buf
            .cell((2, 0))
            .expect("in range")
            .modifier
            .contains(Modifier::REVERSED));
        assert!(!buf
            .cell((0, 1))
            .expect("in range")
            .modifier
            .contains(Modifier::REVERSED));
    }

    #[test]
    fn the_margin_every_row_shares_stays_on_the_screen() {
        let buf = screen(&["  fn main() {", "      body();", "  }"]);
        assert_eq!(text(&buf, ((0, 0), (20, 2))), "fn main() {\n    body();\n}");
        // A row that starts partway in is kept as it is.
        assert_eq!(text(&buf, ((6, 1), (20, 1))), "body();");
    }

    #[test]
    fn only_spaces_are_a_margin_so_other_leading_blanks_never_cut_a_character() {
        let buf = screen(&["\u{3000}wide blank", "  plain"]);
        // A row that starts with an ideographic space has no margin to share: nothing is cut.
        assert_eq!(text(&buf, ((0, 0), (20, 1))), "\u{3000}wide blank\n  plain");
    }

    #[test]
    fn a_wide_character_is_copied_once() {
        let buf = screen(&["日本語 ok"]);
        assert_eq!(text(&buf, ((0, 0), (20, 0))), "日本語 ok");
    }

    #[test]
    fn without_a_known_background_what_is_painted_twice_is_back_as_it_was() {
        let mut buf = screen(&["abc"]);
        let was = buf.clone();
        paint(&mut buf, ((0, 0), (2, 0)), Theme::plain());
        assert_ne!(buf, was);
        paint(&mut buf, ((0, 0), (2, 0)), Theme::plain());
        assert_eq!(buf, was);
    }

    #[test]
    fn with_a_known_background_the_band_replaces_it_and_the_text_keeps_its_colour() {
        let theme = Theme::banded((255, 255, 255));
        let mut buf = Buffer::empty(ratatui::layout::Rect::new(0, 0, 6, 1));
        buf.set_string(
            0,
            0,
            "abc",
            Style::default()
                .fg(ratatui::style::Color::Rgb(26, 127, 55))
                .bg(ratatui::style::Color::Rgb(1, 2, 3)),
        );
        paint(&mut buf, ((0, 0), (2, 0)), theme);
        let cell = buf.cell((1, 0)).expect("in range");
        assert_eq!(Some(cell.bg), theme.selection());
        assert_eq!(cell.fg, ratatui::style::Color::Rgb(26, 127, 55));
        assert!(!cell.modifier.contains(Modifier::REVERSED));
        assert_ne!(
            buf.cell((4, 0)).expect("in range").bg,
            cell.bg,
            "past the text nothing is painted"
        );
    }

    #[test]
    fn the_clipboard_write_is_base64_with_every_padding() {
        assert_eq!(osc52("hi"), b"\x1b]52;c;aGk=\x07");
        assert_eq!(osc52("a"), b"\x1b]52;c;YQ==\x07");
        assert_eq!(osc52("abc"), b"\x1b]52;c;YWJj\x07");
        assert_eq!(osc52("héllo"), b"\x1b]52;c;aMOpbGxv\x07");
    }
}
