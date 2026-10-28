import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'motion.dart';
import 'theme.dart';

enum SelectMarkShape {
  /// Pick one, or pick several in order: a round mark (a check or the place).
  circle,

  /// Pick any: a checkbox.
  square,
}

/// The one selection mark: an empty ring, or, when [selected], the accent
/// filled with a check (or with [number], the pick's place: 1, 2, 3). Only
/// the picture: the row or tile it sits on owns the tap and says "selected"
/// once, so the mark is excluded from semantics.
///
/// On a photo ([onPhoto]) the empty ring is [Ds.onPhoto] over [Ds.photoScrim],
/// so it reads on any picture. The fill changes over [Motion.standard].
class SelectMark extends StatelessWidget {
  const SelectMark({
    super.key,
    required this.selected,
    this.number,
    this.shape = SelectMarkShape.circle,
    this.onPhoto = false,
    this.size = defaultSize,
  });

  final bool selected;

  /// The pick's place, drawn in place of the check while [selected].
  final int? number;
  final SelectMarkShape shape;
  final bool onPhoto;
  final double size;

  /// A mark in a row's leading column or on a card.
  static const defaultSize = 20.0;

  /// A mark on a photo tile, big enough to carry a two-digit place.
  static const photoSize = 24.0;

  static const _ring = 1.5;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final round = shape == SelectMarkShape.circle;
    final Color fill;
    final Color ring;
    if (selected) {
      fill = ds.accent;
      // On a photo the ring stays white, so the mark reads on an accent-like
      // picture (and on the accent pill of the photo viewer).
      ring = onPhoto ? ds.onPhoto : ds.accent;
    } else {
      // Opaque, so a mark over a card's edge hides the line under it.
      fill = onPhoto ? ds.photoScrim : ds.surface;
      ring = onPhoto ? ds.onPhoto : ds.textTertiary;
    }
    final number = this.number;
    return ExcludeSemantics(
      child: AnimatedContainer(
        duration: Motion.of(context, Motion.standard),
        curve: Motion.easeOut,
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: round ? BoxShape.circle : BoxShape.rectangle,
          borderRadius: round ? null : BorderRadius.circular(Radii.xs),
          color: fill,
          border: Border.all(color: ring, width: _ring),
        ),
        child: !selected
            ? null
            : number != null
            ? Text(
                '$number',
                maxLines: 1,
                textScaler: TextScaler.noScaling,
                style: Type.badge.copyWith(color: ds.onAccent),
              )
            : Icon(LucideIcons.check, size: IconSize.inline, color: ds.onAccent),
      ),
    );
  }
}
