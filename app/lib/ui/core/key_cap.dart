import 'dart:async';

import 'package:flutter/material.dart';

import 'motion.dart';
import 'press.dart';
import 'theme.dart';

/// A key a phone keyboard lacks (`esc`, `tab`, an arrow, `ctrl`): a soft
/// rounded cap 36 high in a 44 dp target, at least 44 wide.
///
/// Keys are pressed often and fast, so a cap changes colour under the finger
/// and never scales. With [onRepeat] a held key repeats: after
/// [Dwell.keyRepeatDelay], then every [Dwell.keyRepeatGap], each repeat
/// waiting for the last one to finish so a slow link never builds a queue.
/// A finger that moves off (a scroll of the row) stops the repeat.
///
/// [active] true is an armed modifier (`ctrl` waiting for the next key): the accent
/// tint, announced as selected.
class KeyCap extends StatefulWidget {
  const KeyCap({
    super.key,
    this.label,
    this.icon,
    required this.onTap,
    this.onRepeat,
    this.active,
    this.semanticLabel,
  }) : assert((label == null) != (icon == null), 'a label or an icon');

  final String? label;
  final IconData? icon;

  /// Null disables the key.
  final VoidCallback? onTap;

  /// One repeat of a held key; awaited before the next.
  final FutureOr<void> Function()? onRepeat;

  /// An armed modifier; null for a key that is not a toggle.
  final bool? active;

  /// What a screen reader says; required in practice for an [icon] key
  /// (`Up`), a [label] key reads its label.
  final String? semanticLabel;

  /// Painted height of the cap.
  static const height = 36.0;

  /// A finger that moves further than this is scrolling the row, not holding.
  static const holdSlop = 10.0;

  @override
  State<KeyCap> createState() => _KeyCapState();
}

class _KeyCapState extends State<KeyCap> {
  Timer? _timer;
  Offset _downAt = Offset.zero;
  bool _holding = false;

  /// The hold already pressed the key, so the tap that ends it must not.
  bool _repeated = false;

  bool get _repeats => widget.onRepeat != null && widget.onTap != null;

  void _down(PointerDownEvent event) {
    if (!_repeats) return;
    _downAt = event.position;
    _holding = true;
    _repeated = false;
    _timer = Timer(Dwell.keyRepeatDelay, _tick);
  }

  void _move(PointerMoveEvent event) {
    if (_holding && (event.position - _downAt).distance > KeyCap.holdSlop) _stop();
  }

  void _stop() {
    _holding = false;
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _tick() async {
    final repeat = widget.onRepeat;
    if (!_holding || repeat == null) return;
    _repeated = true;
    await repeat();
    if (_holding && mounted) _timer = Timer(Dwell.keyRepeatGap, _tick);
  }

  void _tap() {
    if (_repeated) {
      _repeated = false;
      return;
    }
    Haptics.tick();
    widget.onTap?.call();
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final enabled = widget.onTap != null;
    final active = widget.active ?? false;
    // A disabled key loses its cap and keeps readable words: it is inert, not
    // hidden.
    final (fg, iconColor) = active ? (ds.accentText, ds.accentText) : (ds.textMuted, ds.textSecondary);
    final cap = PressBuilder(
      onTap: enabled ? _tap : null,
      button: true,
      selected: widget.active,
      semanticLabel: widget.semanticLabel,
      minTapSize: kMinTap,
      builder: (context, pressed) => AnimatedContainer(
        duration: Motion.pressing(pressed),
        curve: Motion.easeOut,
        height: KeyCap.height,
        constraints: const BoxConstraints(minWidth: kMinTap),
        padding: const EdgeInsets.symmetric(horizontal: Gap.md),
        decoration: BoxDecoration(
          color: !enabled
              ? Colors.transparent
              : active
                  ? (pressed ? ds.accentWashPressed : ds.accentWash)
                  : (pressed ? ds.fillPressed : ds.fill),
          borderRadius: BorderRadius.circular(Radii.sm),
        ),
        // widthFactor: shrink-wrap, so a Wrap gives it its own width, not all.
        child: Center(
          widthFactor: 1,
          child: widget.icon != null
              ? Icon(widget.icon, size: IconSize.row, color: iconColor)
              : Text(widget.label!, maxLines: 1, style: Mono.input.copyWith(color: fg)),
        ),
      ),
    );
    if (!_repeats) return cap;
    return Listener(
      onPointerDown: _down,
      onPointerMove: _move,
      onPointerUp: (_) => _stop(),
      onPointerCancel: (_) => _stop(),
      child: cap,
    );
  }
}
