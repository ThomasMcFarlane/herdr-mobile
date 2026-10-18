import '../../words/elapsed.dart';
import '../../words/plural.dart';
import 'turn.dart';

/// The parts of the fold line of a turn, from data the app has (counts, times,
/// exit codes, diff stats), never from words a model wrote:
///
/// `Worked 42s` · `3 files` · `4 commands` · `1 failed` · `1 cancelled`
///
/// A part that is zero is left out. `Worked` carries the duration only when
/// it is a real measurement ([Turn.duration]: not for a replayed history) and
/// at least a second. Plain strings, safe for any script: nothing here cuts or
/// indexes text.
List<String> workSummaryParts(Turn turn) {
  final d = turn.duration;
  return [
    d == null || d < const Duration(seconds: 1) ? 'Worked' : 'Worked ${Elapsed.compact(d)}',
    ?_count(turn.changed.length, 'file'),
    ?_count(turn.commands.length, 'command'),
    if (turn.failedCount > 0) '${turn.failedCount} failed',
    if (turn.cancelledCount > 0) '${turn.cancelledCount} cancelled',
  ];
}

/// [workSummaryParts] joined with ` · `.
String workSummaryLine(Turn turn) => workSummaryParts(turn).join(' \u00b7 ');

String? _count(int n, String one) => n == 0 ? null : countOf(n, one);
