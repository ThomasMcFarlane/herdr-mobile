import 'package:flutter/material.dart';

import 'motion.dart';
import 'theme.dart';
import 'press.dart';
import 'roll_text.dart';

/// Pill used for filters, tags and pick-one rows. [leading] is a small glyph
/// (a status glyph keeps its own colour); [icon] is a Lucide icon the chip
/// colours with its label. [count] is rendered with tabular figures and rolls
/// when it changes ([RollText]). Paints 32
/// high, takes a 44 touch target (headers reserve [height] for a chip row).
///
/// Selected is a tint of the accent with the label in accent text: a tint,
/// never a ring, so a row of chips never becomes a row of boxes.
class AppChip extends StatelessWidget {
  const AppChip({
    super.key,
    required this.label,
    this.leading,
    this.icon,
    this.count,
    this.selected = false,
    this.tint,
    this.semanticLabel,
    this.onTap,
  });

  final String label;
  final Widget? leading;
  final IconData? icon;
  final int? count;
  final bool selected;

  /// A state colour (`dangerText`): the chip takes the state's wash and its
  /// words in that colour. For a chip that names a state, never as decoration.
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
    final fg = tint ?? (selected ? ds.accentText : ds.textSecondary);
    return PressBuilder(
      onTap: onTap,
      scale: PressScale.chip,
      haptic: true,
      semanticLabel: semanticLabel ?? (count == null ? label : '$label, $count'),
      selected: selected,
      minTapSize: kMinTap,
      builder: (context, pressed) => AnimatedContainer(
        duration: Motion.pressing(pressed),
        curve: Motion.easeOut,
        height: _pill,
        padding: const EdgeInsets.symmetric(horizontal: Gap.md),
        decoration: BoxDecoration(
          color: tint != null
              ? (pressed ? ds.washPressed(tint!) : ds.wash(tint!))
              : selected
              ? (pressed ? ds.accentWashPressed : ds.accentWash)
              : pressed
              ? ds.fillPressed
              : ds.fill,
          borderRadius: BorderRadius.circular(Radii.pill),
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
              style: Type.labelStrong.copyWith(color: fg),
            );
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (leading != null) ...[leading!, const SizedBox(width: Gap.sm)],
                if (icon != null) ...[Icon(icon, size: IconSize.inline, color: fg), const SizedBox(width: Gap.sm)],
                box.hasBoundedWidth ? Flexible(child: text) : text,
                if (count != null) ...[
                  const SizedBox(width: Gap.sm),
                  RollText(
                    text: '$count',
                    style: Type.count.copyWith(color: selected ? ds.accentText : ds.textMuted),
                    overflow: TextOverflow.visible,
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
