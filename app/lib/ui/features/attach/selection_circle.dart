import 'package:flutter/material.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

/// The tappable selection mark of a tile or a row: the kit's [SelectMark]
/// (an empty ring, or the accent filled with the pick's place: 1, 2, 3...)
/// painted [SelectMark.photoSize], hit-tested [kMinTap] around its centre.
/// On a photo ([onPhoto]) the empty ring is white on a dark wash so it reads
/// on any picture.
class SelectionCircle extends StatelessWidget {
  const SelectionCircle({
    super.key,
    required this.number,
    required this.onTap,
    required this.label,
    this.onPhoto = false,
  });

  /// 1-based place in the tray; null when not picked.
  final int? number;
  final VoidCallback onTap;

  /// What a screen reader says: `Select photo 12`, `Deselect photo 12`.
  final String label;
  final bool onPhoto;

  @override
  Widget build(BuildContext context) => PressBuilder(
    onTap: onTap,
    haptic: true,
    scale: PressScale.icon,
    minTapSize: kMinTap,
    semanticLabel: label,
    selected: number != null,
    builder: (context, pressed) =>
        SelectMark(selected: number != null, number: number, onPhoto: onPhoto, size: SelectMark.photoSize),
  );
}
