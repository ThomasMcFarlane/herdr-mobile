//! The small human touches: a word for the wait, a tip, a duration read at a glance.
//! Pure and deterministic, so each is testable. None of it moves at rest: the only
//! thing that changes over time is the verb, on the 1 s tick a running turn already has.

const VERBS: [&str; 14] = [
    "Pondering",
    "Untangling",
    "Reading the room",
    "Following the thread",
    "Connecting dots",
    "Poking around",
    "Weighing options",
    "Tracing it down",
    "Sleuthing",
    "Tidying up",
    "Chasing a hunch",
    "Checking the details",
    "Piecing it together",
    "Almost there",
];

const TIPS: [&str; 6] = [
    "Ctrl-T shows what the agent is thinking",
    "Ctrl-J adds a line without sending",
    "↑ brings back your last message",
    "PgUp scrolls back while the agent works",
    "Ctrl-D leaves; the session keeps running and shows on your phone",
    "Ctrl-C stops the turn, never the session",
];

/// Seconds a verb stays before the next one.
const VERB_SECS: u64 = 7;
/// Seconds into a turn before a tip is worth the room.
pub const TIP_AFTER_SECS: u64 = 10;
const TIP_SECS: u64 = 15;

/// The word for the wait, `secs` into turn number `turn`. Changes every few seconds; the
/// turn number keeps two turns from starting on the same word.
#[must_use]
pub fn verb(secs: u64, turn: usize) -> &'static str {
    let step = usize::try_from(secs / VERB_SECS).unwrap_or(0);
    VERBS[(step + turn * 5) % VERBS.len()]
}

/// A tip; `n` picks which.
#[must_use]
pub fn tip(n: usize) -> &'static str {
    TIPS[n % TIPS.len()]
}

/// The tip to show `secs` into a turn, or none yet.
#[must_use]
pub fn tip_for_turn(secs: u64, turn: usize) -> Option<&'static str> {
    (secs >= TIP_AFTER_SECS)
        .then(|| tip(usize::try_from((secs - TIP_AFTER_SECS) / TIP_SECS).unwrap_or(0) + turn))
}

/// `9s`, `1m 12s`, `1h 03m`.
#[must_use]
pub fn duration(secs: u64) -> String {
    match secs {
        0..=59 => format!("{secs}s"),
        60..=3599 => format!("{}m {:02}s", secs / 60, secs % 60),
        _ => format!("{}h {:02}m", secs / 3600, secs % 3600 / 60),
    }
}

/// Braille spinner frames, advanced about every 90 ms.
use std::time::Duration;

const SPINNER: [&str; 10] = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];
const SPINNER_MS: u64 = 90;
/// How long a fold takes to open.
pub const REVEAL_MS: u64 = 160;
/// How fast the sheen crosses a word, and how wide it is.
const SHIMMER_MS: u64 = 70;
const SHIMMER_WIDTH: usize = 3;
/// A request that needs the person pulses at this rate.
const PULSE_MS: u64 = 600;

/// Whether the person wants things to move: `HERDR_TUI_MOTION=off`, `NO_MOTION` or
/// `REDUCED_MOTION` turn it off. A desktop has the battery for it by default.
#[must_use]
pub fn motion_enabled() -> bool {
    let off = |k: &str| {
        std::env::var(k).is_ok_and(|v| {
            !v.is_empty()
                && v != "0"
                && !v.eq_ignore_ascii_case("off")
                && !v.eq_ignore_ascii_case("false")
        })
    };
    let explicitly_off = std::env::var("HERDR_TUI_MOTION").is_ok_and(|v| {
        v == "0" || v.eq_ignore_ascii_case("off") || v.eq_ignore_ascii_case("false")
    });
    !(explicitly_off || off("NO_MOTION") || off("REDUCED_MOTION"))
}

/// The spinner frame at `now_ms`.
#[must_use]
pub fn spinner(now_ms: u64) -> &'static str {
    SPINNER[usize::try_from(now_ms / SPINNER_MS).unwrap_or(0) % SPINNER.len()]
}

/// Which letters of a word of `len` the sheen is on at `now_ms`. It crosses, then rests a beat.
#[must_use]
pub fn shimmer(len: usize, now_ms: u64) -> Vec<bool> {
    let cycle = len + SHIMMER_WIDTH + 6;
    let head = usize::try_from(now_ms / SHIMMER_MS).unwrap_or(0) % cycle;
    (0..len)
        .map(|i| i <= head && head < i + SHIMMER_WIDTH + 1 && head - i < SHIMMER_WIDTH)
        .collect()
}

/// Whether the pulse is on its bright half.
#[must_use]
pub fn pulse(now_ms: u64) -> bool {
    (now_ms / PULSE_MS) % 2 == 0
}

/// How long the loop may sleep before it must draw again, given what is moving. `None`: until
/// something happens, which is what it does at rest, so a still screen costs no wakeups at all.
#[must_use]
pub fn next_wake(motion: bool, working: bool, waiting: bool, revealing: bool) -> Option<Duration> {
    if motion && revealing {
        // An unfold in progress: about 60 frames a second, for the 160 ms it lasts.
        Some(Duration::from_millis(16))
    } else if motion && working {
        Some(Duration::from_millis(SHIMMER_MS))
    } else if working {
        // Only the elapsed counter moves.
        Some(Duration::from_secs(1))
    } else if motion && waiting {
        Some(Duration::from_millis(PULSE_MS / 2))
    } else {
        None
    }
}

