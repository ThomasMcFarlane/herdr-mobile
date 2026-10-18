import 'package:flutter/material.dart';

import 'press.dart';
import 'chips.dart';
import 'motion.dart';
import 'tokens.dart';
import 'top_bar.dart';

/// Large-title page header (Apple/Notion pattern) as a pinned sliver.
///
/// At rest it shows a big bold title over the page background with no
/// separator. As the list scrolls the big title slides under a compact bar,
/// the compact title fades in, and a hairline appears: a scroll-edge effect
/// instead of a permanent divider. [leading] and [actions] stay put.
///
/// Only the title and subtitle fade. [bottom] (filter chips, a segmented
/// control) slides under the opaque bar at full opacity, and cannot be tapped
/// once it is fully hidden. Both titles are announced as headings.
class SliverLargeTitle extends StatelessWidget {
  const SliverLargeTitle({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.actions = const [],
    this.bottom,
    this.bottomHeight = 0,
  });

  /// A pushed screen's header: [AppBackButton] leads.
  const SliverLargeTitle.back({
    super.key,
    required this.title,
    this.subtitle,
    this.actions = const [],
    this.bottom,
    this.bottomHeight = 0,
  }) : leading = const AppBackButton();

  final String title;

  /// One quiet line under the big title.
  final Widget? subtitle;

  /// The root tabs have none; pushed screens use [SliverLargeTitle.back].
  final Widget? leading;
  final List<Widget> actions;

  /// Scrolls away with the title (filter chips, a segmented control).
  final Widget? bottom;

  /// Height reserved for [bottom]; [AppChip.height] (44) for a chip row.
  final double bottomHeight;

  static const _barHeight = 56.0;
  static const _titleBlock = 50.0;
  static const _subtitleBlock = 22.0;
  static const _gap = 8.0;

  /// Height of the part that scrolls away.
  static double _large(bool hasSubtitle, double bottomHeight) =>
      _titleBlock + (hasSubtitle ? _subtitleBlock : 0) + bottomHeight + _gap;

  /// The pinned header's full (unscrolled) height: where the list content
  /// starts. Use it as the `edgeOffset` of a pull-to-refresh indicator.
  static double extent(
    BuildContext context, {
    bool hasSubtitle = false,
    double bottomHeight = 0,
  }) => MediaQuery.paddingOf(context).top + _barHeight + _large(hasSubtitle, bottomHeight);

  /// The pinned bar's height once the large title has scrolled away: the part
  /// of the screen's top that content scrolled under is hidden by.
  static double collapsedExtent(BuildContext context) => MediaQuery.paddingOf(context).top + _barHeight;

  @override
  Widget build(BuildContext context) => SliverPersistentHeader(
    pinned: true,
    delegate: _LargeTitleDelegate(
      topInset: MediaQuery.paddingOf(context).top,
      title: title,
      subtitle: subtitle,
      leading: leading,
      actions: actions,
      bottom: bottom,
      bottomHeight: bottomHeight,
      ds: context.ds,
      reduced: Motion.reduced(context),
    ),
  );
}

class _LargeTitleDelegate extends SliverPersistentHeaderDelegate {
  _LargeTitleDelegate({
    required this.topInset,
    required this.title,
    required this.subtitle,
    required this.leading,
    required this.actions,
    required this.bottom,
    required this.bottomHeight,
    required this.ds,
    required this.reduced,
  });

  final double topInset;
  final String title;
  final Widget? subtitle;
  final Widget? leading;
  final List<Widget> actions;
  final Widget? bottom;
  final double bottomHeight;
  final Ds ds;
  final bool reduced;

  static const _bar = SliverLargeTitle._barHeight;
  static const _titleBlock = SliverLargeTitle._titleBlock;
  static const _subtitleBlock = SliverLargeTitle._subtitleBlock;

  double get _large => SliverLargeTitle._large(subtitle != null, bottomHeight);

  @override
  double get minExtent => topInset + _bar;

  @override
  double get maxExtent => topInset + _bar + _large;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final t = (shrinkOffset / (_large * 0.55)).clamp(0.0, 1.0);
    final compact = ((t - 0.55) / 0.45).clamp(0.0, 1.0);
    final big = (1 - t * 1.25).clamp(0.0, 1.0);
    final collapsed = shrinkOffset >= _large - 1;

    Widget titles = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: _titleBlock,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Semantics(
              header: true,
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Type.largeTitle.copyWith(color: ds.text),
              ),
            ),
          ),
        ),
        if (subtitle != null) SizedBox(height: _subtitleBlock, child: subtitle),
      ],
    );
    // No layer at rest (opacity 1); the title is simply absent once it is gone.
    if (big < 1) titles = Opacity(opacity: big, child: titles);
    if (big == 0) {
      titles = SizedBox(height: _titleBlock + (subtitle != null ? _subtitleBlock : 0));
    }

    // Bars clamp text scale like iOS navigation bars: their blocks are fixed
    // height, so unbounded system scaling would clip the title.
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: kBarTextScale,
      child: ClipRect(
        child: Container(
          color: ds.bg,
          child: Stack(
            children: [
              // Large title block, anchored under the bar so it slides beneath it.
              Positioned(
                left: Gap.gutter,
                right: Gap.gutter,
                top: topInset + _bar - shrinkOffset.clamp(0.0, _large),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    titles,
                    if (bottom != null)
                      SizedBox(
                        height: bottomHeight + SliverLargeTitle._gap,
                        child: ExcludeSemantics(
                          excluding: collapsed,
                          child: IgnorePointer(
                            ignoring: collapsed,
                            child: Padding(
                              padding: const EdgeInsets.only(top: SliverLargeTitle._gap),
                              child: bottom,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              // Top bar.
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                height: topInset + _bar,
                child: Container(
                  color: ds.bg,
                  padding: EdgeInsets.only(top: topInset),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      if (compact > 0)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 64),
                          child: Semantics(
                            header: true,
                            child: _fade(
                              compact,
                              Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Type.barTitle.copyWith(color: ds.text),
                              ),
                            ),
                          ),
                        ),
                      // Round buttons paint 40 inside a 44 touch box, so the
                      // painted edge still sits 16 from the screen edge.
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: AppTopBar.edge),
                        child: Row(
                          children: [
                            ?leading,
                            const Spacer(),
                            for (final (i, a) in actions.indexed) ...[
                              if (i > 0) const SizedBox(width: 4),
                              a,
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: AnimatedOpacity(
                  opacity: collapsed || overlapsContent ? 1 : 0,
                  duration: reduced ? Duration.zero : Motion.standard,
                  child: ColoredBox(
                    color: ds.hairline,
                    child: SizedBox(
                      height: 1 / MediaQuery.devicePixelRatioOf(context),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static Widget _fade(double opacity, Widget child) =>
      opacity >= 1 ? child : Opacity(opacity: opacity, child: child);

  @override
  bool shouldRebuild(_LargeTitleDelegate old) =>
      old.title != title ||
      old.ds != ds ||
      old.topInset != topInset ||
      old.bottomHeight != bottomHeight ||
      old.leading != leading ||
      old.subtitle != subtitle ||
      old.bottom != bottom ||
      old.actions != actions;
}
