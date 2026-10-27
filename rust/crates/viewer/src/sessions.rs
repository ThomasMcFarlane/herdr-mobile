//! `herdr-tui ls`: the sessions on this machine as a table, what needs you first. Pure: the
//! records go in, text comes out, so the order, the words and the fit are testable.

use crate::width;
use keeper::records::{Info, State};

/// A session as one table row.
#[derive(Debug, PartialEq, Eq)]
pub struct Row {
    pub id: String,
    pub agent: String,
    pub state: &'static str,
    /// Sort key: what needs the person first, then what works, what idles, what ended.
    rank: u8,
    pub place: String,
    pub age: String,
    pub viewers: u32,
    pub title: String,
}

fn state_of(i: &Info) -> (&'static str, u8) {
    match i.state {
        State::Exited => ("exited", 4),
        State::Starting => ("starting", 3),
        State::Running if i.pending > 0 => ("needs you", 0),
        State::Running if i.turn_active => ("working", 1),
        State::Running => ("idle", 2),
    }
}

/// `5s`, `12m`, `3h 05m`, `2d`.
#[must_use]
pub fn ago(secs: i64) -> String {
    match secs.max(0) {
        s @ 0..=59 => format!("{s}s"),
        s @ 60..=3599 => format!("{}m", s / 60),
        s @ 3600..=86_399 => format!("{}h {:02}m", s / 3600, s % 3600 / 60),
        s => format!("{}d", s / 86_400),
    }
}

/// `path` with `home` as `~`, then cut from the left (the end of a path is the part that tells
/// folders apart) to `width` columns.
#[must_use]
pub fn place(path: &str, home: &str, width: usize) -> String {
    let short = match path.strip_prefix(home) {
        Some(rest) if !home.is_empty() && (rest.is_empty() || rest.starts_with('/')) => {
            format!("~{rest}")
        }
        _ => path.to_string(),
    };
    if width::of(&short) <= width {
        return short;
    }
    // The last clusters that fit beside the ellipsis, never half of one.
    let room = width.saturating_sub(1);
    let (mut used, mut from) = (0, short.len());
    for (i, _, w) in width::cluster_indices(&short)
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
    {
        if used + w > room {
            break;
        }
        used += w;
        from = i;
    }
    format!("…{}", &short[from..])
}

/// `s` padded with spaces on the right to `to` columns (`{:w$}` pads by char, which misaligns
/// wide and combining text).
fn pad(s: &str, to: usize) -> String {
    format!("{s}{}", " ".repeat(to.saturating_sub(width::of(s))))
}

/// The first `max` columns of `s`, cut between clusters.
fn cut(s: &str, max: usize) -> &str {
    let mut used = 0;
    for (i, _, w) in width::cluster_indices(s) {
        if used + w > max {
            return &s[..i];
        }
        used += w;
    }
    s
}

#[must_use]
pub fn rows(infos: &[Info], now_ms: i64, home: &str) -> Vec<Row> {
    let mut rows: Vec<Row> = infos
        .iter()
        .map(|i| {
            let (state, rank) = state_of(i);
            let since = i.started_at.map_or(0, |t| (now_ms - t) / 1000);
            Row {
                id: i.id.clone(),
                agent: keeper::routes::by_id(&i.agent).map_or_else(|| i.agent.clone(), |r| r.label),
                state,
                rank,
                place: place(&i.cwd, home, 40),
                age: ago(since),
                viewers: i.clients,
                title: crate::md::one_line(
                    i.extra.get("title").and_then(|t| t.as_str()).unwrap_or(""),
                    80,
                ),
            }
        })
        .collect();
    // Newest first within a state.
    rows.sort_by_key(|r| r.rank);
    rows
}