/// How many rows of a block that changes from `from` rows to `to` rows show `elapsed_ms` into it.
#[must_use]
pub fn reveal_rows(from: usize, to: usize, elapsed_ms: u64) -> usize {
    let t = ease_out(elapsed_ms);
    let (a, b) = (from as f64, to as f64);
    (a + (b - a) * t).round().max(0.0) as usize
}

/// Ease-out from 0 to 1 over `REVEAL_MS`: fast at first, settling.
#[must_use]
pub fn ease_out(elapsed_ms: u64) -> f64 {
    let t = (elapsed_ms as f64 / REVEAL_MS as f64).clamp(0.0, 1.0);
    1.0 - (1.0 - t) * (1.0 - t)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_verb_holds_for_a_few_seconds_then_changes_and_differs_between_turns() {
        assert_eq!(verb(0, 0), verb(6, 0));
        assert_ne!(verb(6, 0), verb(7, 0));
        assert_ne!(verb(0, 0), verb(0, 1));
        // Never out of range, however long the turn.
        assert!(!verb(u64::MAX, usize::MAX / 8).is_empty());
    }

    #[test]
    fn a_tip_waits_for_a_long_turn_and_then_rotates() {
        assert_eq!(tip_for_turn(9, 0), None);
        assert!(tip_for_turn(10, 0).is_some());
        assert_ne!(tip_for_turn(10, 0), tip_for_turn(25, 0));
    }

    #[test]
    fn durations_read_at_a_glance() {
        assert_eq!(duration(0), "0s");
        assert_eq!(duration(59), "59s");
        assert_eq!(duration(72), "1m 12s");
        assert_eq!(duration(3600 + 180), "1h 03m");
    }

    #[test]
    fn the_sheen_crosses_the_word_and_never_lights_more_than_its_width() {
        for t in (0..3000).step_by(35) {
            let on = shimmer(12, t).iter().filter(|b| **b).count();
            assert!(on <= SHIMMER_WIDTH, "{on} lit at {t}");
        }
        assert!((0..3000)
            .step_by(35)
            .any(|t| shimmer(12, t).iter().any(|b| *b)));
        assert!(
            (0..3000)
                .step_by(35)
                .any(|t| shimmer(12, t).iter().all(|b| !*b)),
            "it rests between sweeps"
        );
        assert!(shimmer(0, 500).is_empty());
    }

    #[test]
    fn the_spinner_cycles_and_the_pulse_alternates() {
        assert_ne!(spinner(0), spinner(SPINNER_MS));
        assert_eq!(spinner(0), spinner(SPINNER_MS * 10));
        assert_ne!(pulse(0), pulse(PULSE_MS));
    }

    #[test]
    fn a_still_screen_asks_for_no_wakeups_and_motion_only_costs_while_something_moves() {
        assert_eq!(
            next_wake(true, false, false, false),
            None,
            "at rest: nothing"
        );
        assert_eq!(next_wake(false, false, false, false), None);
        assert_eq!(
            next_wake(true, true, false, false),
            Some(Duration::from_millis(70)),
            "the shimmer"
        );
        assert_eq!(
            next_wake(true, false, true, false),
            Some(Duration::from_millis(300)),
            "the pulse"
        );
        assert_eq!(
            next_wake(true, true, false, true),
            Some(Duration::from_millis(16)),
            "an unfold wins while it lasts"
        );
    }

    #[test]
    fn with_motion_off_only_the_elapsed_counter_ticks() {
        assert_eq!(
            next_wake(false, true, false, true),
            Some(Duration::from_secs(1))
        );
        assert_eq!(
            next_wake(false, false, true, false),
            None,
            "no pulse without motion"
        );
        assert_eq!(
            next_wake(false, false, false, true),
            None,
            "no unfold animation without motion"
        );
    }

    #[test]
    fn an_unfold_goes_from_the_old_height_to_the_new_one_without_jumping_either_way() {
        assert_eq!(reveal_rows(2, 10, 0), 2, "it starts where it was");
        assert_eq!(reveal_rows(2, 10, REVEAL_MS), 10, "and ends whole");
        let mid = reveal_rows(2, 10, REVEAL_MS / 2);
        assert!((2..10).contains(&mid), "{mid}");
        assert_eq!(
            reveal_rows(10, 4, REVEAL_MS),
            4,
            "closing works the same way"
        );
        assert_eq!(reveal_rows(0, 0, 50), 0);
    }

    #[test]
    fn the_reveal_eases_out_from_nothing_to_whole() {
        assert!((ease_out(0) - 0.0).abs() < 1e-9);
        assert!((ease_out(REVEAL_MS) - 1.0).abs() < 1e-9);
        assert!(ease_out(REVEAL_MS / 2) > 0.5, "fast at first");
        assert!((ease_out(u64::MAX) - 1.0).abs() < 1e-9);
    }

    #[test]
    fn every_verb_and_tip_fits_a_narrow_status_line() {
        for v in VERBS {
            assert!(v.chars().count() <= 22, "{v}");
        }
        for t in TIPS {
            assert!(t.chars().count() <= 66, "{t}");
        }
    }
}
