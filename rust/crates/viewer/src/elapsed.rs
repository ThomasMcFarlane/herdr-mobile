//! The one thing that changes over time while a turn runs: the elapsed counter. Pure and
//! deterministic, so each part is testable. Nothing else in the viewer moves.

use std::time::Duration;

/// `9s`, `1m 12s`, `1h 03m`.
#[must_use]
pub fn duration(secs: u64) -> String {
    match secs {
        0..=59 => format!("{secs}s"),
        60..=3599 => format!("{}m {:02}s", secs / 60, secs % 60),
        _ => format!("{}h {:02}m", secs / 3600, secs % 3600 / 60),
    }
}

/// At rest nothing wakes the loop; while a turn runs the elapsed counter does, once a second.
#[must_use]
pub fn next_wake(working: bool) -> Option<Duration> {
    working.then(|| Duration::from_secs(1))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn durations_read_at_a_glance() {
        assert_eq!(duration(0), "0s");
        assert_eq!(duration(59), "59s");
        assert_eq!(duration(72), "1m 12s");
        assert_eq!(duration(3600 + 180), "1h 03m");
    }

    #[test]
    fn only_a_running_turn_wakes_the_loop_and_only_once_a_second() {
        assert_eq!(next_wake(false), None);
        assert_eq!(next_wake(true), Some(Duration::from_secs(1)));
    }
}
