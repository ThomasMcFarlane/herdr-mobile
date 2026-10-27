//! What can be folded, and how the person moves among it. Pure.
//!
//! A *block* is what the screen treats as one thing: a message, a note, one tool call, or a
//! run of finished tool calls. A run of three or more finished calls followed by something
//! else folds into one line (outcome first, process one key down); while the turn still
//! runs its rows show live. Failures are never folded away.

use crate::transcript::{Entry, Item, Role, Tool};
use acp::ToolStatus;
use std::collections::{HashSet, VecDeque};

/// A run is named by its first call's id with this bit set, so that opening the run and opening
/// that call are two different things.
const RUN_BIT: u64 = 1 << 63;

/// A run of at least this many finished tool calls folds.
const GROUP_MIN: usize = 3;
/// Diff rows shown before the rest folds.
pub const DIFF_FOLDED_ROWS: usize = 6;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Block {
    /// One item.
    One(usize),
    /// A run of tool calls `start..end`. `open`: unfolded, its calls follow as `One` blocks.
    Run {
        start: usize,
        end: usize,
        open: bool,
    },
}

fn is_tool(item: &Item) -> bool {
    matches!(item.entry, Entry::Tool(_))
}

fn finished(item: &Item) -> bool {
    matches!(&item.entry, Entry::Tool(t) if matches!(t.status, ToolStatus::Completed | ToolStatus::Failed))
}

/// The blocks of `items`, oldest first. A run is only a run once something follows it
/// and every call in it has finished.
#[must_use]
pub fn blocks(items: &VecDeque<Item>, expanded: &HashSet<u64>) -> Vec<Block> {
    let mut out = Vec::new();
    let mut i = 0;
    while i < items.len() {
        if !is_tool(&items[i]) {
            out.push(Block::One(i));
            i += 1;
            continue;
        }
        let start = i;
        while i < items.len() && is_tool(&items[i]) {
            i += 1;
        }
        let closed = i < items.len() && (start..i).all(|k| finished(&items[k]));
        if closed && i - start >= GROUP_MIN {
            let open = expanded.contains(&(items[start].id | RUN_BIT));
            out.push(Block::Run {
                start,
                end: i,
                open,
            });
            if open {
                out.extend((start..i).map(Block::One));
            }
        } else {
            out.extend((start..i).map(Block::One));
        }
    }
    out
}

/// The id that names a block (for focus and for what is unfolded).
#[must_use]
pub fn key(b: Block, items: &VecDeque<Item>) -> u64 {
    match b {
        Block::One(i) => items[i].id,
        Block::Run { start, .. } => items[start].id | RUN_BIT,
    }
}

/// Whether the block has something to unfold.
#[must_use]
pub fn foldable(b: Block, items: &VecDeque<Item>) -> bool {
    match b {
        Block::Run { .. } => true,
        Block::One(i) => match &items[i].entry {
            Entry::Message {
                role: Role::Thought,
                ..
            } => true,
            Entry::Tool(t) => tool_foldable(t),
            _ => false,
        },
    }
}

#[must_use]
pub fn tool_foldable(t: &Tool) -> bool {
    !t.output.head.is_empty()
        || !t.output.tail.is_empty()
        || t.diffs
            .first()
            .is_some_and(|d| crate::diff::hunk(d).rows.len() > DIFF_FOLDED_ROWS)
        || t.subject.as_deref().is_some_and(|s| s.contains('\n'))
}

/// The keys of the blocks the person can move among, oldest first.
#[must_use]
pub fn focusable(items: &VecDeque<Item>, expanded: &HashSet<u64>) -> Vec<u64> {
    blocks(items, expanded)
        .into_iter()
        .filter(|b| foldable(*b, items))
        .map(|b| key(b, items))
        .collect()
}

/// What a key press does in browse mode.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Nav {
    Prev,
    Next,
    Open,
    Close,
    OpenAll,
    CloseAll,
}

