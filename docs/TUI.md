# Desk client (`rust/`)

The desk front-end for agents: `herdr-tui` starts an agent (omp, claude, codex, pi) in the
current folder, or attaches to a running session (`herdr-tui <keeper id>`, what a herdr pane
runs). Every session is a keeper session, so the phone sees and answers it too. It replaces
the python `view` (`keeper_script.dart`, `class View`). It speaks the
keeper's ACP socket as a viewer (`_meta.herdr.viewer`), exactly as `view` does, and the
keeper does not change. Written in Rust, no async runtime, small on purpose.

Status: v0 (prototype) runs end to end; the code is being rebuilt as the layers below.
Everything here is the target; what is measured is marked.

## The moment

At the desk, in a herdr pane next to the editor. An agent is working on something the
person cares about. Unlike the phone they have a keyboard, a wide screen and minutes of
attention, and they judge the tool against codex and omp. Same five questions as the app,
asked with a keyboard:

1. **Does anything need me?** A permission card at the bottom, with the exact command.
2. **Is it alive?** One status line: what it is doing now, for how long, how to stop it.
3. **What did it do?** The conversation above, outcome first, tool calls folded.
4. **Steer it.** A composer that is always there and always clear where text goes.
5. **Can I trust it?** The command shown whole; nothing answered by default or by a timeout.

## What codex teaches (and what we leave)

Read from `openai/codex` `codex-rs/tui` (cloned to `temp/codex-ref`, untracked).

| Codex does | Why it works | Ours |
| --- | --- | --- |
| **Inline viewport.** Finished messages are written into the terminal's scrollback (`insert_history.rs`); only the bottom pane is live. | Native scroll and copy, history survives exit, at the price of a 1,440-line forked terminal (`custom_terminal.rs`) and reflow code. | **Leave** (owner chose the alternate screen). We keep its other lessons. |
| History cells are immutable once finished; a streaming message is committed by newline (`streaming/`), not per token. | No flicker, no half lines in scrollback. | Adopt: commit whole lines; the unfinished tail lives in the live area. |
| Tool calls group and fold: `• Explored └ Search … Read …`, output capped at 5 lines with a count of the rest (`TOOL_CALL_MAX_LINES`). | Outcome first, process one keypress down. | Adopt. Full output behind the pager. |
| One status line while working: `• Working (12s • esc to interrupt)`. | Alive, how long, how to stop, in one row. | Adopt. Elapsed shown at second resolution only while visible. |
| Approval: the command, then numbered options with a single key each (`y`, `p`, `esc`), `Enter` confirms, "No, and tell the agent what to do differently". | Fast, and the person sees what they approve. | Adopt the shape. Guards below. |
| Composer: `›` prompt with a placeholder, footer with shortcuts left and context right. | Always clear where typing goes. | Adopt. |
| Colour: terminal default foreground, ANSI palette only, dim for secondary; no custom RGB, no ANSI black/white (`styles.md`). | Works in every theme, light or dark. | Adopt. Fixes my v0, which was fine only by accident. |
| Snapshot tests of the rendered screen via a vt100 emulator. | Catches what a person would see. | Adopt (our `herdr-screen-check` idea, for a terminal). |
| A 12k-line composer, paste-burst detection, themes, voice, plugins, keymaps. | Years of product. | **Leave.** Add only what a viewer needs. |

## Screen model

The viewer owns the screen (alternate screen, owner's decision: faster and lighter than
printing into scrollback, and the layout is ours to get right).

```
 transcript viewport   entries wrapped to the width, follows the bottom
 approval dock         only while a request waits
 status line           one row: what it is doing, for how long, how to stop
 composer              always there, grows to 6 rows
 footer                key hints
```

- History is held in a store bounded by **bytes**, not rows; tool output is trimmed to a
  head and tail with a count when it arrives. Dropped items are said so (`N earlier items`);
  the keeper still has them.
- Wrapped lines are cached per (entry, width) and dropped on resize, so a redraw during
  streaming wraps only the entry that changed. Nothing is drawn when nothing changed, and
  the only timer is the 1 s elapsed counter while a turn runs.
