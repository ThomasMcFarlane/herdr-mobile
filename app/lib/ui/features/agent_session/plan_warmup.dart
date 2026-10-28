import 'dart:async';
import 'dart:math' as math;

import '../../../data/acp/acp_models.dart';
import '../../../data/acp/session_state.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

import 'transcript_plan.dart';

/// Turns planned for the first frame of a long transcript: the screenful the
/// reader sees and a little above it.
const firstFrameTurns = 8;

/// A transcript with no more items than this is planned whole at once (it is
/// cheap: the first frame of a short thread costs the same either way).
const planWholeUpTo = 120;

bool _startsTurn(TranscriptItem item) => item is TranscriptMessage && item.role == MessageRole.user;

/// The index in [items] where the last [turns] turns begin (a turn starts at a
/// user message), or 0 when there are no more turns than that.
int tailStart(List<TranscriptItem> items, int turns) {
  var seen = 0;
  for (var i = items.length - 1; i > 0; i--) {
    if (_startsTurn(items[i]) && ++seen == turns) return i;
  }
  return 0;
}

/// The index where the last turn begins (its user message), or 0.
int lastTurnStart(List<TranscriptItem> items) {
  for (var i = items.length - 1; i > 0; i--) {
    if (_startsTurn(items[i])) return i;
  }
  return 0;
}

/// Where the plan of the first frame starts: [tailStart], and, when a turn runs
/// ([live]) and it alone holds more than [planWholeUpTo] items, that many of its
/// newest. A running turn's log is open (a row per item, every message parsed),
/// and a subagent's conversation is one turn of up to 2000 items. A finished
/// turn is never cut: it folds to one line, and a cut would give that line the
/// wrong figures.
int firstFrameStart(List<TranscriptItem> items, {required bool live}) {
  final byTurns = tailStart(items, firstFrameTurns);
  if (!live) return byTurns;
  final byItems = items.length - planWholeUpTo;
  return byItems > lastTurnStart(items) ? byItems : byTurns;
}

/// Gets the older turns of a long transcript ready while the reader looks at
/// its tail, so that planning the whole thing afterwards costs next to
/// nothing.
///
/// Planning a turn is not free: its Markdown is parsed, its changed files and
/// their line stats are counted, its calls grouped. All of that is memoized on
/// the objects the plan reads (the message, the turn), so a plan of a turn
/// that was planned before only builds its rows. [start] plans the turns
/// before [end] one by one into a plan of its own, newest first, at most
/// [budget] of work per [gap] on the UI thread (a timer between frames, never
/// inside a build), and calls `done` when the last one is ready. Nothing here
/// is shown.
class PlanWarmup {
  PlanWarmup({required this.open, required this.notes, this.budget = Dwell.planBudget, this.gap = Dwell.planGap});

  final Set<String> open;
  final Map<String, String> notes;
  final Duration budget;
  final Duration gap;

  Timer? _timer;

  bool get running => _timer != null;

  /// Prepares the turns of `items[0, end)`. With [live] (a turn runs) and `end`
  /// inside that turn, its head is prepared in pieces of [planWholeUpTo] items,
  /// planned as a running turn so that their Markdown is parsed: one piece per
  /// step, not the whole head in one.
  void start(List<TranscriptItem> items, int end, Set<String> waiting, void Function() done, {bool live = false}) {
    cancel();
    final starts = <int>[
      for (var i = 0; i < end; i++)
        if (_startsTurn(items[i])) i,
    ];
    if (starts.isEmpty || starts.first != 0) starts.insert(0, 0);
    final liveHead = live && end > lastTurnStart(items);
    final units = <(int, int)>[];
    var liveFrom = 1 << 30;
    for (var i = 0; i < starts.length; i++) {
      final from = starts[i];
      final to = i + 1 < starts.length ? starts[i + 1] : end;
      if (liveHead && i == starts.length - 1) {
        liveFrom = units.length;
        for (var a = from; a < to; a += planWholeUpTo) {
          units.add((a, math.min(a + planWholeUpTo, to)));
        }
      } else {
        units.add((from, to));
      }
    }
    var k = units.length - 1;

    void step() {
      _timer = null;
      final clock = Stopwatch()..start();
      // At least one unit per tick, whatever the budget: it always advances.
      do {
        final (from, to) = units[k];
        TranscriptPlan(open: open, notes: notes).update(items.sublist(from, to), waiting: waiting, live: k >= liveFrom);
        k--;
      } while (k >= 0 && clock.elapsed < budget);
      if (k >= 0) {
        _timer = Timer(gap, step);
      } else {
        done();
      }
    }

    _timer = Timer(gap, step);
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
  }
}
