import 'package:flutter/material.dart';

import 'theme.dart';

/// How far a transfer is along: a thin bar that fills from the left. For work
/// whose size is known (a picture or a video being copied to the phone); work
/// of unknown length says so in words instead. It fills as the numbers arrive
/// and does nothing else: nothing here loops.
///
/// Takes the width its parent gives it.
class ProgressLine extends StatelessWidget {
  const ProgressLine({super.key, required this.fraction});

  /// 0 to 1; anything outside is clamped.
  final double fraction;

  /// The bar's thickness.
  static const height = 3.0;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return SizedBox(
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(color: ds.fill, borderRadius: BorderRadius.circular(Radii.pill)),
        child: Align(
          alignment: Alignment.centerLeft,
          child: FractionallySizedBox(
            widthFactor: fraction.clamp(0.0, 1.0),
            heightFactor: 1,
            child: DecoratedBox(
              decoration: BoxDecoration(color: ds.accent, borderRadius: BorderRadius.circular(Radii.pill)),
            ),
          ),
        ),
      ),
    );
  }
}
