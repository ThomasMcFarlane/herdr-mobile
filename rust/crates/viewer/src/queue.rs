//! Messages typed while the agent works: they wait here, and go out one at a time when the turn
//! ends, as the phone's queue does (`docs/AGENT_SESSIONS.md`, "The queue"). Pure state; the
//! program (`main.rs`) sends and draws. Memory only: leaving the program loses the queue.

use crate::attach::Attachment;
use std::collections::VecDeque;

/// How many messages may wait. Bounds memory: the viewer is meant to live in a few MB.
pub const MAX: usize = 10;

/// One message that waits.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Queued {
    pub id: u64,
    pub text: String,
    /// Files to send with it, not yet read: their bytes are loaded when the message goes.
    pub files: Vec<Attachment>,
    /// Why it does not go out by itself, when it does not. The person's Enter on an empty box
    /// (or taking it back) is the way on.
    pub held: Option<String>,
}

/// The messages that wait, oldest first.
#[derive(Default)]
pub struct Queue {
    entries: VecDeque<Queued>,
    next: u64,
}

/// What a turn that just ended means for the messages that waited.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Disposition {
    /// Send them one by one.
    Go,
    /// The person stopped the turn: what they typed since is one message, then it goes on.
    Merge,
    /// Nothing goes until the person says so; the reason is shown.
    Hold(&'static str),
}

/// The phone's rule: a failed turn, a refusal or a stop from elsewhere holds the queue (a
/// message sent on top of a problem nobody saw is worse than a pause); the person's own Stop
/// goes on with it. `reason` is the turn's stop reason, when it said one.
#[must_use]
pub fn after_turn(stop_requested: bool, reason: Option<&str>) -> Disposition {
    match (stop_requested, reason) {
        (_, Some("error")) => Disposition::Hold("the turn failed"),
        (_, Some("refusal")) => Disposition::Hold("the agent refused"),
        (false, Some("cancelled")) => Disposition::Hold("the turn was stopped elsewhere"),
        (true, _) => Disposition::Merge,
        _ => Disposition::Go,
    }
}

impl Queue {
    /// Adds a waiting message at the back. The caller checks [`Queue::is_full`] first.
    pub fn push(&mut self, text: String, files: Vec<Attachment>) {
        debug_assert!(!self.is_full(), "the caller checks is_full first");
        self.next += 1;
        self.entries.push_back(Queued {
            id: self.next,
            text,
            files,
            held: None,
        });
    }

    #[must_use]
    pub fn is_full(&self) -> bool {
        self.entries.len() >= MAX
    }

    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    #[must_use]
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    #[must_use]
    pub fn entries(&self) -> &VecDeque<Queued> {
        &self.entries
    }

    #[must_use]
    pub fn has_waiting(&self) -> bool {
        self.entries.iter().any(|q| q.held.is_none())
    }

    #[must_use]
    pub fn has_held(&self) -> bool {
        self.entries.iter().any(|q| q.held.is_some())
    }

    /// Why the first held message is held.
    #[must_use]
    pub fn held_reason(&self) -> Option<&str> {
        self.entries.iter().find_map(|q| q.held.as_deref())
    }

    /// Takes the oldest message that is not held.
    #[must_use]
    pub fn pop_waiting(&mut self) -> Option<Queued> {
        let at = self.entries.iter().position(|q| q.held.is_none())?;
        self.entries.remove(at)
    }

    /// Puts a message back at the front, waiting: it could not go yet.
    pub fn requeue_front(&mut self, mut q: Queued) {
        q.held = None;
        self.entries.push_front(q);
    }

    /// Puts a message the agent refused back at the front, held: it keeps its place.
    pub fn hold_front(&mut self, mut q: Queued, why: String) {
        q.held = Some(why);
        self.entries.push_front(q);
    }

    /// Takes the message with `id` out (to edit it).
    #[must_use]
    pub fn take(&mut self, id: u64) -> Option<Queued> {
        let at = self.entries.iter().position(|q| q.id == id)?;
        self.entries.remove(at)
    }

    /// Takes the newest message out (to edit it).
    #[must_use]
    pub fn take_newest(&mut self) -> Option<Queued> {
        self.entries.pop_back()
    }

    /// Every waiting message is held, for `why`.
    pub fn hold_all(&mut self, why: &str) {
        for q in self.entries.iter_mut().filter(|q| q.held.is_none()) {
            q.held = Some(why.to_string());
        }
    }

    /// Every held message waits again. `true` when there was one.
    pub fn release(&mut self) -> bool {
        let mut any = false;
        for q in &mut self.entries {
            any |= q.held.take().is_some();
        }
        any
    }

