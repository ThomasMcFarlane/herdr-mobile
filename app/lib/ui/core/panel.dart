import 'package:flutter/material.dart';

import 'motion.dart';
import 'press.dart';
import 'rows.dart';
import 'tokens.dart';

/// What a [Panel] sits on.
enum PanelTone {
  /// [Ds.fill]: a block inside content (a message, an output, a preview).
  fill,

  /// [Ds.surface] with a hairline: a raised block on a fill or a card.
  surface,
}

/// The one content container: a rounded block, [Radii.md], no other border.
class Panel extends StatelessWidget {
  const Panel({
    super.key,
    this.tone = PanelTone.fill,
    required this.child,
    this.padding = const EdgeInsets.all(Gap.md),
  });

  final PanelTone tone;
  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tone == PanelTone.fill ? ds.fill : ds.surface,
        borderRadius: BorderRadius.circular(Radii.md),
        border: tone == PanelTone.surface ? Border.all(color: ds.hairline) : null,
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}

/// A [Panel] that folds: a pressable header (at least [kMinTap] high, a
/// [Caret] at its end) over a body that opens and closes in a [Collapse].
///
/// The header's pressed fill is [Ds.pressTint] clipped to the panel's corners.
/// Announced as a button that reports its expanded state.
class FoldPanel extends StatelessWidget {
  const FoldPanel({
    super.key,
    required this.header,
    required this.child,
    required this.expanded,
    required this.onToggle,
    this.tone = PanelTone.fill,
    this.semanticLabel,
  });

  final Widget header;
  final Widget child;
  final bool expanded;
  final ValueChanged<bool> onToggle;
  final PanelTone tone;

  /// Replaces the header's merged text when it does not say what folds.
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return ClipRRect(
      borderRadius: BorderRadius.circular(Radii.md),
      child: Panel(
        tone: tone,
        padding: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              expanded: expanded,
              child: PressBuilder(
                onTap: () => onToggle(!expanded),
                haptic: true,
                semanticLabel: semanticLabel,
                builder: (context, pressed) => AnimatedContainer(
                  duration: Motion.pressing(pressed),
                  curve: Motion.easeOut,
                  constraints: const BoxConstraints(minHeight: kMinTap),
                  color: pressed ? ds.pressTint : ds.pressTint.withAlpha(0),
                  padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
                  child: Row(
                    children: [
                      Expanded(child: header),
                      const SizedBox(width: Gap.sm),
                      Caret(open: expanded),
                    ],
                  ),
                ),
              ),
            ),
            Collapse(
              open: expanded,
              child: Padding(padding: const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, Gap.md), child: child),
            ),
          ],
        ),
      ),
    );
  }
}
