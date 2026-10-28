import 'package:flutter/widgets.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

import 'agent_card.dart' show StateTime;
import 'agent_session_rows.dart' show SessionStateTime, sessionMeta;
import 'agents_grouping.dart';

/// The agent a swipe between agents leads to, as the board's row shows it:
/// status glyph, title (up to two lines, as on the board), where it runs and
/// how long it has been in its state. A glance, not the row.
///
/// [fromLeft] (a swipe right, to the previous agent): the card comes in from
/// the left, so it is laid out the other way round, glyph and title at its
/// right edge. Whichever side it enters from, what shows first is who it is.
class AgentPeekCard extends StatelessWidget {
  const AgentPeekCard({super.key, required this.item, required this.fromLeft});

  final BoardItem item;
  final bool fromLeft;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final (status, title, where, time, dim) = switch (item) {
      PaneItem(:final row) => (row.status, row.title, row.subtitle, StateTime(agent: row) as Widget, row.stale),
      SessionItem(:final session) => (
        boardStatus(session),
        session.title,
        sessionMeta(session),
        SessionStateTime(session: session) as Widget,
        false,
      ),
    };
    final align = fromLeft ? TextAlign.end : TextAlign.start;
    final children = [
      StatusGlyph(status: status, size: IconSize.lead, dim: dim),
      const SizedBox(width: Gap.md),
      Expanded(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: fromLeft ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: align,
              style: Type.row.copyWith(color: ds.text),
            ),
            if (where.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: Gap.hair),
                child: Text(
                  where,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: align,
                  style: Type.secondary.copyWith(color: ds.textSecondary),
                ),
              ),
          ],
        ),
      ),
      const SizedBox(width: Gap.sm),
      time,
    ];
    return Row(children: fromLeft ? children.reversed.toList() : children);
  }
}

/// What a swipe past either end of the board's order shows: that there is
/// nothing there. Quiet: it is not news, only where the list ends.
class AgentPeekEnd extends StatelessWidget {
  const AgentPeekEnd({super.key, required this.next, this.listed = true});

  /// The swipe asked for the next agent (else the previous one).
  final bool next;

  /// The agent in front is in the board's order (else it has no neighbours).
  final bool listed;

  @override
  Widget build(BuildContext context) => Text(
    peekEndWords(next: next, listed: listed),
    maxLines: 1,
    style: Type.label.copyWith(color: context.ds.textMuted),
  );
}

/// What the end card says; the `Next agent` / `Previous agent` actions
/// announce the same at either end.
String peekEndWords({required bool next, required bool listed}) => !listed
    ? 'Not on the board'
    : next
    ? 'No next agent'
    : 'No previous agent';

/// The card a peek sits on: the floating lanes' look (surface, hairline, the
/// one float shadow), so it reads as something over the screen, not part of
/// it. [armed] (letting go now goes there) tints it with the accent, as a
/// selection is tinted, never outlined.
class PeekFrame extends StatelessWidget {
  const PeekFrame({super.key, required this.armed, required this.child});

  final bool armed;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return AnimatedContainer(
      duration: Motion.of(context, Motion.fade),
      curve: Motion.easeOut,
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: armed ? Color.alphaBlend(ds.accentWash, ds.surface) : ds.surface,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: ds.hairline),
        boxShadow: ds.floatShadow,
      ),
      child: child,
    );
  }
}
