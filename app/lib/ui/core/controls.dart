import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'motion.dart';
import 'status_panel.dart' show StatusTint;
import 'theme.dart';

/// Smallest comfortable touch target (dp). Controls that paint smaller than
/// this still hit-test at least this big.
const kMinTap = 44.0;

/// Where chrome bars stop growing with the system text size: their blocks
/// are fixed height, and three tab cells hold "Machines" at 320 dp at this.
const kBarTextScale = 1.15;

/// Press handling shared by every control: feedback on pointer-down (after the
/// scroll-intent delay, so scrolling a list never flashes rows), commit on up,
/// cancel by dragging away. No ripple. Optional press scale.
///
/// Semantics (one node per control, never duplicated):
/// - [semanticLabel] null (default): the visible text inside [builder] merges
///   into one label. Use this wherever the child already says what it is.
/// - [semanticLabel] set: it REPLACES everything inside, so icon-only controls
///   and rows with a hand-composed label say it exactly once.
/// - The button role is announced only when the control can be tapped (or
///   [button] says so, for dimmed buttons). A plain label stays plain text.
/// - [selected] adds the selected state (tabs, segments, filter chips).
class PressBuilder extends StatefulWidget {
  const PressBuilder({
    super.key,
    required this.builder,
    this.onTap,
    this.onLongPress,
    this.scale = 1,
    this.haptic = false,
    this.semanticLabel,
    this.selected,
    this.button,
    this.minTapSize = 0,
  });

  final Widget Function(BuildContext context, bool pressed) builder;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Scale while pressed (1 = none). Small controls use ~0.96, rows none.
  final double scale;

  /// Selection haptic on tap.
  final bool haptic;
  final String? semanticLabel;

  /// Selected state for toggles, tabs and segments; null for plain buttons.
  final bool? selected;

  /// Announce as a button. Defaults to "can be tapped"; a disabled
  /// [AppButton] passes true so it reads as a dimmed button.
  final bool? button;

  /// Minimum width and height of the touch target. The painted child keeps its
  /// size and is centred inside it.
  final double minTapSize;

  @override
  State<PressBuilder> createState() => _PressBuilderState();
}

class _PressBuilderState extends State<PressBuilder> {
  bool _down = false;

  void _set(bool v) {
    if (_down != v && mounted) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null || widget.onLongPress != null;
    final active = _down && enabled;
    Widget child = widget.builder(context, active);
    if (widget.scale != 1 && !Motion.reduced(context)) {
      child = AnimatedScale(
        scale: active ? widget.scale : 1,
        duration: Motion.pressing(_down),
        curve: Motion.easeOut,
        child: child,
      );
    }
    if (widget.minTapSize > 0) {
      child = ConstrainedBox(
        constraints: BoxConstraints(
          minWidth: widget.minTapSize,
          minHeight: widget.minTapSize,
        ),
        child: Align(widthFactor: 1, heightFactor: 1, child: child),
      );
    }
    final isButton = widget.button ?? enabled;
    final label = widget.semanticLabel;
    return Semantics(
      button: isButton,
      enabled: isButton ? enabled : null,
      selected: widget.selected,
      label: label,
      excludeSemantics: label != null,
      // Assistive-tech activation goes straight to the callbacks; the gesture
      // detector below is pointer-only so it adds no second semantics node.
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        onTapDown: enabled ? (_) => _set(true) : null,
        onTapUp: enabled ? (_) => _set(false) : null,
        onTapCancel: enabled ? () => _set(false) : null,
        onTap: widget.onTap == null
            ? null
            : () {
                if (widget.haptic) Haptics.tick();
                widget.onTap!();
              },
        onLongPress: widget.onLongPress == null
            ? null
            : () {
                Haptics.hold();
                widget.onLongPress!();
              },
        child: child,
      ),
    );
  }
}

/// The one indeterminate spinner: a thin round-capped ring, for work the user
/// is waiting on (a button that is saving, a send in flight). It is the only
/// looping animation in the app; keep it short-lived and never use it as
/// decoration.
class BusySpinner extends StatelessWidget {
  const BusySpinner({super.key, this.size = 14, this.color});

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => SizedBox.square(
        dimension: size,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          strokeCap: StrokeCap.round,
          color: color ?? context.ds.textSecondary,
        ),
      );
}

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

class SegmentOption<T> {
  const SegmentOption(this.value, this.label, {this.icon, this.count, this.leading});

  final T value;
  final String label;
  final IconData? icon;

  /// A number after the label (`Pages 17`), muted, in tabular figures.
  final int? count;

  /// A small widget before the label (a live dot). Not drawn with an [icon].
  final Widget? leading;
}

