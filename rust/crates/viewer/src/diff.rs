//! A change as a hunk: the lines that differ with the common head and tail trimmed.

use crate::transcript::Diff;

/// Removed rows first, then added, with a row of context either side, and the counts.
#[derive(Debug, PartialEq, Eq)]
pub struct Hunk {
    pub rows: Vec<(char, String)>,
    pub added: usize,
    pub removed: usize,
}

#[must_use]
pub fn hunk(d: &Diff) -> Hunk {
    let old: Vec<&str> = d
        .old
        .as_deref()
        .map_or_else(Vec::new, |o| o.lines().collect());
    let new: Vec<&str> = d.new.lines().collect();
    let head = old.iter().zip(&new).take_while(|(a, b)| a == b).count();
    let tail = old[head..]
        .iter()
        .rev()
        .zip(new[head..].iter().rev())
        .take_while(|(a, b)| a == b)
        .count();
    let removed = &old[head..old.len() - tail];
    let added = &new[head..new.len() - tail];
    let mut rows = Vec::new();
    if head > 0 {
        rows.push((' ', old[head - 1].to_string()));
    }
    rows.extend(removed.iter().map(|l| ('-', (*l).to_string())));
    rows.extend(added.iter().map(|l| ('+', (*l).to_string())));
    if tail > 0 {
        rows.push((' ', old[old.len() - tail].to_string()));
    }
    Hunk {
        rows,
        added: added.len(),
        removed: removed.len(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn diff(old: Option<&str>, new: &str) -> Diff {
        Diff {
            path: "a".into(),
            old: old.map(str::to_string),
            new: new.into(),
        }
    }

    #[test]
    fn only_what_changed_shows_with_a_row_of_context() {
        let h = hunk(&diff(Some("a\nb\nc\nd"), "a\nb\nX\nY\nd"));
        assert_eq!((h.added, h.removed), (2, 1));
        assert_eq!(h.rows.iter().map(|(m, _)| *m).collect::<String>(), " -++ ");
        assert_eq!(h.rows[1].1, "c");
    }

    #[test]
    fn a_new_file_is_all_additions_and_no_change_is_empty() {
        assert_eq!(hunk(&diff(None, "x\ny")).added, 2);
        let same = hunk(&diff(Some("a\nb"), "a\nb"));
        assert_eq!((same.added, same.removed), (0, 0));
    }
}
