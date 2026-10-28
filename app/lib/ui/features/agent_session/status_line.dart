import 'package:flutter/widgets.dart';

import '../../../data/acp/acp_models.dart';
import '../../../data/acp/session_state.dart';
import '../../../data/acp/turns/turns.dart';
import '../../../data/repositories/agent_session.dart';
import '../../../data/acp/background/background_work.dart' show BackgroundWork;
import '../../../data/words/elapsed.dart';
import '../../support/step_clock.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

import 'background_format.dart';
import '../../render/visible_text.dart';

/// The clock the status line and the subagent cards read (tests replace it).
DateTime Function() statusNow = DateTime.now;

/// One step a second: the elapsed time moves by the second. Runs only while a
/// [StatusLine] or a subagent card shows its clock (a lease per widget), and
/// not in the background ([StepClock] stops with the app).
final secondsClock = StepClock(Dwell.second);

/// What the agent does, as words: `Running flutter test`, `Reading parse.dart`,
/// the first sentence of the thought, `Working`.
String activityWords(ActivityLine a) {
  final text = visibleText(a.text);
  if (a.kind != ActivityKind.tool || a.tool == null) return text;
  final verb = switch (a.tool!.kind) {
    ToolKind.execute => 'Running',
    ToolKind.read => 'Reading',
    ToolKind.edit => 'Editing',
    ToolKind.search => 'Searching',
    ToolKind.fetch => 'Fetching',
    ToolKind.delete => 'Deleting',
    ToolKind.move => 'Moving',
    _ => null,
  };
  return verb == null ? text : '$verb $text';
}

/// The one liveness indicator of the transcript: the line after the last row
/// while a turn runs, `Running flutter test · 12s`.
///
/// What it says comes from [activityOf] (the call that runs, else the first
/// sentence of the latest thought, else `Working`); the clock counts the step
/// it names (a call, a thought) or, for `Working`, the turn from the instant
/// the person pressed Send (`AgentSessionView.turnStartedAt`, so it is there in
/// the first frame). When nothing has arrived for a minute it adds `Quiet for
/// 2m`, the honest stuck signal ([quietFor]). Nothing moves, nothing spins:
/// the seconds step once a second, and a step with no known start has no
/// clock.
///
/// Not shown while the agent waits for the person (the dock owns that), and
/// gone when the turn ends, except that an agent which waits on background
/// work says `Waiting for bg_6 · 14m` (the minute clock). Its line is always
/// laid out, empty when nothing runs, so the end of a turn slides no row.
class StatusLine extends StatefulWidget {
  const StatusLine({super.key, required this.session});

  final AgentSessionView session;

  @override
  State<StatusLine> createState() => _StatusLineState();
}

class _StatusLineState extends State<StatusLine> with StepClockLease<StatusLine> {
  late bool _active = _isActive();
  List<TranscriptItem>? _items;
  AgentPhase? _phase;
  List<PendingRequest>? _pending;

  /// The agent waits on background work: the line says so instead of an
  /// activity ([BackgroundWork] by identity: the session replaces it).
  BackgroundWork? _waitingOn;

  bool _isActive() {
    final a = activityOf(widget.session.state, now: statusNow());
    return a != null && a.kind != ActivityKind.waiting;
  }

  BackgroundWork? _waiting() => widget.session.waitingOnBackground ? widget.session.backgroundWork : null;

  @override
  StepClock get clock => secondsClock;

  // The waiting line counts by the minute (its own clock); no seconds clock.
  @override
  bool get wantsClock => _active && _waitingOn == null;

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_onSession);
    _remember();
  }

  @override
  void didUpdateWidget(StatusLine old) {
    super.didUpdateWidget(old);
    if (old.session != widget.session) {
      old.session.removeListener(_onSession);
      widget.session.addListener(_onSession);
      _active = _isActive();
      _remember();
      syncClock();
    }
  }

  @override
  void dispose() {
    widget.session.removeListener(_onSession);
    super.dispose();
  }

  void _remember() {
    final s = widget.session.state;
    _items = s.items;
    _phase = s.phase;
    _pending = s.pending;
    _waitingOn = _waiting();
  }

  /// A notification comes with every frame of text: this changes something
  /// only when the transcript, the phase, the requests or the work do.
  void _onSession() {
    final s = widget.session.state;
    final waiting = _waiting();
    final waitChanged = !identical(waiting, _waitingOn);
    if (identical(s.items, _items) && s.phase == _phase && identical(s.pending, _pending) && !waitChanged) return;
    _remember();
    final active = _isActive();
    if (active == _active) {
      if (mounted && (active || waitChanged)) setState(() {});
      if (waitChanged) syncClock();
      return;
    }
    setState(() => _active = active);
    syncClock();
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final style = Type.secondary.copyWith(color: ds.textSecondary, fontFeatures: Type.tabular);
    final work = _waitingOn;
    if (work != null) {
      return Padding(
        padding: const EdgeInsets.only(top: Gap.md),
        child: _WaitingLine(work: work, style: style),
      );
    }
    // A no-break space keeps the height of the line while it is empty.
    if (!_active) {
      return Padding(
        padding: const EdgeInsets.only(top: Gap.md),
        child: Text('\u00A0', style: style),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: Gap.md),
      child: ValueListenableBuilder<int>(
        valueListenable: clock.steps,
        builder: (context, _, _) {
          final now = statusNow();
          final state = widget.session.state;
          final activity = activityOf(state, now: now);
          if (activity == null || activity.kind == ActivityKind.waiting) {
            return Text('\u00A0', style: style);
          }
          final words = activityWords(activity);
          final since = activity.kind == ActivityKind.working ? widget.session.turnStartedAt : activity.since;
          final clockText = since == null ? null : Elapsed.compact(now.difference(since));
          final quiet = activity.quiet;
          final quietText = quiet == null ? null : 'Quiet for ${Elapsed.compact(quiet, seconds: false)}';
          return Semantics(
            label: quietText == null ? words : '$words, $quietText',
            child: ExcludeSemantics(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(words, maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
                      ),
                      if (clockText != null) Text(' \u00b7 $clockText', maxLines: 1, style: style),
                    ],
                  ),
                  if (quietText != null)
                    Text(
                      quietText,
                      maxLines: 1,
                      style: Type.secondaryStrong.copyWith(color: ds.text, fontFeatures: Type.tabular),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// `Waiting for bg_6 · 14m`: the turn is over and the agent waits on
/// background work. The clock counts from the oldest start among the tasks, by
/// the minute; with no known start (or no known task) there is none.
class _WaitingLine extends StatelessWidget {
  const _WaitingLine({required this.work, required this.style});

  final BackgroundWork work;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final words = waitingSentence(work);
    final start = work.oldestStart;
    return MinuteBuilder(
      builder: (context, now) {
        final clock = start == null || work.runningCount == 0 ? null : Elapsed.compact(now.difference(start));
        return Semantics(
          label: clock == null ? words : '$words, $clock',
          child: ExcludeSemantics(
            child: Row(
              children: [
                Flexible(
                  child: Text(words, maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
                ),
                if (clock != null) Text(' \u00b7 $clock', maxLines: 1, style: style),
              ],
            ),
          ),
        );
      },
    );
  }
}
