import 'dart:async';

import 'package:flutter/material.dart';

import 'count_badge.dart';
import 'press.dart';
import 'motion.dart';
import 'toast.dart' show ToastShelf;
import 'tokens.dart';

class TabSpec {
  const TabSpec({
    required this.icon,
    required this.label,
    this.badge = 0,
    this.badgeLabel = 'need you',
    this.mark = false,
    this.markLabel = '',
  });

  final IconData icon;
  final String label;

  /// Count shown as a small dot with number; 0 hides it.
  final int badge;

  /// What the count means, for screen readers: "Agents, 2 need you".
  final String badgeLabel;

  /// A small plain dot, in the accent: something here is worth a look, and
  /// nothing needs the person (the count [badge] is the loud one). Not drawn
  /// next to a count. [markLabel] is its meaning for screen readers.
  final bool mark;
  final String markLabel;
}

/// The floating pill at the bottom of a root screen: the tab bar, and the
/// batch actions that take its place while the board picks. One slot, one
/// look, so the bottom never changes shape when the board starts picking.
///
/// Slim on purpose: 56 dp tall, at most [maxWidth] wide and centred, so it
/// sits in the thumb's reach without spreading edge to edge over the board it
/// serves (the first tab bar was 64 dp and the full width, and read as big).
abstract final class FloatingBar {
  static const height = 56.0;
  static const pad = 4.0;
  static const cell = height - pad * 2;
  static const margin = 8.0;
  static const side = 12.0;
  static const maxWidth = 312.0;

  /// Space a scrolling list keeps free at its bottom.
  static double clearance(BuildContext context) => height + margin * 2 + MediaQuery.paddingOf(context).bottom;
}

/// Where a [FloatingBarPill] stands: [FloatingBar.margin] above the system
/// inset, [FloatingBar.side] from the edges, centred, at most
/// [FloatingBar.maxWidth] wide. Text stops growing at [kBarTextScale].
class FloatingBarSlot extends StatelessWidget {
  const FloatingBarSlot({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final inset = MediaQuery.paddingOf(context);
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: kBarTextScale,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          inset.left + FloatingBar.side,
          0,
          inset.right + FloatingBar.side,
          inset.bottom + FloatingBar.margin,
        ),
        child: Align(
          alignment: Alignment.bottomCenter,
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: FloatingBar.maxWidth),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// The pill itself: the surface, a hairline and the one float shadow
/// ([Ds.floatShadow]), no backdrop blur (a full-screen blur pass per frame on
/// mid-range GPUs). [child] is one row of [FloatingBar.cell] height.
class FloatingBarPill extends StatelessWidget {
  const FloatingBarPill({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: ds.surface,
        borderRadius: BorderRadius.circular(FloatingBar.height / 2),
        border: Border.all(color: ds.hairline),
        boxShadow: ds.floatShadow,
      ),
      child: Padding(
        padding: const EdgeInsets.all(FloatingBar.pad),
        child: SizedBox(height: FloatingBar.cell, child: child),
      ),
    );
  }
}

/// Rows fade out into the page just above the floating bar and are gone
/// behind it and the system navigation: the scrim is solid under the pill and
/// the gesture inset, so no text shows beside or below the pill. It is
/// [FloatingBar.clearance] tall and ends where the triage chip begins: the
/// scrim is drawn above the board, and a taller one dimmed the chip, the one
/// loud shortcut, from its bottom edge up.
class FloatingBarScrim extends StatelessWidget {
  const FloatingBarScrim({super.key});

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [ds.bg.withValues(alpha: 0), ds.bg, ds.bg],
            stops: const [0, 0.5, 1],
          ),
        ),
      ),
    );
  }
}

