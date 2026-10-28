//! What an update tells the person as it goes: the steps, and the download as a bar that fills.
//! The drawing is pure (a line for a width), so it is tested without a terminal.

/// What [`super::run`] tells the screen as it goes.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Event<'a> {
    /// A step begins.
    Step(&'a str),
    /// A file is arriving: bytes so far, the whole size when the server said it, bytes a second.
    Bytes {
        label: &'a str,
        done: u64,
        total: Option<u64>,
        per_sec: f64,
    },
    /// The file has arrived.
    Finished,
}

/// A size as a person reads it: `812 KB`, `2.5 MB`.
#[must_use]
fn human(bytes: u64) -> String {
    #[allow(clippy::cast_precision_loss)]
    let b = bytes as f64;
    if b >= 999_500.0 {
        format!("{:.1} MB", b / 1_000_000.0)
    } else if b >= 1_000.0 {
        format!("{:.0} KB", b / 1_000.0)
    } else {
        format!("{bytes} B")
    }
}

/// A bar `width` cells wide, filled to `frac` (0 to 1) in eighths of a cell, so it grows smoothly
/// rather than a cell at a time.
#[must_use]
fn bar(frac: f64, width: usize) -> String {
    const EIGHTHS: [char; 8] = [
        ' ', '\u{258f}', '\u{258e}', '\u{258d}', '\u{258c}', '\u{258b}', '\u{258a}', '\u{2589}',
    ];
    #[allow(
        clippy::cast_precision_loss,
        clippy::cast_possible_truncation,
        clippy::cast_sign_loss
    )]
    let eighths = (frac.clamp(0.0, 1.0) * (width * 8) as f64).round() as usize;
    let (full, part) = (eighths / 8, eighths % 8);
    let mut out = "\u{2588}".repeat(full);
    if full < width {
        out.push(EIGHTHS[part]);
        out.push_str(&" ".repeat(width - full - 1));
    }
    out
}

/// The widest the bar is drawn, and the narrowest it is worth drawing.
const BAR_MAX: usize = 28;
const BAR_MIN: usize = 8;

/// The progress line, always shorter than `width` so it never wraps (a wrapped line cannot be
/// redrawn in place): what, a bar, the share, the sizes and the speed. On a narrow terminal the
/// bar shrinks first, then the speed, the sizes and the label go. Without a known total the bar
/// is left out and only what has arrived is said.
#[must_use]
fn progress_line(label: &str, done: u64, total: Option<u64>, per_sec: f64, width: usize) -> String {
    let budget = width.saturating_sub(1);
    #[allow(
        clippy::cast_precision_loss,
        clippy::cast_possible_truncation,
        clippy::cast_sign_loss
    )]
    let speed = if per_sec >= 1.0 {
        format!("  {}/s", human(per_sec as u64))
    } else {
        String::new()
    };
    let Some(total) = total.filter(|t| *t > 0) else {
        let said = format!("{label}  {}{speed}", human(done));
        return if said.chars().count() <= budget {
            said
        } else {
            human(done)
        };
    };
    #[allow(clippy::cast_precision_loss)]
    let frac = (done as f64 / total as f64).min(1.0);
    #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
    let pct = (frac * 100.0).round() as u32;
    let sizes = format!("  {} / {}", human(done), human(total));
    let attempts = [
        (label, format!("{sizes}{speed}")),
        (label, sizes),
        (label, String::new()),
        ("", String::new()),
    ];
    for (label, tail) in &attempts {
        let lead = if label.is_empty() {
            String::new()
        } else {
            format!("{label}  ")
        };
        let rest = format!(" {pct:>3}%{tail}");
        // Two more cells for the ends of the bar.
        let used = lead.chars().count() + 2 + rest.chars().count();
        if let Some(room) = budget.checked_sub(used).filter(|r| *r >= BAR_MIN) {
            return format!(
                "{lead}\u{2595}{}\u{258f}{rest}",
                bar(frac, room.min(BAR_MAX))
            );
        }
    }
    format!("{pct:>3}%")
}

