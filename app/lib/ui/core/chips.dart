import 'package:flutter/material.dart';

import 'motion.dart';
import 'status_panel.dart' show StatusTint;
import 'theme.dart';
import 'press.dart';

/// Pill used for filters and tags. [leading] is a small glyph, [count] is
/// rendered with tabular figures. Paints 32 high, takes a 44 touch target
/// (headers reserve [height] for a chip row).
class AppChip extends StatelessWidget {
  const AppChip({
    super.key,
    required this.label,
    this.leading,
    this.count,
    this.selected = false,
    this.tint,
    this.semanticLabel,
    this.onTap,
  });

  final String label;
  final Widget? leading;
  final int? count;
  final bool selected;

  /// A state colour (`dangerText`): the chip takes the tint of a status
  /// strip (a 12% fill with a faint outline) and its words in that colour.
  /// For a chip that names a state, never as decoration.
  final Color? tint;

  /// What a screen reader says in place of [label] (and [count]).
  final String? semanticLabel;
  final VoidCallback? onTap;

  /// Layout height including the touch padding above and below the pill.
  static const height = kMinTap;

  /// The widest a chip grows in a row of chips above a composer (settings,
  /// quick phrases); a longer label ends in an ellipsis. Grows with the text,
  /// so a larger size cuts no more words.
  static double maxRowWidth(BuildContext context) => 240 * MediaQuery.textScalerOf(context).scale(14) / 14;

  static const _pill = 32.0;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return PressBuilder(
      onTap: onTap,
      scale: 0.96,
      haptic: true,
      semanticLabel: semanticLabel ?? (count == null ? label : '$label, $count'),
      selected: selected,
      minTapSize: kMinTap,
      builder: (context, pressed) => AnimatedContainer(
        duration: Motion.pressing(pressed),
        curve: Motion.easeOut,
        height: _pill,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          // A tint, not an outline: a row of outlined pills is a row of
          // boxes. Selected is the deeper tint and keeps a ring.
          color: tint != null
              ? tint!.withValues(alpha: pressed ? StatusTint.fillAlpha + 0.06 : StatusTint.fillAlpha)
              : selected || pressed
              ? ds.fillPressed
              : ds.fill,
          borderRadius: BorderRadius.circular(_pill / 2),
          border: Border.all(
            color: tint != null
                ? tint!.withValues(alpha: StatusTint.borderAlpha)
                : selected
                ? ds.textTertiary.withValues(alpha: 0.5)
                : Colors.transparent,
          ),
        ),
        // A label wider than the room it is given ends in an ellipsis. A
        // scrolling row gives unbounded room, where a Flexible is not allowed
        // and the label simply takes what it needs.
        child: LayoutBuilder(
          builder: (context, box) {
            final text = Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Type.label.copyWith(
                color: tint ?? (selected ? ds.text : ds.textSecondary),
                fontWeight: FontWeight.w600,
              ),
            );
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (leading != null) ...[leading!, const SizedBox(width: 7)],
                box.hasBoundedWidth ? Flexible(child: text) : text,
                if (count != null) ...[
                  const SizedBox(width: 6),
                  Text(
                    '$count',
                    style: Type.label.copyWith(
                      color: ds.textMuted,
                      fontFeatures: Type.tabular,
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}
