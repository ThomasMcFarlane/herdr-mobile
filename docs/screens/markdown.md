# Markdown

The one renderer for every Markdown surface (`ui/render/markdown/`).

The design system (tokens, kit, motion, words) is `docs/DESIGN.md`; this file holds what this screen does and why.


One renderer for every Markdown surface: the agent's answer and thoughts, the
file viewer, later a plan in the permission dock. The model is `MdDocument`
(`md_document.dart`, the only thing a renderer reads); the widgets are
`MdBlockView` (one block, for a lazy list that keeps its own "Show all" state),
`MdDocumentView` (a whole static document in a column) and `mdBlockGap`.
Each block is a `Text.rich` paragraph, a list, a quote, an alert, a table or a
code block, so `SelectionArea` selects across all of them (one `SelectionArea`
over the transcript list keeps working across a code block and a table) and the
text is the semantics label. The tone comes from `MdToneScope`: an answer reads
at body size in the text colour, reasoning (`ThoughtRow`) at the secondary size
and colour, a quote in the supporting colour.

- **Blocks.** Headings 22 / 18.5 / 16 / 15 (`Type.*`, 600-700, h4-h6 body size),
  paragraphs `Type.body`, bold 700, italic, `~~strike~~`, inline code in mono
  1.5 pt smaller on the quiet fill, links `accentText` underlined faintly. A
  soft line break is a newline in chat prose and a space in the file viewer
  (`parseMd(softBreaksAsNewlines:)`). A hard break, `<br>`, entities and
  autolinks come from the model. RTL is per paragraph (the first strong
  character): such a paragraph, its list item or its quote is laid out right
  to left.
- **Spacing** (`mdBlockGap`): 10 between blocks; 16 above an h1/h2, 12 above
  h3-h6, 6 under any heading; 6 from a lead-in paragraph to its list; 12 around
  a rule. In a list: 4 between tight items, 10 between loose ones; inside a
  tight item 3 around a nested list and 6 between paragraphs. Text blocks stop
  at a reading width of about 72 characters (560 dp at 100% text; it grows with
  the text scale) on a wide screen; code and tables use the whole width.
- **Lists.** Depth is structure; the marker column is as wide as the widest
  number (ordered lists keep their start, numbers right-aligned in tabular
  figures); bullets are drawn shapes, a dot, a ring, a square by level; the
  indent stops growing past six levels and past 125% text scale. A task item
  is a read-only status shape from the glyph language (`StatusGlyph`: an empty
  ring open, a check done), never a checkbox, announced as "Done" / "Not done".
  Continuation paragraphs, code and nested quotes live inside the item.
- **Quotes and alerts.** A quote has a 3 dp bar at its start edge and the
  supporting text colour, nested to any depth. A GitHub alert is a quiet fill
  with a Lucide glyph and its name (`Note`, `Tip`, `Important` in the
  supporting colour, `Warning` in `blockedText`, `Caution` in `dangerText`): no
  coloured chrome.
- **Code.** A header 44 dp high with the language label (caption, `textMuted`),
  a wrap toggle (shown when a line is longer than ~34 characters) and a copy
  button (Lucide `copy`, 44 dp hit); copy gives the raw code (`copyText`, so
  the words are said only where the system does not) and the icon turns into a
  check for `Dwell.copied`, only when the copy took; a refused copy keeps the
  copy icon and says so. No wrap by default: the block
  scrolls sideways, so a line stays one line; the last toggle is the start
  state of the next block. Colours are the theme's terminal palette
  (`context.terminal`, the same colours as a pane) on the quiet fill, every
  token colour >= 4.5:1 (`md_highlight_test.dart`); a dark terminal on paper
  takes the terminal's page. Highlighting (`highlight/`) is per line, kept per
  block, redone only from the first changed line, and only for the lines shown
  and complete: the open last line of a streaming block stays plain, so a
  colour never flips back. Unknown languages stay plain. 60 lines, then
  `N more lines` and `Show all` (a lazy 360 dp box past 300 lines); the caller
  owns that state. Bidi overrides and control characters show as `‹U+202E›`
  (`visibleText`), tabs go to the next multiple of four, a line past 2000
  characters is cut and counted. Every line goes through `clipLine`
  (`visibleText`, then a cut that never splits a surrogate pair): half a pair
  makes the paragraph builder throw "string is not well-formed UTF-16", and a
  row whose layout throws is left undrawn. Prose goes through `proseText`
  (half a pair becomes U+FFFD, bidi overrides go).