/// Where an update draws, which decides how: a terminal gets one line that is redrawn (in colour
/// unless the person turned it off), anything else gets plain lines.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Output {
    Plain,
    Terminal { colour: bool },
}

/// Draws [`Event`]s on stderr: on a terminal one line that is redrawn as the download grows, else
/// one plain line per step (a log or a pipe gets no control characters).
#[derive(Debug)]
pub struct Console {
    output: Output,
    drawn: bool,
}

impl Console {
    #[must_use]
    pub fn new(output: Output) -> Console {
        Console {
            output,
            drawn: false,
        }
    }

    /// Shows one [`Event`]; nothing here can fail the update, so a closed stderr is ignored.
    pub fn event(&mut self, e: &Event) {
        use std::io::Write;
        let mut err = std::io::stderr();
        match e {
            Event::Step(what) => {
                let _ = writeln!(err, "herdr-tui: {what}");
            }
            Event::Bytes {
                label,
                done,
                total,
                per_sec,
            } => {
                if let Output::Terminal { colour } = self.output {
                    let width = crossterm::terminal::size().map_or(80, |(w, _)| usize::from(w));
                    let line = progress_line(label, *done, *total, *per_sec, width);
                    let (on, off) = if colour {
                        ("\x1b[36m", "\x1b[0m")
                    } else {
                        ("", "")
                    };
                    let _ = write!(err, "\r\x1b[2K{on}{line}{off}");
                    let _ = err.flush();
                    self.drawn = true;
                }
            }
            Event::Finished => {
                if std::mem::take(&mut self.drawn) {
                    let _ = writeln!(err);
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sizes_read_as_a_person_says_them() {
        assert_eq!(human(812), "812 B");
        assert_eq!(human(812_345), "812 KB");
        assert_eq!(human(2_527_000), "2.5 MB");
        assert_eq!(human(999_499), "999 KB");
        assert_eq!(human(999_700), "1.0 MB", "never `1000 KB`");
    }

    #[test]
    fn the_bar_fills_in_eighths_never_past_its_width_and_keeps_its_width() {
        for width in [1, 10, 28] {
            for step in 0..=40 {
                let b = bar(f64::from(step) / 40.0, width);
                assert_eq!(b.chars().count(), width, "{step}/40 of {width}: {b:?}");
            }
        }
        assert_eq!(bar(0.0, 4), "    ");
        assert_eq!(bar(1.0, 4), "\u{2588}\u{2588}\u{2588}\u{2588}");
        assert_eq!(bar(0.5, 4), "\u{2588}\u{2588}  ");
        assert_eq!(bar(0.375, 4), "\u{2588}\u{258c}  ");
        assert_eq!(bar(7.0, 4), bar(1.0, 4), "over is full");
        assert_eq!(bar(-1.0, 4), bar(0.0, 4));
    }

    #[test]
    fn a_progress_line_says_the_share_the_sizes_and_the_speed_and_copes_without_a_total() {
        let l = progress_line(
            "herdr-tui-linux-x86_64",
            1_300_000,
            Some(2_600_000),
            1_200_000.0,
            100,
        );
        assert!(
            l.contains(" 50%") && l.contains("1.3 MB / 2.6 MB") && l.contains("1.2 MB/s"),
            "{l}"
        );
        let done = progress_line("x", 9, Some(5), 0.0, 100);
        assert!(done.contains("100%"), "never past 100%: {done}");
        let unknown = progress_line("x", 2_000, None, 0.0, 100);
        assert_eq!(unknown, "x  2 KB");
        assert!(!progress_line("x", 0, Some(0), 0.0, 100).contains("NaN"));
    }

    #[test]
    fn a_progress_line_never_reaches_the_last_column_so_it_can_be_redrawn_in_place() {
        for width in 8..=140 {
            for (done, total) in [
                (0, Some(2_600_000)),
                (1_300_000, Some(2_600_000)),
                (2_600_000, Some(2_600_000)),
                (1_300_000, None),
            ] {
                let l = progress_line("herdr-tui-linux-x86_64", done, total, 1_200_000.0, width);
                assert!(l.chars().count() < width, "{width} columns: {l:?}");
            }
        }
    }
}
