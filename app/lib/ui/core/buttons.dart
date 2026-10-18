import 'package:flutter/material.dart';

import 'motion.dart';
import 'theme.dart';
import 'press.dart';
import 'spinner.dart';

enum AppButtonKind { primary, secondary, ghost, danger }

/// Flat button: 9px radius, no elevation, no ripple. [compact] paints 36 high
/// but still takes a 44 touch target.
class AppButton extends StatelessWidget {
  const AppButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.kind = AppButtonKind.primary,
    this.expand = false,
    this.loading = false,
    this.compact = false,
  });

  final String label;

  /// Null disables the button.
  final VoidCallback? onPressed;
  final IconData? icon;
  final AppButtonKind kind;
  final bool expand;

  /// Shows a spinner and ignores taps.
  final bool loading;

  /// Smaller (36px painted, 44px touch) for inline use in banners and rows.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final (bg, fg, pressedBg) = switch (kind) {
      AppButtonKind.primary => (ds.accent, ds.onAccent, Color.alphaBlend(Colors.black.withValues(alpha: 0.12), ds.accent)),
      AppButtonKind.secondary => (ds.fill, ds.text, ds.fillPressed),
      AppButtonKind.ghost => (Colors.transparent, ds.accentText, ds.fill),
      AppButtonKind.danger => (ds.danger.withValues(alpha: 0.12), ds.dangerText, ds.danger.withValues(alpha: 0.2)),
    };
    final enabled = onPressed != null && !loading;
    final dimmed = onPressed == null && !loading;
    final h = compact ? 36.0 : 46.0;
    return PressBuilder(
      onTap: enabled ? onPressed : null,
      scale: 0.97,
      haptic: kind == AppButtonKind.primary,
      button: true,
      minTapSize: kMinTap,
      // Dimming is baked into the colours: an Opacity layer here would cost a
      // composited layer per button for a state that is almost always off.
      builder: (context, pressed) => TweenAnimationBuilder<double>(
        tween: Tween(end: dimmed ? 0.4 : 1),
        duration: Motion.standard,
        builder: (context, k, _) {
          Color dim(Color c) => k == 1 ? c : c.withValues(alpha: c.a * k);
          return AnimatedContainer(
            duration: Motion.pressing(pressed),
            curve: Motion.easeOut,
            height: h,
            width: expand ? double.infinity : null,
            padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 18),
            decoration: BoxDecoration(
              color: dim(pressed ? pressedBg : bg),
              borderRadius: BorderRadius.circular(Radii.control),
            ),
            child: Row(
              mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (loading)
                  BusySpinner(color: dim(fg))
                else if (icon != null)
                  Icon(icon, size: compact ? 16 : 18, color: dim(fg)),
                if (loading || icon != null) const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Type.button.copyWith(
                      color: dim(fg),
                      fontSize: compact ? 13.5 : 15,
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Round icon button, 40px painted (44px touch): the Notion header control. A
/// soft tinted disc with no outline (a ring around every header icon is the
/// loudest repeated line on a screen); [filled] false is a bare icon.
class CircleButton extends StatelessWidget {
  const CircleButton({
    super.key,
    required this.icon,
    required this.onPressed,
    required this.tooltip,
    this.size = 40,
    this.active = false,
    this.filled = true,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String tooltip;
  final double size;

  /// Toggled-on state (accent tint).
  final bool active;

  /// Draw the soft disc; false for a bare icon.
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Tooltip(
      message: tooltip,
      // The press node below carries the label; the tooltip would add a second.
      excludeFromSemantics: true,
      child: PressBuilder(
        onTap: onPressed,
        scale: 0.92,
        semanticLabel: tooltip,
        button: true,
        selected: active ? true : null,
        minTapSize: kMinTap,
        builder: (context, pressed) => AnimatedContainer(
          duration: Motion.pressing(pressed),
          curve: Motion.easeOut,
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: active
                ? ds.accent.withValues(alpha: ds.isDark ? 0.22 : 0.14)
                : filled
                    ? (pressed ? ds.fillPressed : ds.fill)
                    : (pressed ? ds.fill : Colors.transparent),
          ),
          alignment: Alignment.center,
          child: Icon(icon, size: size * 0.5, color: active ? ds.accentText : ds.text),
        ),
      ),
    );
  }
}