- **Tables.** A real table: bold header over a stronger hairline, one hairline
  per row, no zebra, text 1.5 pt under body in tabular figures. A column is as
  wide as its longest cell (and bold header) between 48 and 240 dp, longer text
  wraps in the cell, and while rows stream the widths only grow. Alignment
  follows `:--` / `:-:` / `--:`. Narrower than the screen it shares the width;
  wider it scrolls sideways with a 28 dp fade on the edge that has more, and
  never overflows. 40 rows, then `N more rows` / `Show all`. A long press
  (or the `Copy table` accessibility action) offers Copy as Markdown and Copy
  as TSV.
- **Links, paths, images** (what a tap does comes from the nearest
  `MdActions`; a surface without one draws the text without the affordance).
  Only `http` and `https` links open, and only through the link sheet, which
  shows the whole address first (a label can say anything); `mailto:`,
  `javascript:`, anchors and the like are plain text. A path (`lib/a.dart`,
  `lib/a.dart:42`, `~/x`, a relative link target, `#L42` fragments) in text,
  in inline code that is nothing but a path, or as a link target opens the
  file viewer at that line, on the session's machine, relative to its folder
  (`AgentMdScope`; in the file viewer relative to the file's folder): the host
  is asked only on the tap, never while drawing. An image is never fetched: a
  quiet chip `Image: alt · host`; a tap shows the address in the link sheet
  (web) or opens the file viewer, which draws pictures (a path).
- **What counts as a path** (one detector, `ui/render/terminal/terminal_links.dart`,
  shared by the terminal view and this Markdown, so a token is a link or not
  for the same reason in both). A path is underlined only when it looks like a
  FILE: `name.ext` (a stem and a short alphanumeric extension that is not all
  digits, so not `1.2.3`), or a well-known extension-less name (`Makefile`,
  `LICENSE`, `go.mod`, `.gitignore`, `/etc/hosts`), with an optional `:line`,
  `:line:col`, `(line,col)`, `#L12`, `#L12-L20` or ` (line 12)`. Alone (no
  directory) the extension must also be a known one, so `e.g` and `www.x.com`
  stay words. Never a link: folders (`src/`, `lib/ui`, `/usr/local/bin`), slash
  commands (`/model`, `/compact`, `/resume`: a single absolute segment with no
  dot, at the start of a line or anywhere), `and/or`, dates, versions, ratios,
  CLI flags, `host.com/x`, `user@host:/x`, `C:\x`, `package:x/y.dart`,
  `#include <x.h>`, globs, calls (`res.json()`), and the tail of an ellipsis
  (`…/a.dart`). Git's `a/` and `b/` in `--- a/x`, `+++ b/x` and `diff --git`
  headers are not part of the target (the underline still covers them); in a
  `--stat` line `a/b/c.dart` is a real folder. A missed link costs a copy and
  paste; a wrong one is an underline in the way, so every rule leans towards
  plain text. `test/link_sense_test.dart` holds the labelled table (over 230
  lines), the recorded-session check and the speed budget.
- **Tapping a path** (`openRemoteFile`): the host is asked only now. It tries
  the pane/session folder, then the two folders above it (an agent names a file
  from the project root while the pane sits in a subfolder), with git's `a/`
  `b/` prefix dropped as a second try; `/x`, `~/x`, `./x` and `../x` are not
  searched for elsewhere. A file opens the viewer; a folder opens the browser;
  a missing or forbidden one is a toast, never a dead end.
- **Text safety.** Code and inline code show every hidden or direction-changing
  character as `‹U+202E›`; prose drops the embeddings, overrides and isolates
  (they can only mislead) and keeps the right-to-left and left-to-right marks
  real RTL text needs. The engine percent-encodes such a character in a link
  target, so the sheet shows `%E2%80%AE`. HTML is text.
- **Semantics.** Each block row is a node with its plain text; headings are
  headers; a code block reads `Code, dart, 12 lines` (no language: `Code, 12
  lines`) with its header buttons and its text as separate nodes; a table
  reads `Table, 3 columns, 5 rows` (the header counts as a row) with its cells
  as separate nodes; a link, a path and an image chip are tappable nodes; a
  task item says `Done` or `Not done`. The open tail of a streaming message
  (`tail: true`) is excluded until it is final, so a screen reader is not
  re-announced every frame.
- **Streaming.** The transcript draws the answer that is arriving through one
  live row (`LiveMessageRow`, "The live row, pacing and follow" under "Agent
  session screen" above): frozen blocks as cached widgets, the open tail
  healed (`**bo` shows as bold, an open fence as a code block, a half-written
  table row waits) with `tail: true`. Ending the message changes no pixel: the
  settled rows are the same widgets with the same gaps. Not here yet: the fade
  of the newest words (off until measured on the phone) and a measurement of a
  painted block on the phone.
