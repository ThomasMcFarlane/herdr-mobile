import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

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
///
/// The bottom stack is lanes, from the bottom edge up, each present only while
/// it has content: the inset; the Dock ([height]: the tab bar, or the batch bar
/// while the board picks); the Pin ([pin]: the triage pill); the toast. Every
/// gap is [margin]. One motion for every lane ([BottomStackTransition]).
abstract final class FloatingBar {
  static const height = 56.0;
  static const pad = 4.0;
  static const cell = height - pad * 2;
  static const margin = 8.0;
  static const side = 12.0;
  static const maxWidth = 312.0;

  /// The Pin lane: a pill over the Dock (the triage pill).
  static const pin = 44.0;

  /// How much the pill grows while a finger carries the tab capsule: it is
  /// an object in the hand (Telegram lifts its bar the same way, 1.019).
  static const liftScale = 1.02;

  /// From the bottom edge to the top of the Dock and its margin: where the
  /// next lane (or a toast) stands.
  static double clearance(BuildContext context) => height + margin * 2 + MediaQuery.paddingOf(context).bottom;

  /// Where a toast stands while the Pin shows.
  static double pinLift(BuildContext context) => clearance(context) + pin + margin;

  /// The space a scrolling list keeps free at its end, so its last row can be
  /// read above the lanes: the Dock, and the Pin while it shows.
  static double listEnd(BuildContext context, {bool pin = false}) =>
      clearance(context) + margin + (pin ? FloatingBar.pin + margin : 0);
}

/// Where a [FloatingBarPill] stands: [FloatingBar.margin] above the system
/// inset, [FloatingBar.side] from the edges, centred, at most
/// [FloatingBar.maxWidth] wide. Text stops growing at [kBarTextScale].
///
/// A lane that stands on another lane (not on the screen's bottom edge) sets
/// [aboveInset] false: then only the margin is below it.
class FloatingBarSlot extends StatelessWidget {
  const FloatingBarSlot({super.key, required this.child, this.aboveInset = true});

  final Widget child;
  final bool aboveInset;

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
          (aboveInset ? inset.bottom : 0) + FloatingBar.margin,
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
        borderRadius: BorderRadius.circular(Radii.pill),
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
///
/// The fading top half lets taps through to the rows that still show in it;
/// the solid half takes them, so nothing hidden beside the pill is tapped by
/// accident.
class FloatingBarScrim extends StatelessWidget {
  const FloatingBarScrim({super.key});

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Column(
      children: [
        Expanded(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Ds.fade(ds.bg, 0), ds.bg],
                ),
              ),
            ),
          ),
        ),
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            excludeFromSemantics: true,
            onTap: () {},
            child: ColoredBox(color: ds.bg),
          ),
        ),
      ],
    );
  }
}

/// How a lane of the bottom stack comes and goes: up from [Motion.travel]
/// with a fade, [Motion.sheetIn]; the reverse, [Motion.sheetOut]. With
/// [slide] false it only fades over [Motion.fade]: the Dock swapping between
/// the tab bar and the batch bar in its own place. Reduced motion fades.
///
/// At rest it is the lane itself (no opacity layer), or nothing while hidden:
/// [builder] runs only while the lane shows, so a hidden lane listens to
/// nothing.
class BottomStackTransition extends StatefulWidget {
  const BottomStackTransition({super.key, required this.visible, required this.builder, this.slide = true});

  final bool visible;
  final bool slide;
  final WidgetBuilder builder;

  @override
  State<BottomStackTransition> createState() => _BottomStackTransitionState();
}

class _BottomStackTransitionState extends State<BottomStackTransition> with SingleTickerProviderStateMixin {
  late final AnimationController _shown = AnimationController(vsync: this, value: widget.visible ? 1 : 0);
  late final Animation<double> _curve = Motion.curved(_shown);

  @override
  void didUpdateWidget(BottomStackTransition old) {
    super.didUpdateWidget(old);
    if (old.visible == widget.visible) return;
    final fadeOnly = !widget.slide || Motion.reduced(context);
    _shown
      ..duration = fadeOnly ? Motion.fade : Motion.sheetIn
      ..reverseDuration = fadeOnly ? Motion.fade : Motion.sheetOut;
    if (widget.visible) {
      unawaited(_shown.forward());
    } else {
      unawaited(_shown.reverse());
    }
  }

  @override
  void dispose() {
    _shown.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _curve,
        builder: (context, _) {
          final t = _curve.value;
          if (t <= 0) return const SizedBox.shrink();
          final child = widget.builder(context);
          if (t >= 1) return child;
          final slide = widget.slide && !Motion.reduced(context);
          return IgnorePointer(
            child: Opacity(
              opacity: t,
              child: slide ? Transform.translate(offset: Offset(0, (1 - t) * Motion.travel), child: child) : child,
            ),
          );
        },
      );
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

  /// Where a released capsule is springing to: the selection that follows it
  /// must not restart it as a timed glide.
  int? _springTo;

