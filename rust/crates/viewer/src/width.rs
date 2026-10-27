//! How many terminal columns text takes, measured the way ratatui's buffer and the terminal
//! measure it: by grapheme cluster, not by `char`.
//!
//! Summing a width per `char` is wrong for a cluster that is more than one char: `⚠️` is U+26A0 and
//! an emoji selector (U+FE0F), which the terminal draws as one two-column cell, but a per-char sum
//! says 1 + 0. A table row holding one came out a column longer than its neighbours and pushed its
//! right border out; the next frame left that cell behind as a stray glyph.

use unicode_segmentation::UnicodeSegmentation;
use unicode_width::UnicodeWidthStr;

/// The columns `s` takes: the sum over its grapheme clusters.
#[must_use]
pub fn of(s: &str) -> usize {
    s.graphemes(true).map(UnicodeWidthStr::width).sum()
}

/// The grapheme clusters of `s` with the columns each takes. Cut text at these boundaries, never
/// between the chars of one.
pub fn clusters(s: &str) -> impl Iterator<Item = (&str, usize)> {
    s.graphemes(true).map(|g| (g, UnicodeWidthStr::width(g)))
}

/// The grapheme clusters of `s` with their byte offsets and columns.
pub fn cluster_indices(s: &str) -> impl Iterator<Item = (usize, &str, usize)> {
    s.grapheme_indices(true)
        .map(|(i, g)| (i, g, UnicodeWidthStr::width(g)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_symbol_with_an_emoji_selector_is_one_cell_of_two_columns() {
        assert_eq!(of("⚠️"), 2);
        assert_eq!(of("⚠"), 1, "without the selector it is text");
        assert_eq!(of("❤️✔️"), 4);
        assert_eq!(of("✅"), 2);
        assert_eq!(of("●○◐"), 3);
        assert_eq!(of("a⚠️b"), 4);
        assert_eq!(of("e\u{301}"), 1, "a letter and its accent");
        assert_eq!(of("日本"), 4);
        assert_eq!(of(""), 0);
    }

    #[test]
    fn clusters_are_never_cut_between_the_chars_of_one() {
        let got: Vec<(&str, usize)> = clusters("a⚠️b").collect();
        assert_eq!(got, [("a", 1), ("⚠️", 2), ("b", 1)]);
        let at: Vec<usize> = cluster_indices("a⚠️b").map(|(i, _, _)| i).collect();
        assert_eq!(
            at,
            [0, 1, 7],
            "the selector's three bytes stay with its symbol"
        );
    }
}
