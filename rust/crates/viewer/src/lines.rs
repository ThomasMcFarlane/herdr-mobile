//! Reads lines from the keeper without trusting them: a byte that is not UTF-8 is replaced, not
//! fatal, a line longer than the cap is skipped without being held in memory, and an empty line
//! is nothing. The old `BufRead::lines` ended the whole session at the first bad byte.

use std::io::{self, BufRead};

pub struct Lines<R: BufRead> {
    reader: R,
    cap: usize,
}

impl<R: BufRead> Lines<R> {
    #[must_use]
    pub fn new(reader: R, cap: usize) -> Lines<R> {
        Lines { reader, cap }
    }
}

impl<R: BufRead> Iterator for Lines<R> {
    type Item = io::Result<String>;

    fn next(&mut self) -> Option<Self::Item> {
        let mut line: Vec<u8> = Vec::new();
        let mut oversize = false;
        loop {
            let chunk = match self.reader.fill_buf() {
                Ok(c) => c,
                Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                Err(e) => return Some(Err(e)),
            };
            if chunk.is_empty() {
                // The end: what is left without a newline is a last line.
                return if oversize || line.is_empty() {
                    None
                } else {
                    Some(Ok(finish(&line)))
                };
            }
            let (take, found) = match chunk.iter().position(|b| *b == b'\n') {
                Some(i) => (i + 1, true),
                None => (chunk.len(), false),
            };
            if !oversize {
                if line.len() + take > self.cap {
                    // Too long to hold: forget what was read and skip to its end.
                    oversize = true;
                    line = Vec::new();
                } else {
                    line.extend_from_slice(&chunk[..take]);
                }
            }
            self.reader.consume(take);
            if found {
                if oversize || line.iter().all(u8::is_ascii_whitespace) {
                    oversize = false;
                    line.clear();
                    continue;
                }
                return Some(Ok(finish(&line)));
            }
        }
    }
}

fn finish(line: &[u8]) -> String {
    String::from_utf8_lossy(line)
        .trim_end_matches(['\r', '\n'])
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    fn read(bytes: &[u8], cap: usize) -> Vec<String> {
        Lines::new(Cursor::new(bytes.to_vec()), cap)
            .map(|l| l.expect("no io error"))
            .collect()
    }

    #[test]
    fn a_byte_that_is_not_utf8_costs_one_character_not_the_session() {
        let got = read(b"x\nbad \xff byte\nz\n", 100);
        assert_eq!(got, ["x", "bad \u{fffd} byte", "z"]);
    }

    #[test]
    fn a_line_over_the_cap_is_skipped_and_the_next_one_is_read() {
        let mut data = vec![b'a'; 1000];
        data.extend_from_slice(b"\nok\n");
        assert_eq!(read(&data, 100), ["ok"]);
    }

    #[test]
    fn a_line_longer_than_the_readers_own_buffer_is_still_one_line() {
        let long = "x".repeat(70_000);
        let data = format!("{long}\nnext\n");
        let got: Vec<String> = Lines::new(
            io::BufReader::with_capacity(16, Cursor::new(data.into_bytes())),
            1 << 20,
        )
        .map(|l| l.expect("ok"))
        .collect();
        assert_eq!(got.len(), 2);
        assert_eq!((got[0].len(), got[1].as_str()), (70_000, "next"));
    }

    #[test]
    fn crlf_is_trimmed_blank_lines_are_nothing_and_a_last_line_needs_no_newline() {
        assert_eq!(read(b"a\r\n\r\n   \nb", 100), ["a", "b"]);
        assert!(read(b"", 100).is_empty());
    }

    #[test]
    fn an_oversize_last_line_without_a_newline_is_dropped_too() {
        assert!(read(&vec![b'a'; 500], 100).is_empty());
    }
}
