# Agent screens and the pane

One agent per screen, the pane, its bar and terminal, and the composers they share.

The design system (tokens, kit, motion, words) is `docs/DESIGN.md`; this file holds what this screen does and why.

## One agent per screen

An agent screen shows one agent: a terminal pane's terminal (`PaneScreen`) or
its chat (an agent session, or an omp, Claude Code or Codex pane followed through its log). Every
way in opens it through `openAgent` (`agents/agent_navigation.dart`): the
board, notifications and links, the start forms, Duplicate, past sessions and
the agent screens themselves. An agent already in front in that view is left
as it is. Why: the pane used to have browser-style tabs, and they held
terminals only (an agent the app can read opens as a chat by default, agent sessions were
always pushed screens), so they were a second, partial list of agents beside
the board, with its own count and order. The board is the
one scan surface; an agent screen is for one agent.

- **A swipe goes to the next agent.** Inside an agent screen (over the
  terminal panel, or the chat's transcript) a quick sideways swipe shows the
  next agent in the board's order (swipe left; right for the previous one):
  its sections in turn, Needs you and Done longest waiting first, panes and
  sessions mixed as the board mixes them. The board's filter and collapsed
  sections are a way of looking, not an order, and are not applied. Why: fast
  switching without a second list, in the order that answers "does anything
  need me" first.
- **What counts as the swipe** (`AgentSwipeDetector`, `agent_swipe.dart`):
  one finger the whole time (a second one is a pinch), 64 dp sideways within
  450 ms of touching down, with under 40% as much vertical travel, and not a
  finger that first went more than 24 dp vertically (a scroll, for the rest
  of the touch). Why the numbers: a long-press selection starts at 500 ms, so
  a selection drag is never a swipe, and a scroll that drifts is not either.
- **What never triggers it.** A touch that starts within 24 dp of the
  screen's sides: the system back gestures live there. Anything under the
  finger that scrolled sideways during the touch (a code block, a table, a
  terminal wider than the screen with wrap off): that swipe is theirs, and a
  scrollable claims the drag before 64 dp. The detector listens to raw
  pointers and never joins the gesture arena, so scrolling, link taps,
  selection and pinch zoom behave exactly as without it.
- **The ends.** At either end of the order, or for an agent the board does
  not list, nothing moves and a `tick` says so. Why: the order does not wrap
  round, so the person feels where the list ends instead of landing back on
  the first agent without noticing.
- **Chat and Terminal are one agent's two views, switched from its menu.** An
  agent with both (a pane the app can follow through its log) has `Show terminal` in the
  chat's `Session options` and `Show chat` in the terminal's `Pane options`.
  It swaps the view in place, and the choice is remembered for that agent for
  the app run: the board and the swipe open it in that view after. Settings >
  `Open agents as` stays the default for an agent with no choice yet; a
  pane whose agent has no chat opens its terminal and offers no `Show chat`. A
  Claude Code or Codex pane that herdr reports no session for offers `Read as chat…`
  in its terminal's options, always (not only after a look for the log failed): it installs herdr's hook for that agent
  on the machine after one confirmation (`connect_chat.dart`), which makes
  the agent report its session.
  Why: the old `Terminal` action replaced the chat, and nothing in the
  terminal led back to it. It then became a
  two-icon toggle in every bar, 88 dp that the title needed, for something
  done a few times a day; the menu costs one more tap and gives the bar back.
- **Drafts are kept per agent** for the app run (`AgentScreens.keepDraft`),
  shared by the agent's chat and terminal. Why: a swipe and the view switch replace
  the screen, so what is typed must live outside it; with tabs, a draft in a
  hidden tab was lost past six live panes and closing a tab dropped it.
- **Back always goes to the board** (where the person came from). A swipe and
  the view switch replace the screen in front instead of pushing, and a
  notification or a link replaces the agent screen in front, if one is. Why:
  walking ten agents must not leave ten screens to back out of.
- **Motion.** A swipe replaces the route: the new screen slides a short way
  (0.2 of the width) and fades in over `Motion.standard`, from the side the
  finger came from, while the screen under it stays still (no parallax). The
  toggle only fades, over `Motion.fade`: the same agent, so nothing slides.
  Under reduced motion a swipe is that fade. At launch the screen is back at
  once (below, "What survives a launch"). Once in, the route is a page like
  any other: Back and the edge swipe use the page transition.

## Pane bar

One bar of about 56 dp (`AppTopBar`): back, status glyph and title over
`agent · machine`, then files and `Pane options` (`⋯`), never more than two
actions. Why: a third circle cut the title. The options are the one way to the
pane's actions: `Show chat` (for an agent with both views), `Wrap lines`,
`Duplicate`, `Copy title`, `Copy pane id <id>` (the raw id lives there, not in the bar). The title
is not a button, and nothing else hides behind it: no long press, no pull-down.
Where a blocked pane's prompt is
understood, the question and up to three answers plus `N more` dock above the
key row (`AnswerDock`). The dock is hidden in the compact and short layouts.

The answer dock shows the question in two lines and the command (`subject`)
in mono in two more (`QuestionWash`, compact); `Read all` opens the rest when
either is cut.

The dock's answers take no tap and are dimmed for `tapGuard` each time the dock
appears (the pane turns blocked, its screen opens by a tap, a swipe or the
toggle, the link comes back)
and each time its question changes, a new question after `Sent` included
(`TapGuardState`, checked in the chip and again in the handler). Why: the dock
comes up right above the key row and the composer, so the thumb is already
there, pressing Enter or typing, when it arrives; without the guard that press
answered whatever question had just slid under it.

While the dock shows a question, a bare Enter does not reach the pane: the key
row's Enter and the keyboard's send on an empty composer press nothing, give a
tick and toast `Pick an answer above`. Why: in the agent's menu Enter accepts
the highlighted option, so it would answer past the dock's hold on a risky
option and past its guard. Arrows, Esc and a Ctrl/Alt Enter still go through
(deliberate moves in the menu), typed text still sends as a line, and with no
dock (compact or short layout, or a prompt the app does not understand) Enter
is left alone.

**Terminal jump pill** (`terminal_jump.dart`, in `TerminalView`). Away from the
newest row it is the round chevron (`Jump to latest`); when rows arrive after
the reader left (net rows added at the end, so rows the read window drops from
the top do not count, nor a redraw in place) it is a pill, `3 new lines`,
`99+ new` past 99, counted from zero each time they leave and reset on
reaching the end. A pane that turns blocked while they are away makes it
`Needs you` with the blocked glyph (one already blocked when they left is
not news; the dock shows it); that wins over the count. A tap fires `Haptics.tick`
and scrolls to the end: `Motion.easeOut` over 220 ms when under 3 viewports
away, an instant jump otherwise and under reduced motion. It comes and goes
with opacity and scale (0.92 to 1) and keeps its words while fading out.

**Live edge** (`live_edge.dart`, bottom of the terminal panel, inside the
outline). A 2 px rule: accent-tinted when the last read brought new output
(`PaneViewModel.streaming`), `hairline` when it found nothing new. While the
link is down or a read failed, the text dims to the closed-pane alpha (0.6)
and the rule is `danger` (read failed) or `textMuted` (link down only) with
a label `stale · 12s`, seconds since `PaneViewModel.lastRead` (then `1m`,
`1h`). One timer a second redraws that label, only while stale and on
screen; a live pane has no timer and no ticker. The
screen reader hears `Output is stale` once. A closed pane is dimmed, not stale.


## Composers

- **Send haptics follow the outcome; a failed send loses nothing.** One
  contract for both composers: `sent` fires when the message was taken and
  `failed` when it was not, never before the outcome is known (a session
  composer that buzzed `sent` and cleared the field before an observed agent's
  send failed left the person with neither the text nor a true signal). The
  pane composer keeps its text until the request is accepted (the tap itself
  already ticked). A failed send's banner stays through the reads that
  follow, until a send succeeds or Retry is pressed; text typed while a send
  was in flight is kept. The session composer empties at once (an ACP prompt
  is taken the moment it starts, and its turn is not waited for:
  `AgentSessionView.sendBlocks` completes with whether the message was kept)
  and on a failure puts the text and attachments back, ahead of anything typed
  or attached meanwhile.
- **Quick phrases**: a row of chips above the composers (pane and agent
  session), shown while the field is focused and empty, never in the compact
  layout. A tap fills the field and never sends. Edited in Settings; prefs key
  `quickPhrases.v1`, 12 phrases of at most 80 characters. Up to 3 learned
  chips (`SentPhrases`, key `sentPhrases.v1`) follow the person's own list, or
  lead the shipped defaults while the list is untouched: a message really
  sent beats a guess, and an edited list never moves. A message is learned
  only from text sent to an agent (never a line typed into a shell), after
  its second send, one line, no address, no token of 24+ characters, 300
  remembered at most. Why: replayed on a year of one person's messages, 14% were
  exact repeats and these chips finish 5% of messages in one tap, twice the
  defaults (`tool/predict-eval`); what a person types can hold secrets, hence
  each limit.
- **Dictation** (`ui/features/dictation/`): the mic takes Send's place in both
  composers (agent session, and a pane that has an agent) while the box is
  empty and the link is live: the same 36 dp disc, neutral at rest, the accent
  while it listens, and it stays the stop button while it listens although the
  box now holds the words (the button never turns into Send under the thumb
  mid-sentence). What is heard goes into the box at the cursor and never
  sends: the person reads it and presses Send, as with a quick-phrase chip. A
  long press picks the language: English and Tiếng Việt always have a row, dimmed
  with the reason when the phone's speech service lacks them; the choice is kept
  (`dictation.language.v1`). Not offered for a line typed into a shell. Why: a
  phone is faster to speak to than to type on, one-handed, and a wrong word
  sent to an agent is worse than a wrong word in the box.
- **Zoom detents**: pinch-zooming the terminal ticks at each whole font size
  and gives a firmer `hold` at the minimum and maximum.

## The terminal follows the theme

A pane is drawn on paper in the light theme and on ink in the dark one
(`TerminalPalette.light/dark`, `context.terminal`); Settings > Look > Dark
terminal keeps it dark on paper. The ANSI parser always yields the dark
`TerminalColors`; `TerminalPalette.recolor` turns a row's runs into the
palette's when the row is prepared (the dark palette returns the run itself, so
it costs nothing). On paper, the 16 ANSI colours are darker hues that reach
4.5:1 on white, text with a background of its own and no colour picks the
default that reads on it, and any text below 3.5:1 against its background is
pulled toward black, so a TUI that chose pale greys for a dark screen stays
readable.

## Wrap keeps tables whole

Wrap re-flows prose to the phone's width. A row of a table or a box (line
characters, a markdown or ASCII table: `table_lines.dart`) is never cut, since
cut in pieces it means nothing; when one is wider than the view, the view
scrolls sideways for it, and the agent swipe stands aside, as it does for
anything that scrolls sideways.