/// Applies `nav` to the focus. Returns the new focus, and the keys newly opened (to animate).
pub fn navigate(
    nav: Nav,
    focus: u64,
    keys: &[u64],
    expanded: &mut HashSet<u64>,
) -> (u64, Vec<u64>) {
    let at = keys.iter().position(|k| *k == focus);
    match nav {
        Nav::Prev => (
            at.map_or(keys.last().copied(), |i| {
                keys.get(i.saturating_sub(1)).copied()
            })
            .unwrap_or(focus),
            Vec::new(),
        ),
        Nav::Next => (
            at.map_or(keys.first().copied(), |i| {
                keys.get((i + 1).min(keys.len().saturating_sub(1))).copied()
            })
            .unwrap_or(focus),
            Vec::new(),
        ),
        Nav::Open => (
            focus,
            if expanded.insert(focus) {
                vec![focus]
            } else {
                Vec::new()
            },
        ),
        Nav::Close => {
            expanded.remove(&focus);
            (focus, Vec::new())
        }
        Nav::OpenAll => {
            let opened: Vec<u64> = keys
                .iter()
                .copied()
                .filter(|k| expanded.insert(*k))
                .collect();
            (focus, opened)
        }
        Nav::CloseAll => {
            expanded.clear();
            (focus, Vec::new())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::transcript::{Diff, Output, Transcript};
    use acp::SessionUpdate;
    use serde_json::json;

    fn tool(t: &mut Transcript, id: &str, status: &str) {
        t.apply(SessionUpdate::from_value(&json!({"sessionUpdate": "tool_call", "toolCallId": id, "title": format!("Read {id}"), "status": status})).expect("update"));
    }

    fn say(t: &mut Transcript, text: &str) {
        t.apply(SessionUpdate::from_value(&json!({"sessionUpdate": "agent_message_chunk", "messageId": text, "content": {"type": "text", "text": text}})).expect("update"));
    }

    fn kinds(b: &[Block]) -> Vec<&'static str> {
        b.iter()
            .map(|b| match b {
                Block::One(_) => "one",
                Block::Run { open: false, .. } => "run",
                Block::Run { open: true, .. } => "run-open",
            })
            .collect()
    }

    #[test]
    fn three_finished_calls_followed_by_something_fold_into_one_run() {
        let mut t = Transcript::default();
        for id in ["a", "b", "c"] {
            tool(&mut t, id, "completed");
        }
        // Nothing follows yet: the turn may still add calls, so the rows show live.
        assert_eq!(
            kinds(&blocks(t.items(), &HashSet::new())),
            ["one", "one", "one"]
        );
        say(&mut t, "done");
        assert_eq!(kinds(&blocks(t.items(), &HashSet::new())), ["run", "one"]);
    }

    #[test]
    fn a_run_with_a_call_still_going_or_fewer_than_three_does_not_fold() {
        let mut t = Transcript::default();
        tool(&mut t, "a", "completed");
        tool(&mut t, "b", "completed");
        say(&mut t, "x");
        assert_eq!(
            kinds(&blocks(t.items(), &HashSet::new())),
            ["one", "one", "one"]
        );
        let mut u = Transcript::default();
        for (id, st) in [("a", "completed"), ("b", "completed"), ("c", "in_progress")] {
            tool(&mut u, id, st);
        }
        say(&mut u, "x");
        assert_eq!(
            kinds(&blocks(u.items(), &HashSet::new())),
            ["one", "one", "one", "one"]
        );
    }

    #[test]
    fn opening_a_run_does_not_open_its_first_call_and_the_other_way_round() {
        let mut t = Transcript::default();
        for id in ["a", "b", "c"] {
            tool(&mut t, id, "completed");
        }
        say(&mut t, "done");
        let first = t.items()[0].id;
        let run = key(blocks(t.items(), &HashSet::new())[0], t.items());
        assert_ne!(
            run, first,
            "a run and its first call are different things to open"
        );
        // Opening the first call alone leaves the run folded.
        assert_eq!(
            kinds(&blocks(t.items(), &HashSet::from([first]))),
            ["run", "one"]
        );
        // Opening the run opens only the run: the calls it lists are still closed.
        let open = HashSet::from([run]);
        assert_eq!(kinds(&blocks(t.items(), &open))[0], "run-open");
        assert!(!open.contains(&first));
    }

    #[test]
    fn opening_a_run_lists_its_calls_after_it() {
        let mut t = Transcript::default();
        for id in ["a", "b", "c"] {
            tool(&mut t, id, "completed");
        }
        say(&mut t, "done");
        let first = t.items()[0].id;
        let open = HashSet::from([first | RUN_BIT]);
        assert_eq!(
            kinds(&blocks(t.items(), &open)),
            ["run-open", "one", "one", "one", "one"]
        );
    }

    #[test]
    fn what_is_foldable_is_a_run_a_thought_and_a_call_with_something_to_show() {
        let mut t = Transcript::default();
        t.apply(SessionUpdate::from_value(&json!({"sessionUpdate": "agent_thought_chunk", "messageId": "t", "content": {"type": "text", "text": "hmm"}})).expect("u"));
        say(&mut t, "answer");
        t.apply(SessionUpdate::from_value(&json!({"sessionUpdate": "tool_call", "toolCallId": "x", "title": "Run", "status": "completed",
            "content": [{"type": "content", "content": {"type": "text", "text": "out"}}]})).expect("u"));
        tool(&mut t, "plain", "completed");
        let b = blocks(t.items(), &HashSet::new());
        let f: Vec<bool> = b.iter().map(|b| foldable(*b, t.items())).collect();
        assert_eq!(f, [true, false, true, false]);
    }

    #[test]
    fn a_small_edit_is_not_foldable_and_a_big_one_is() {
        let small = Tool {
            id: "1".into(),
            title: "e".into(),
            kind: None,
            status: ToolStatus::Completed,
            subject: None,
            output: Output::default(),
            diffs: vec![Diff {
                path: "a".into(),
                old: Some("a".into()),
                new: "b".into(),
            }],
        };
        assert!(!tool_foldable(&small));
        let big = Tool {
            diffs: vec![Diff {
                path: "a".into(),
                old: None,
                new: (0..30)
                    .map(|i| i.to_string())
                    .collect::<Vec<_>>()
                    .join("\n"),
            }],
            ..small
        };
        assert!(tool_foldable(&big));
    }

    #[test]
    fn navigation_moves_between_foldables_and_stops_at_the_ends() {
        let keys = [10, 20, 30];
        let mut open = HashSet::new();
        assert_eq!(navigate(Nav::Next, 10, &keys, &mut open).0, 20);
        assert_eq!(navigate(Nav::Next, 30, &keys, &mut open).0, 30);
        assert_eq!(navigate(Nav::Prev, 10, &keys, &mut open).0, 10);
        assert_eq!(navigate(Nav::Prev, 30, &keys, &mut open).0, 20);
        // A focus that is no longer foldable falls to an end.
        assert_eq!(navigate(Nav::Prev, 99, &keys, &mut open).0, 30);
    }

    #[test]
    fn opening_reports_what_is_new_so_only_that_animates() {
        let keys = [10, 20];
        let mut open = HashSet::new();
        assert_eq!(navigate(Nav::Open, 10, &keys, &mut open).1, [10]);
        assert!(
            navigate(Nav::Open, 10, &keys, &mut open).1.is_empty(),
            "already open"
        );
        assert_eq!(navigate(Nav::OpenAll, 10, &keys, &mut open).1, [20]);
        navigate(Nav::Close, 10, &keys, &mut open);
        assert!(!open.contains(&10) && open.contains(&20));
        navigate(Nav::CloseAll, 10, &keys, &mut open);
        assert!(open.is_empty());
    }
}