- The mouse is not captured: the wheel scrolls through the terminal's alternate-scroll mode
  and the terminal's own selection keeps working. `Ctrl-Y` copies the last answer (OSC 52).
- Cost of choosing this over printing into scrollback (codex): no native scrollback after
  exit, copy of a long answer needs `Ctrl-Y` or the terminal's selection of the visible part.

## Small touches (and why they are allowed)

The app's rule is that nothing moves at rest and delight is friction that vanished. These keep it:
the waiting word and tip change only on the 1 s tick a running turn already has (no timer at rest);
the end-of-turn line answers "what did it do?" (question 3) instead of decorating; the bell and the
window title serve "does anything need me?" for a pane nobody is looking at. A tip waits 10 s into a
turn so it never competes with a short answer. All of it is in `delight.rs`, pure and tested.

## Journeys

**Open a session.** `herdr-tui` starts, connects, asks the keeper to replay, prints the
last turns into scrollback with a line saying how many earlier turns exist, and shows the
composer. Waiting for the phone to open the session says so (it does today).

**An agent needs me.** The card appears in the live area, above the status line: the
tool title, the command whole (wrapped, never cut; `Read all` only past ~12 rows),
options numbered. Keys are ignored for 400 ms after it appears (a keystroke meant for the
composer must not answer it). Digits answer only while the composer is empty.

**Follow.** Streaming text appears line by line above the status line. Tool rows appear when a
call finishes, folded; the status line names the running one.

**Steer.** `Enter` sends, `Ctrl-J` / `Alt-Enter` newline, `Up` recalls, `Ctrl-C` stops a
running turn and (idle, empty) leaves. Typed text survives a failed send.

**Something is wrong.** The keeper closed, the agent exited, the session did not open:
a note in scrollback and a status line in words, with what to do (`herdr-tui` exits
non-zero so the pane shows it, never a blank screen).

## Parity with the other surfaces

A permission is answered on the phone card, the notification, the python `view` (until
removed) and here. Properties the person relies on, filled from each surface's code:

| Property | Phone card/dock | Python `view` | This viewer (target) |
| --- | --- | --- | --- |
| Shows the command | whole, `Read all` | whole | whole |
| Guard against a stale answer | `tapGuard` after arrival | none | 400 ms after arrival |
| Hold for risky / standing grants | hold | none (typed number) | second deliberate key, labelled |
| Confirmation | haptic, then next card | note `Answered: …` | note in scrollback |
| Failure path | honest, Retry | a failed write ends the view (`View.send`) | note, card stays, can retry |
| Several waiting | walk them | "answer on the phone" | `1 of N`, answer in order |
| Question (form) | answered in sheet | "answer on the phone" | **gap**, see below |

Open cells are findings, not silence: forms, and risky-hint rules (`mode_danger.dart`,
`permission_subject.dart` hold the phone's rules; do not re-derive them, port or share).

## Plan

| Step | Today (v0) | Problem | Change |
| --- | --- | --- | --- |
| Screen model | Alternate screen, history in RAM by item count | Memory not bounded by size, wrap redone per frame | Byte-bounded store, per-width cache |
| Streaming | Redraw whole history per event | Cost grows with history | Width-keyed line cache, redraw only on change |
| Colour | Cyan/yellow/etc. | Fine in few themes | ANSI palette per codex `styles.md`; default fg |
| Permission | Digit answers instantly | Stale answer, no hold, no `Read all` | Guard, second key for standing grants |
| Tool rows | One row each | Noise on long turns | Group consecutive calls, cap, count |
| Tests | Unit tests of model | Nothing proves the screen | vt100 snapshot of each state, worst-case data |
| Questions | Note only | Dead end | Answer forms in the card |
| Herdr | Not reported | `view` reports state to herdr | Port `report` |

## Owner decisions

1. **Alternate screen** (decided). Inline scrollback was the other option.
2. **Replay on open.** The whole replay goes into the byte-bounded store first; delta replay
   (`_meta.herdr.since`) only if opening a long session is slow.
3. **Distribution** of the binary to hosts: open, decided before the app starts running it.
