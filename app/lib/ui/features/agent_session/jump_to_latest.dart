import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

/// The way back to the end of the conversation, shown while the reader is
/// away from it ([visible]): a round chevron, or, when blocks of the answer
/// have been finished since they left, a pill that says how many (`3 new`,
/// rolling as it grows). Announced as `3 new, jump to latest`. A compact
/// [FloatingPill]: 36 high in a 44 dp target, in and out with a fade and a
/// small scale.
class JumpToLatest extends StatelessWidget {
  const JumpToLatest({super.key, required this.newBlocks, required this.onPressed, this.visible = true});

  /// Blocks finished since the reader left the end; 0 shows the chevron.
  final int newBlocks;
  final VoidCallback onPressed;
  final bool visible;

  @override
  Widget build(BuildContext context) {
    final count = newBlocks > 0;
    return FloatingPill(
      icon: count ? null : LucideIcons.chevronsDown,
      label: count ? '$newBlocks new' : null,
      trailing: count ? Icon(LucideIcons.chevronsDown, size: IconSize.row, color: context.ds.textSecondary) : null,
      size: FloatingPillSize.compact,
      tooltip: 'Jump to latest',
      semanticLabel: count ? '$newBlocks new, jump to latest' : 'Jump to latest',
      haptic: false,
      visible: visible,
      onTap: onPressed,
    );
  }
}