/// The app's one switch: a slim tinted pill (`ds.fill`, no border) and ONE
/// capsule under the chosen cell, lighter than the pill (white on the tint,
/// `ds.fillPressed` on ink): the tab bar's capsule, without its outline. It picks the value of a setting (theme,
/// density) and switches what a sheet shows (the kinds of what a session made);
/// the job differs, the look does not.
///
/// Cells are equal width when every option fits at its own size, and the row
/// scrolls sideways (cells as wide as their content) when one does not, so a
/// label is never cut to fit. The capsule slides to the chosen cell
/// ([Motion.standard], [Motion.easeOut]; it jumps under reduced motion) and
/// one number, its place in cell units, drives it and every cell's colour, so
/// a label warms as the capsule arrives under it and cools as it leaves, in
/// step (the label weight never changes: it cannot be interpolated, and used to
/// snap on its own). No press scale, no ripple. Text stops growing at 1.2x: the
/// pill is a fixed 44 dp and every option is a full-height touch target.
class Segmented<T> extends StatefulWidget {
  const Segmented({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
  });

  final List<SegmentOption<T>> options;
  final T value;
  final ValueChanged<T> onChanged;

  @override
  State<Segmented<T>> createState() => _SegmentedState<T>();
}

class _SegmentedState<T> extends State<Segmented<T>> {
  /// The capsule's air inside the pill.
  static const _inset = 2.0;
  /// Air at each side of a label: [_pad] when the row scrolls, at least [_padMin] when the cells are equal.
  static const _pad = 14.0;
  static const _padMin = 8.0;
  static const _gap = 6.0;

  final _scroll = ScrollController();
  var _placed = false;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  TextStyle get _style => Type.label.copyWith(fontSize: 13.5, fontWeight: FontWeight.w600);