  @override
  void didUpdateWidget(FloatingTabBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index == widget.index || _scrubbing) return;
    if (widget.index == _springTo && _place.isAnimating) return;
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
    setState(() => _scrubbing = true);
    _springTo = null;
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

  // Chosen where a flick would have stopped, so a quick flick is enough. The
  // capsule lands there on a spring that starts at the finger's speed: the
  // drag and the landing are one movement.
  void _scrubEnd(double velocity) {
    if (!_scrubbing) return;
    setState(() => _scrubbing = false);
    final cell = _cellWidth;
    final last = widget.tabs.length - 1;
    final projected = _place.value + (cell > 0 ? velocity * Springs.projectTab / cell : 0);
    final target = projected.round().clamp(0, last);
    if (Motion.reduced(context) || cell <= 0) {
      _place.value = target.toDouble();
    } else {
      _springTo = target;
      unawaited(_place.animateWith(
        SpringSimulation(Springs.snap, _place.value, target.toDouble(), velocity / cell, tolerance: Springs.scale),
      ));
    }
    if (target != widget.index) {
      widget.onChanged(target);
      // The caller owns the selection: if it did not take it, the capsule goes back.
      WidgetsBinding.instance
        ..addPostFrameCallback((_) {
          if (mounted && !_scrubbing && widget.index != target) {
            _springTo = null;
            _glideTo(widget.index);
          }
        })
        ..ensureVisualUpdate();
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
        child: AnimatedScale(
          // Picked up: the pill lifts a little while the capsule is carried.
          scale: _scrubbing && !Motion.reduced(context) ? FloatingBar.liftScale : 1,
          duration: Motion.settle,
          curve: Motion.easeOut,
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
                    // cells themselves never move. A tint of the accent: the
                    // hue says "selected", so the capsule can stay faint
                    // (grey on grey said it too quietly).
                    Align(
                      alignment: Alignment(n < 2 ? 0 : -1 + 2 * at / (n - 1), 0),
                      child: FractionallySizedBox(
                        key: FloatingTabBar.capsuleKey,
                        widthFactor: 1 / n,
                        heightFactor: 1,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: ds.accentWash,
                            borderRadius: BorderRadius.circular(Radii.pill),
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

  /// The update dot on Settings: a quiet mark, never a count.
  static const _dot = 10.0;

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
        // The press warms the cell at once; the capsule's place does the rest.
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: pressed ? 1 : 0),
          duration: Motion.pressing(pressed),
          curve: Motion.easeOut,
          builder: (context, press, _) {
            final t = near > press ? near : press;
            // Hue carries the selection: secondary ink to accent text, in
            // step with the capsule arriving under the cell.
            final color = Color.lerp(ds.textSecondary, ds.accentText, t)!;
            // The ring around a badge is whatever is under it: the pill's
            // surface, or the capsule as it arrives.
            final under = Color.lerp(ds.surface, Color.alphaBlend(ds.accentWash, ds.surface), near)!;
            return Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Icon(tab.icon, size: IconSize.nav, color: color),
                    // On the icon's corner, clear of the label.
                    Positioned(
                      left: IconSize.nav - Gap.sm - Gap.hair + 1,
                      top: -Gap.hair,
                      child: _Badge(count: badge, ring: under),
                    ),
                    if (badge == 0 && tab.mark)
                      Positioned(
                        left: IconSize.nav - Gap.xs - Gap.hair,
                        top: -Gap.hair,
                        child: Container(
                          width: _dot,
                          height: _dot,
                          decoration: BoxDecoration(
                            color: ds.accent,
                            shape: BoxShape.circle,
                            border: Border.all(color: under, width: 1.5),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: Gap.hair),
                Text(
                  tab.label,
                  maxLines: 1,
                  softWrap: false,
                  style: Type.caption.copyWith(color: color),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The tab's count: it arrives and leaves with a scale over [Motion.settle] /
/// [Motion.standard] (keeping the last number while it leaves), and its
/// number rolls when it changes ([CountBadge]). Nothing under reduced motion.
class _Badge extends StatefulWidget {
  const _Badge({required this.count, required this.ring});

  final int count;
  final Color ring;

  @override
  State<_Badge> createState() => _BadgeState();
}

class _BadgeState extends State<_Badge> {
  late int _shown = widget.count;

  @override
  void didUpdateWidget(_Badge old) {
    super.didUpdateWidget(old);
    if (widget.count > 0) _shown = widget.count;
  }

  @override
  Widget build(BuildContext context) {
    final on = widget.count > 0;
    if (_shown == 0) return const SizedBox.shrink();
    // From nothing the first time it is built, then from wherever it is.
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: on ? 1 : 0),
      duration: Motion.of(context, on ? Motion.settle : Motion.standard),
      curve: Motion.easeOut,
      onEnd: () {
        if (!on && mounted) setState(() => _shown = 0);
      },
      child: CountBadge(count: _shown, ring: widget.ring),
      builder: (context, t, child) => t >= 1 ? child! : Transform.scale(scale: t, child: child),
    );
  }
}
