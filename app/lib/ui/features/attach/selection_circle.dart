import 'dart:async';

import 'package:flutter/material.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

/// The tappable selection mark of a tile or a row: the kit's [SelectMark]
/// (an empty ring, or the accent filled with the pick's place: 1, 2, 3...)
/// painted [SelectMark.photoSize], hit-tested [kMinTap] around its centre.
/// On a photo ([onPhoto]) the empty ring is white on a dark wash so it reads
/// on any picture.
///
/// The change is feedback on the circle itself: a new number pops in from 0.9
/// to 1 over `Motion.press`, so the eye that tapped sees the pick land where
/// it tapped. Not under reduced motion.
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
    builder: (context, pressed) {
      final mark = SelectMark(selected: number != null, number: number, onPhoto: onPhoto, size: SelectMark.photoSize);
      return Motion.reduced(context) ? mark : _Pop(number: number, child: mark);
    },
  );
}

/// Scales its child from 0.9 to 1 over `Motion.press` when [number] changes
/// (not when it first appears: a scrolled-in tile does not animate). The
/// controller exists only after the first change.
class _Pop extends StatefulWidget {
  const _Pop({required this.number, required this.child});

  final int? number;
  final Widget child;

  @override
  State<_Pop> createState() => _PopState();
}

class _PopState extends State<_Pop> with SingleTickerProviderStateMixin {
  AnimationController? _c;

  @override
  void didUpdateWidget(_Pop old) {
    super.didUpdateWidget(old);
    if (old.number == widget.number) return;
    _c ??= AnimationController(vsync: this, duration: Motion.press);
    unawaited(_c!.forward(from: 0).catchError((Object _) {}));
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    if (c == null) return widget.child;
    return AnimatedBuilder(
      animation: c,
      child: widget.child,
      builder: (context, child) =>
          c.isAnimating ? Transform.scale(scale: 0.9 + 0.1 * Motion.easeOut.transform(c.value), child: child) : child!,
    );
  }
}