  /// How wide an option's content is, without its padding.
  double _contentWidth(BuildContext context, SegmentOption<T> o, {required bool icons}) {
    final scaler = MediaQuery.textScalerOf(context);
    double text(String s, TextStyle style) {
      final p = TextPainter(
        text: TextSpan(text: s, style: style),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      return p.width;
    }

    var w = text(o.label, _style);
    if (icons && o.icon != null) w += 15 + _gap;
    if (o.leading != null) w += 8 + _gap;
    if (o.count != null) w += 5 + text('${o.count}', _style.copyWith(fontWeight: FontWeight.w500));
    return w;
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final options = widget.options;
    final n = options.length;
    final index = options.indexWhere((o) => o.value == widget.value).clamp(0, n - 1);
    final reduced = Motion.reduced(context);
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.2,
      child: Builder(
        builder: (context) => LayoutBuilder(
          builder: (context, box) {
            final inner = box.maxWidth;
            // Equal cells with the icons; else equal cells with the words alone (an icon
            // is decoration, a word is the option); else a scrolling row, icons kept.
            bool equal(bool icons) => options.every((o) => _contentWidth(context, o, icons: icons) + 2 * _padMin <= inner / n);
            final icons = equal(true) || !equal(false);
            final fits = equal(icons);
            final natural = [for (final o in options) _contentWidth(context, o, icons: true) + 2 * _pad];
            final widths = fits ? List.filled(n, inner / n) : natural;
            final lefts = <double>[];
            var x = 0.0;
            for (final w in widths) {
              lefts.add(x);
              x += w;
            }
            final total = x;
            if (!fits) _reveal(lefts[index], widths[index], inner, reduced, first: !_placed);
            _placed = true;
            return Container(
              height: kMinTap,
              decoration: BoxDecoration(
                color: ds.fill,
                borderRadius: BorderRadius.circular(kMinTap / 2),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(kMinTap / 2),
                child: ClipRect(
                  child: SingleChildScrollView(
                    controller: _scroll,
                    scrollDirection: Axis.horizontal,
                    physics: fits ? const NeverScrollableScrollPhysics() : null,
                    child: TweenAnimationBuilder<double>(
                      tween: Tween<double>(end: index.toDouble()),
                      duration: reduced ? Duration.zero : Motion.standard,
                      curve: Motion.easeOut,
                      builder: (context, place, _) {
                        // The capsule's left edge and width at [place], between the cells it is travelling across.
                        final lo = place.floor().clamp(0, n - 1);
                        final hi = place.ceil().clamp(0, n - 1);
                        final t = place - lo;
                        final capLeft = lefts[lo] + (lefts[hi] - lefts[lo]) * t;
                        final capWidth = widths[lo] + (widths[hi] - widths[lo]) * t;
                        return SizedBox(
                          width: total,
                          height: kMinTap,
                          child: Stack(
                            children: [
                              Positioned(
                                left: capLeft + _inset,
                                width: capWidth - 2 * _inset,
                                top: _inset,
                                bottom: _inset,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    // Lighter than the track in both themes: white on the tint, the next rung up on ink.
                                    color: ds.brightness == Brightness.dark ? ds.fillPressed : ds.surface,
                                    borderRadius: BorderRadius.circular(kMinTap / 2),
                                  ),
                                ),
                              ),
                              Row(
                                children: [
                                  for (final (i, o) in options.indexed)
                                    SizedBox(
                                      width: widths[i],
                                      child: _cell(context, o, i, place, icons: icons),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  /// Keeps the chosen cell in view when the row scrolls.
  void _reveal(double left, double width, double view, bool reduced, {required bool first}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final max = _scroll.position.maxScrollExtent;
      final want = (left + width / 2 - view / 2).clamp(0.0, max);
      if ((_scroll.offset - want).abs() < 1) return;
      if (first || reduced) {
        _scroll.jumpTo(want);
      } else {
        unawaited(_scroll.animateTo(want, duration: Motion.standard, curve: Motion.easeOut));
      }
    });
  }

  Widget _cell(BuildContext context, SegmentOption<T> o, int i, double place, {required bool icons}) {
    final ds = context.ds;
    final selected = o.value == widget.value;
    // 1 under the capsule, 0 a cell away: the colour follows the capsule.
    final warm = (1 - (place - i).abs()).clamp(0.0, 1.0);
    final color = Color.lerp(ds.textSecondary, ds.text, warm)!;
    return PressBuilder(
      onTap: () {
        if (!selected) widget.onChanged(o.value);
      },
      haptic: !selected,
      semanticLabel: o.count == null ? o.label : '${o.label}, ${o.count}',
      selected: selected,
      minTapSize: kMinTap,
      builder: (context, _) => Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (o.leading != null) ...[o.leading!, const SizedBox(width: _gap)],
            if (icons && o.icon != null) ...[Icon(o.icon, size: 15, color: color), const SizedBox(width: _gap)],
            Flexible(
              child: Text(
                o.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _style.copyWith(color: color),
              ),
            ),
            if (o.count != null) ...[
              const SizedBox(width: 5),
              Text(
                '${o.count}',
                style: _style.copyWith(
                  fontWeight: FontWeight.w500,
                  color: ds.textMuted,
                  fontFeatures: Type.tabular,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Text field with its label above (Linear-style) instead of Material's
/// floating label.
///
/// The field is named for screen readers by [label] (the visible text is
/// excluded from semantics so it is not read twice), and one line below it is
/// always reserved for [helper] / validation text, so an error appearing never
/// shifts the fields underneath.
class LabeledField extends StatelessWidget {
  const LabeledField({
    super.key,
    required this.label,
    this.controller,
    this.hint,
    this.helper,
    this.validator,
    this.obscure = false,
    this.minLines = 1,
    this.maxLines = 1,
    this.suffix,
    this.keyboardType,
    this.textInputAction,
    this.mono = false,
    this.onChanged,
    this.inputFormatters,
    this.enabled = true,
    this.restorationId,
    this.autofocus = false,
    this.onSubmitted,
  });

  final String label;
  final TextEditingController? controller;
  final String? hint;
  final String? helper;
  final FormFieldValidator<String>? validator;
  final bool obscure;
  final int minLines;
  final int maxLines;
  final Widget? suffix;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final bool mono;
  final ValueChanged<String>? onChanged;
  final List<TextInputFormatter>? inputFormatters;
  final bool enabled;

  /// Persist the text across process death (state restoration). Leave null for
  /// secrets: restoration data is not protected storage.
  final String? restorationId;

  /// Takes focus (and the keyboard) as soon as it is shown.
  final bool autofocus;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: ExcludeSemantics(
            child: Text(label, style: Type.label.copyWith(color: ds.textSecondary)),
          ),
        ),
        Semantics(
          label: label,
          child: TextFormField(
            controller: controller,
            restorationId: restorationId,
            autofocus: autofocus,
            onFieldSubmitted: onSubmitted,
            enabled: enabled,
            obscureText: obscure,
            minLines: obscure ? 1 : minLines,
            maxLines: obscure ? 1 : maxLines,
            validator: validator,
            keyboardType: keyboardType,
            textInputAction: textInputAction,
            onChanged: onChanged,
            inputFormatters: inputFormatters,
            autocorrect: false,
            enableSuggestions: false,
            style: (mono
                    ? const TextStyle(fontFamily: monoFamily, fontSize: 13, height: 1.5)
                    : Type.body.copyWith(fontSize: 16))
                .copyWith(color: ds.text),
            cursorColor: ds.accent,
            decoration: InputDecoration(
              hintText: hint,
              suffixIcon: suffix,
              // A blank helper keeps one line reserved for the error text.
              helperText: helper ?? ' ',
              helperMaxLines: 3,
              helperStyle: Type.caption.copyWith(color: ds.textMuted),
            ),
          ),
        ),
      ],
    );
  }
}