    /// Each run of consecutive waiting messages without files becomes one, the texts joined by
    /// a blank line, the first one's id kept. A message with files or a held one is never
    /// merged and ends the run: `[Image #n]` restarts at 1 in every message, so merging
    /// file-carrying messages would make two pictures answer to one name.
    pub fn merge_waiting(&mut self) {
        let mut out: VecDeque<Queued> = VecDeque::with_capacity(self.entries.len());
        // Whether the message at the back of `out` may take the next one in.
        let mut open = false;
        for q in self.entries.drain(..) {
            let plain = q.held.is_none() && q.files.is_empty();
            if plain && open {
                if let Some(last) = out.back_mut() {
                    last.text.push_str("\n\n");
                    last.text.push_str(&q.text);
                    continue;
                }
            }
            open = plain;
            out.push_back(q);
        }
        self.entries = out;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn file(n: u32) -> Attachment {
        Attachment {
            name: format!("p{n}.png"),
            uri: format!("file:///p{n}.png"),
            path: format!("/p{n}.png"),
            picture: Some("image/png"),
            size: 1,
            data: None,
            link: false,
            number: n,
        }
    }

    fn queue_of(texts: &[&str]) -> Queue {
        let mut q = Queue::default();
        for t in texts {
            q.push((*t).to_string(), Vec::new());
        }
        q
    }

    fn texts(q: &Queue) -> Vec<&str> {
        q.entries().iter().map(|e| e.text.as_str()).collect()
    }

    #[test]
    fn the_queue_is_full_at_the_cap() {
        let mut q = Queue::default();
        for i in 0..MAX {
            assert!(!q.is_full(), "room for message {i}");
            q.push(format!("m{i}"), Vec::new());
        }
        assert!(q.is_full());
    }

    #[test]
    fn messages_go_oldest_first_and_a_held_one_is_skipped() {
        let mut q = queue_of(&["a", "b", "c"]);
        let a = q.pop_waiting().expect("a");
        assert_eq!(a.text, "a");
        q.hold_front(a, "busy".into());
        // The held one sits at the front; the next waiting one is b.
        assert_eq!(texts(&q), ["a", "b", "c"]);
        assert_eq!(q.pop_waiting().expect("b").text, "b");
        assert_eq!(q.pop_waiting().expect("c").text, "c");
        assert!(q.pop_waiting().is_none());
        assert_eq!(q.len(), 1, "the held one stays");
        assert_eq!(q.held_reason(), Some("busy"));
    }

    #[test]
    fn a_refused_message_keeps_its_place_and_a_requeued_one_waits_again() {
        let mut q = queue_of(&["a", "b"]);
        let a = q.pop_waiting().expect("a");
        q.hold_front(a.clone(), "the agent was busy".into());
        assert_eq!(q.entries()[0].held.as_deref(), Some("the agent was busy"));
        assert!(q.has_held() && q.has_waiting());
        let a = q.take(a.id).expect("a again");
        q.requeue_front(a);
        assert!(!q.has_held());
        assert_eq!(texts(&q), ["a", "b"]);
    }

    #[test]
    fn hold_all_then_release_round_trips() {
        let mut q = queue_of(&["a", "b"]);
        assert!(!q.release(), "nothing to release");
        q.hold_all("the turn failed");
        assert!(!q.has_waiting());
        assert_eq!(q.held_reason(), Some("the turn failed"));
        assert!(q.release());
        assert!(q.has_waiting() && !q.has_held());
    }

    #[test]
    fn consecutive_plain_messages_merge_and_files_or_holds_break_the_run() {
        let mut q = Queue::default();
        q.push("a".into(), Vec::new());
        q.push("b".into(), Vec::new());
        q.push("c".into(), vec![file(1)]);
        q.push("d".into(), Vec::new());
        q.push("e".into(), Vec::new());
        let ids: Vec<u64> = q.entries().iter().map(|e| e.id).collect();
        q.merge_waiting();
        assert_eq!(texts(&q), ["a\n\nb", "c", "d\n\ne"]);
        let kept: Vec<u64> = q.entries().iter().map(|e| e.id).collect();
        assert_eq!(kept, [ids[0], ids[2], ids[3]]);

        let mut q = queue_of(&["a", "b", "c"]);
        let mid = q.entries()[1].id;
        q.entries.iter_mut().find(|e| e.id == mid).expect("b").held = Some("x".into());
        q.merge_waiting();
        assert_eq!(texts(&q), ["a", "b", "c"], "a held message ends the run");
    }

    #[test]
    fn a_message_comes_back_by_id_or_as_the_newest() {
        let mut q = queue_of(&["a", "b", "c"]);
        let b = q.entries()[1].id;
        assert_eq!(q.take(b).expect("b").text, "b");
        assert!(q.take(b).is_none());
        assert_eq!(q.take_newest().expect("c").text, "c");
        assert_eq!(texts(&q), ["a"]);
    }

    #[test]
    fn a_failed_turn_or_one_stopped_elsewhere_holds_and_the_persons_stop_goes_on() {
        use Disposition::{Go, Hold, Merge};
        assert_eq!(after_turn(false, None), Go);
        assert_eq!(after_turn(false, Some("end_turn")), Go);
        assert_eq!(after_turn(false, Some("max_tokens")), Go);
        assert_eq!(
            after_turn(false, Some("cancelled")),
            Hold("the turn was stopped elsewhere")
        );
        assert_eq!(after_turn(true, Some("cancelled")), Merge);
        assert_eq!(after_turn(true, None), Merge);
        assert_eq!(after_turn(true, Some("error")), Hold("the turn failed"));
        assert_eq!(
            after_turn(false, Some("refusal")),
            Hold("the agent refused")
        );
    }
}
