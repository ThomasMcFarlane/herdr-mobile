//! The input box: multi-line text, a cursor, and sent-message recall.

#[derive(Default)]
pub struct Composer {
    pub text: String,
    /// Byte offset of the cursor, always on a char boundary.
    pub cursor: usize,
    sent: Vec<String>,
    /// Index into [sent] while recalling; None when typing fresh text.
    recall: Option<usize>,
}

impl Composer {
    pub fn insert(&mut self, c: char) {
        self.text.insert(self.cursor, c);
        self.cursor += c.len_utf8();
        self.recall = None;
    }

    /// Inserts a whole string at the cursor in one go (a paste).
    pub fn insert_str(&mut self, s: &str) {
        self.text.insert_str(self.cursor, s);
        self.cursor += s.len();
        self.recall = None;
    }

    pub fn backspace(&mut self) {
        if let Some(p) = self.prev(self.cursor) {
            self.text.drain(p..self.cursor);
            self.cursor = p;
        }
    }

    pub fn delete(&mut self) {
        if let Some(n) = self.next(self.cursor) {
            self.text.drain(self.cursor..n);
        }
    }

    pub fn left(&mut self) {
        if let Some(p) = self.prev(self.cursor) {
            self.cursor = p;
        }
    }

    pub fn right(&mut self) {
        if let Some(n) = self.next(self.cursor) {
            self.cursor = n;
        }
    }

    pub fn home(&mut self) {
        self.cursor = self.text[..self.cursor].rfind('\n').map_or(0, |i| i + 1);
    }

    pub fn end(&mut self) {
        self.cursor = self.text[self.cursor..]
            .find('\n')
            .map_or(self.text.len(), |i| self.cursor + i);
    }

    /// Moves the cursor to the same column on the line above. `false` on the first line.
    pub fn up(&mut self) -> bool {
        let start = self.text[..self.cursor].rfind('\n').map_or(0, |i| i + 1);
        if start == 0 {
            return false;
        }
        let col = self.text[start..self.cursor].chars().count();
        let prev_start = self.text[..start - 1].rfind('\n').map_or(0, |i| i + 1);
        self.cursor = self.at_column(prev_start, start - 1, col);
        true
    }

    /// Moves the cursor to the same column on the line below. `false` on the last line.
    pub fn down(&mut self) -> bool {
        let Some(nl) = self.text[self.cursor..].find('\n').map(|i| self.cursor + i) else {
            return false;
        };
        let start = self.text[..self.cursor].rfind('\n').map_or(0, |i| i + 1);
        let col = self.text[start..self.cursor].chars().count();
        let next_end = self.text[nl + 1..]
            .find('\n')
            .map_or(self.text.len(), |i| nl + 1 + i);
        self.cursor = self.at_column(nl + 1, next_end, col);
        true
    }

    /// Byte offset of column `col` within the line `start..end`, or its end when shorter.
    fn at_column(&self, start: usize, end: usize, col: usize) -> usize {
        self.text[start..end]
            .char_indices()
            .nth(col)
            .map_or(end, |(i, _)| start + i)
    }

    /// Delete the word before the cursor (Ctrl-W).
    pub fn kill_word(&mut self) {
        let head = &self.text[..self.cursor];
        let trimmed = head.trim_end();
        let at = trimmed.rfind(char::is_whitespace).map_or(0, |i| i + 1);
        self.text.drain(at..self.cursor);
        self.cursor = at;
    }

    pub fn clear(&mut self) {
        self.text.clear();
        self.cursor = 0;
        self.recall = None;
    }

    /// Up on the first line: older sent text. Returns false when it did not
    /// apply, so the caller can scroll instead.
    pub fn older(&mut self) -> bool {
        if self.text[..self.cursor].contains('\n') || self.sent.is_empty() {
            return false;
        }
        if !self.text.is_empty() && self.recall.is_none() {
            return false;
        }
        let i = self
            .recall
            .map_or(self.sent.len() - 1, |i| i.saturating_sub(1));
        self.recall = Some(i);
        self.text = self.sent[i].clone();
        self.cursor = self.text.len();
        true
    }

    pub fn newer(&mut self) -> bool {
        let Some(i) = self.recall else { return false };
        if i + 1 < self.sent.len() {
            self.recall = Some(i + 1);
            self.text = self.sent[i + 1].clone();
        } else {
            self.recall = None;
            self.text.clear();
        }
        self.cursor = self.text.len();
        true
    }

    /// Takes the text to send. Kept for recall; the caller restores it on failure
    /// with [restore], so typed text survives a failed send.
    pub fn take(&mut self) -> Option<String> {
        let t = self.text.trim().to_string();
        if t.is_empty() {
            return None;
        }
        if self.sent.last() != Some(&t) {
            self.sent.push(t.clone());
            if self.sent.len() > 50 {
                self.sent.remove(0);
            }
        }
        self.clear();
        Some(t)
    }

    pub fn restore(&mut self, t: String) {
        if self.text.is_empty() {
            self.cursor = t.len();
            self.text = t;
        }
    }

    fn prev(&self, at: usize) -> Option<usize> {
        self.text[..at].char_indices().next_back().map(|(i, _)| i)
    }

    fn next(&self, at: usize) -> Option<usize> {
        self.text[at..].chars().next().map(|c| at + c.len_utf8())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn edits_respect_multibyte_chars() {
        let mut c = Composer::default();
        for ch in "aé→b".chars() {
            c.insert(ch);
        }
        c.left();
        c.backspace();
        assert_eq!(c.text, "aéb");
        c.home();
        c.delete();
        assert_eq!(c.text, "éb");
    }

    #[test]
    fn recall_walks_sent_text_and_returns_to_empty() {
        let mut c = Composer::default();
        for t in ["one", "two"] {
            t.chars().for_each(|ch| c.insert(ch));
            c.take();
        }
        assert!(c.older());
        assert_eq!(c.text, "two");
        assert!(c.older());
        assert_eq!(c.text, "one");
        assert!(c.newer() && c.newer());
        assert_eq!(c.text, "");
    }

    #[test]
    fn a_failed_send_gets_its_text_back() {
        let mut c = Composer::default();
        "hi".chars().for_each(|ch| c.insert(ch));
        let t = c.take().expect("text was typed");
        c.restore(t);
        assert_eq!(c.text, "hi");
    }

    #[test]
    fn up_and_down_keep_the_column_and_stop_at_the_ends() {
        let mut c = Composer::default();
        for ch in "abcdef\nxy\nlonger line".chars() {
            c.insert(ch);
        }
        assert!(c.up());
        assert_eq!(
            &c.text[c.cursor..],
            "\nlonger line",
            "clamped to the end of the short line"
        );
        c.home();
        c.right();
        assert!(c.up());
        assert_eq!(c.cursor, 1);
        assert!(!c.up(), "first line");
        assert!(c.down() && c.down());
        assert!(!c.down(), "last line");
    }

    #[test]
    fn kill_word_removes_the_last_word() {
        let mut c = Composer::default();
        "foo bar".chars().for_each(|ch| c.insert(ch));
        c.kill_word();
        assert_eq!(c.text, "foo ");
    }
}