/// The table, at most `width` columns wide. Sessions that have exited are left out unless `all`.
#[must_use]
pub fn render(rows: &[Row], all: bool, width: usize) -> String {
    let (shown, hidden): (Vec<&Row>, usize) = if all {
        (rows.iter().collect(), 0)
    } else {
        (
            rows.iter().filter(|r| r.rank < 4).collect(),
            rows.iter().filter(|r| r.rank == 4).count(),
        )
    };
    let mut out = String::new();
    if shown.is_empty() {
        out.push_str("No sessions are running on this machine. Start one with `herdr-tui`.\n");
    } else {
        let col = |f: &dyn Fn(&Row) -> usize, head: &str| {
            shown
                .iter()
                .map(|r| f(r))
                .max()
                .unwrap_or(0)
                .max(head.len())
        };
        let (wi, wa, ws, wp, wg) = (
            col(&|r| r.id.len(), "ID"),
            col(&|r| width::of(&r.agent), "AGENT"),
            col(&|r| r.state.len(), "STATE"),
            col(&|r| width::of(&r.place), "WHERE"),
            col(&|r| r.age.len(), "AGE"),
        );
        let fixed = wi + wa + ws + wp + wg + 2 + 5 * 2 + 3;
        out.push_str(&format!(
            "{:wi$}  {:wa$}  {:ws$}  {:wp$}  {:>wg$}  {:>2}  TITLE\n",
            "ID", "AGENT", "STATE", "WHERE", "AGE", "ON"
        ));
        for r in shown {
            let title = cut(&r.title, width.saturating_sub(fixed).max(10));
            out.push_str(&format!(
                "{:wi$}  {}  {:ws$}  {}  {:>wg$}  {:>2}  {}\n",
                r.id,
                pad(&r.agent, wa),
                r.state,
                pad(&r.place, wp),
                r.age,
                if r.viewers > 0 {
                    r.viewers.to_string()
                } else {
                    "·".to_string()
                },
                title.trim_end()
            ));
        }
        out.push_str("\nON is how many clients are attached. Open one: herdr-tui attach ID. End one: herdr-tui kill ID.\n");
    }
    if hidden > 0 {
        out.push_str(&format!(
            "{hidden} exited (herdr-tui ls --all shows them).\n"
        ));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn info(id: &str, state: State, pending: u32, turn: bool, cwd: &str, started: i64) -> Info {
        Info {
            id: id.into(),
            agent: "omp".into(),
            cwd: cwd.into(),
            state,
            pending,
            turn_active: turn,
            started_at: Some(started),
            ..Info::default()
        }
    }

    #[test]
    fn what_needs_you_comes_first_then_what_works_then_what_idles_and_the_ended_last() {
        let infos = [
            info("idle11", State::Running, 0, false, "/h/a", 0),
            info("done11", State::Exited, 0, false, "/h/b", 0),
            info("work11", State::Running, 0, true, "/h/c", 0),
            info("need11", State::Running, 2, true, "/h/d", 0),
        ];
        let got: Vec<(String, &str)> = rows(&infos, 10_000, "/h")
            .into_iter()
            .map(|r| (r.id, r.state))
            .collect();
        assert_eq!(
            got,
            [
                ("need11".into(), "needs you"),
                ("work11".into(), "working"),
                ("idle11".into(), "idle"),
                ("done11".into(), "exited")
            ]
        );
    }

    #[test]
    fn the_table_names_the_agent_the_place_the_age_and_how_to_use_it() {
        let mut i = info(
            "abc123",
            State::Running,
            0,
            true,
            "/home/me/work/herdr-mobile",
            0,
        );
        i.clients = 1;
        i.extra.insert("title".into(), "Fix the flaky test".into());
        let text = render(
            &rows(&[i], 3 * 3600 * 1000 + 300_000, "/home/me"),
            false,
            100,
        );
        assert!(
            text.contains("abc123") && text.contains("omp") && text.contains("working"),
            "{text}"
        );
        assert!(
            text.contains("~/work/herdr-mobile")
                && text.contains("3h 05m")
                && text.contains("Fix the flaky test"),
            "{text}"
        );
        assert!(
            text.contains("herdr-tui attach ID") && text.contains("herdr-tui kill ID"),
            "{text}"
        );
    }

    #[test]
    fn exited_sessions_are_counted_not_listed_unless_asked() {
        let infos = [
            info("live11", State::Running, 0, false, "/x", 0),
            info("dead11", State::Exited, 0, false, "/x", 0),
        ];
        let r = rows(&infos, 1000, "/h");
        let quiet = render(&r, false, 100);
        assert!(
            quiet.contains("live11") && !quiet.contains("dead11") && quiet.contains("1 exited"),
            "{quiet}"
        );
        assert!(render(&r, true, 100).contains("dead11"));
    }

    #[test]
    fn with_nothing_running_it_says_how_to_start() {
        assert!(render(&[], false, 80).contains("Start one with `herdr-tui`"));
    }

    #[test]
    fn a_long_path_keeps_its_end_and_a_row_fits_the_width() {
        let p = place(
            "/home/me/work/a/very/long/path/to/herdr-mobile/rust",
            "/home/me",
            24,
        );
        assert!(
            p.starts_with('…') && p.ends_with("herdr-mobile/rust") && width::of(&p) <= 24,
            "{p}"
        );
        assert_eq!(place("/home/me", "/home/me", 20), "~");
        assert_eq!(place("/other/x", "/home/me", 20), "/other/x");
        assert_eq!(
            place("/home/meow/x", "/home/me", 20),
            "/home/meow/x",
            "a different folder that merely starts with the same letters"
        );
        let mut i = info("abc123", State::Running, 0, false, "/x", 0);
        i.extra.insert("title".into(), "t".repeat(300).into());
        let text = render(&rows(&[i], 0, "/h"), false, 80);
        assert!(
            text.lines().all(|l| l.chars().count() <= 100),
            "titles are cut: {text}"
        );
    }

    #[test]
    fn wide_text_keeps_the_columns_lined_up_and_is_cut_between_clusters() {
        let p = place("/home/me/日本語のフォルダ/日本語", "/home/me", 12);
        assert!(p.starts_with('…') && width::of(&p) <= 12, "{p}");
        let mut a = info("aaaaaa", State::Running, 0, false, "/日本語/x", 0);
        a.extra.insert("title".into(), "😀".repeat(60).into());
        let b = info("bbbbbb", State::Running, 0, false, "/abc/x", 1);
        let text = render(&rows(&[a, b], 0, "/h"), false, 60);
        let at: Vec<usize> = text
            .lines()
            .filter(|l| l.contains(" 0s  "))
            .map(|l| width::of(&l[..l.find(" 0s  ").unwrap_or(0)]))
            .collect();
        assert_eq!(at.len(), 2, "{text}");
        assert_eq!(at[0], at[1], "the AGE column lines up: {text}");
        assert!(text.lines().take(3).all(|l| width::of(l) <= 60), "{text}");
    }

    #[test]
    fn ages_read_at_a_glance() {
        assert_eq!(
            [ago(5), ago(125), ago(3 * 3600 + 5 * 60), ago(3 * 86_400)],
            ["5s", "2m", "3h 05m", "3d"]
        );
        assert_eq!(ago(-4), "0s");
    }
}
