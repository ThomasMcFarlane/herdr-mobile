import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

import '../../../data/models/herdr_models.dart';
import '../../../data/words/plural.dart';

/// "1 needs you · 2 to review": floats above the tab bar while any reachable
/// agent (terminal pane or agent session) is blocked, and starts the triage
/// sheet that walks through them. Both numbers are the `AttentionSet`'s: the
/// first is the Agents tab's badge, the second the finished agents that can
/// be reached and are not yet reviewed ([review], left out at 0). It is
/// information; a tap still goes to the blocked agents.
///
/// A [FloatingPill]: the bar's furniture, the blocked glyph its only colour.
/// The count rolls when it changes.
class TriagePill extends StatelessWidget {
  const TriagePill({super.key, required this.count, this.review = 0, required this.onTap});

  /// Reachable blocked agents ("needs you").
  final int count;

  /// Reachable finished agents not yet reviewed ("to review").
  final int review;
  final VoidCallback onTap;

  static const height = FloatingPill.regularHeight;

  @override
  Widget build(BuildContext context) => FloatingPill(
    leading: const StatusGlyph(status: AgentStatus.blocked, size: IconSize.row),
    label: needYou(count),
    detail: review > 0 ? '$review to review' : null,
    trailing: Icon(LucideIcons.chevronRight, size: IconSize.row, color: context.ds.textTertiary),
    onTap: onTap,
    roll: true,
  );
}