/// Floating pill tab bar ([FloatingBarPill] in a [FloatingBarSlot]): three
/// equal cells, an icon over a name in each, the selected one on a soft
/// capsule. Content scrolls under it, so lists must reserve
/// [FloatingBar.clearance] at the bottom. Its shadow is the app's one float
/// shadow. A render shows it only with `debugDisableShadows` off (the test
/// binding turns blur off and paints a hard offset band).
///
/// Every tab is named and every cell is the same width, so nothing moves when a
/// tab is chosen (a second tap from memory lands where the first did) and a
/// count badge, which rides the icon's corner, never meets a label. Three
/// cells fit a 320 dp phone: the text is clamped at [kBarTextScale], and a
/// cell holds "Machines" at that. Every tab keeps its full name for screen
/// readers, and [tabKey] finds one by label in tests.
///
/// One number, the capsule's place in tab units, drives the capsule and every
/// cell's colour, so the text warms as the capsule arrives under it and cools
/// as it leaves, in step. Two clocks (a position curve and a separate linear
/// colour tween) drifted apart, and the label weight, which cannot be
/// interpolated, snapped on its own: it no longer changes.
class FloatingTabBar extends StatefulWidget {
  const FloatingTabBar({
    super.key,
    required this.tabs,
    required this.index,
    required this.onChanged,
  });

  final List<TabSpec> tabs;
  final int index;
  final ValueChanged<int> onChanged;

  /// Key of the tab labelled [label], for tests and callers.
  static Key tabKey(String label) => ValueKey('tab:$label');

  /// Key of the selection capsule, for tests.
  static const capsuleKey = ValueKey('tab:capsule');

  @override
  State<FloatingTabBar> createState() => _FloatingTabBarState();
}

class _FloatingTabBarState extends State<FloatingTabBar> with SingleTickerProviderStateMixin {
  // The capsule's place in tab units (0 is the first cell). It stops when it
  // arrives; nothing runs at rest.
  late final AnimationController _place = AnimationController.unbounded(
    vsync: this,
    value: widget.index.toDouble(),
  );

  final _cellsKey = GlobalKey();

  // A finger holds the capsule: it follows 1:1 and the glide stays out of the way.
  bool _scrubbing = false;
  int _over = 0;

  /// Seconds of the flick's speed that carry on after the finger lifts, to
  /// choose the tab the capsule would have coasted to (Apple's projection).
  static const _momentum = 0.1;

  @override
  void didUpdateWidget(FloatingTabBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index == widget.index || _scrubbing) return;
    _glideTo(widget.index);
  }

  // From where it is now, never from the old tab: a second tap mid-glide
  // carries on from the live place. Under reduced motion it is there at once.
  void _glideTo(int i) {
    if (Motion.reduced(context)) {
      _place.value = i.toDouble();
    } else {
      unawaited(_place.animateTo(i.toDouble(), duration: Motion.standard, curve: Motion.easeOut));
    }
  }

  double get _cellWidth => (_cellsKey.currentContext?.size?.width ?? 0) / widget.tabs.length;

  void _scrubStart(DragStartDetails _) {
    _scrubbing = true;
    _place.stop();
    _over = _place.value.round();
  }

  void _scrubUpdate(DragUpdateDetails d) {
    final cell = _cellWidth;
    if (cell <= 0) return;
    final last = widget.tabs.length - 1;
    // The capsule lives inside the pill: it stops at the first and last cell.
    final next = (_place.value + d.delta.dx / cell).clamp(0.0, last.toDouble());
    _place.value = next;
    final over = next.round().clamp(0, last);
    if (over != _over) {
      _over = over;
      Haptics.tick();
    }
  }

  // Chosen where a flick would have stopped, so a quick flick is enough.
  void _scrubEnd(double velocity) {
    if (!_scrubbing) return;
    _scrubbing = false;
    final cell = _cellWidth;
    final last = widget.tabs.length - 1;
    final projected = _place.value + (cell > 0 ? velocity * _momentum / cell : 0);
    final target = projected.round().clamp(0, last);
    if (target != widget.index) {
      widget.onChanged(target);
      // The caller owns the selection: if it did not take it, the capsule goes back.
      WidgetsBinding.instance
        ..addPostFrameCallback((_) {
          if (mounted && !_scrubbing && widget.index != target) _glideTo(widget.index);
        })
        ..ensureVisualUpdate();
    } else {
      _glideTo(widget.index);
    }
  }

  @override
  void dispose() {
    _place.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      ToastShelf(lift: FloatingBar.clearance(context), child: _bar(context));

  Widget _bar(BuildContext context) {
    final ds = context.ds;
    final n = widget.tabs.length;
    return FloatingBarSlot(
      child: GestureDetector(
        // The capsule is an object in the hand: drag it along the bar and
        // it follows the finger; the tab changes where it is let go. A tap
        // on a cell does the same without it. Around the pill, so a drag
        // that starts on its rim still carries the capsule.
        onHorizontalDragStart: _scrubStart,
        onHorizontalDragUpdate: _scrubUpdate,
        onHorizontalDragEnd: (d) => _scrubEnd(d.velocity.pixelsPerSecond.dx),
        onHorizontalDragCancel: () => _scrubEnd(0),
        child: FloatingBarPill(
          child: SizedBox(
            key: _cellsKey,
            child: AnimatedBuilder(
              animation: _place,
              builder: (context, _) {
                final at = _place.value;
                return Stack(
                  children: [
                    // One capsule under the cells that travels from where
                    // it was to where it is, so the eye follows it; the
                    // cells themselves never move. [ds.fill] on the pill's
                    // surface was about 1.1:1 and vanished in dark.
                    Align(
                      alignment: Alignment(n < 2 ? 0 : -1 + 2 * at / (n - 1), 0),
                      child: FractionallySizedBox(
                        key: FloatingTabBar.capsuleKey,
                        widthFactor: 1 / n,
                        heightFactor: 1,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: ds.fillPressed,
                            borderRadius: BorderRadius.circular(FloatingBar.cell / 2),
                          ),
                        ),
                      ),
                    ),
                    Row(
                      children: [
                        for (final (i, tab) in widget.tabs.indexed)
                          Expanded(
                            child: _TabItem(
                              key: FloatingTabBar.tabKey(tab.label),
                              tab: tab,
                              selected: i == widget.index,
                              // 1 with the capsule centred under this cell, 0 a cell away.
                              near: (1 - (at - i).abs()).clamp(0.0, 1.0).toDouble(),
                              onTap: () => widget.onChanged(i),
                            ),
                          ),
                      ],
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _TabItem extends StatelessWidget {
  const _TabItem({
    super.key,
    required this.tab,
    required this.selected,
    required this.near,
    required this.onTap,
  });

  final TabSpec tab;
  final bool selected;
  final double near;
  final VoidCallback onTap;

  static const _icon = 22.0;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final badge = tab.badge;
    return PressBuilder(
      onTap: onTap,
      haptic: !selected,
      selected: selected,
      semanticLabel: badge > 0
          ? '${tab.label}, $badge ${tab.badgeLabel}'
          : tab.mark
              ? '${tab.label}, ${tab.markLabel}'
              : tab.label,
      builder: (context, pressed) => SizedBox(
        height: FloatingBar.cell,
        // The press warms the text at once; the capsule's place does the rest.
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: pressed ? 1 : 0),
          duration: Motion.pressing(pressed),
          curve: Motion.easeOut,
          builder: (context, press, _) {
            final color = Color.lerp(ds.textSecondary, ds.text, near > press ? near : press);
            return Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Icon(tab.icon, size: _icon, color: color),
                    if (badge > 0)
                      Positioned(
                        left: _icon - 8,
                        top: -7,
                        // The ring is the bar's surface: the badge reads as
                        // cut out of the icon.
                        child: CountBadge(count: badge, ring: ds.surface),
                      )
                    else if (tab.mark)
                      Positioned(
                        left: _icon - 5,
                        top: -3,
                        child: Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: ds.accent,
                            shape: BoxShape.circle,
                            border: Border.all(color: ds.surface, width: 1.5),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  tab.label,
                  maxLines: 1,
                  softWrap: false,
                  style: Type.label.copyWith(color: color, fontWeight: FontWeight.w500),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
