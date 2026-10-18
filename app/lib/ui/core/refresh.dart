import 'dart:async';

import 'package:flutter/material.dart';

import 'tokens.dart';

/// Pull-to-refresh in the app's style: no disc, just a thin 2 px ring over the
/// page background. Give [edgeOffset] the pinned header's height
/// (`SliverLargeTitle.extent(context, ...)`) so the ring appears below it, not
/// on top of the first row.
class AppRefresh extends StatelessWidget {
  const AppRefresh({
    super.key,
    required this.onRefresh,
    required this.edgeOffset,
    required this.child,
    this.notificationPredicate = defaultScrollNotificationPredicate,
  });

  final Future<void> Function() onRefresh;
  final double edgeOffset;
  final Widget child;

  /// Which scrollables pull it down. The default is the one right below it; a
  /// list inside a sideways scroll view needs `(n) => n.metrics.axis ==
  /// Axis.vertical`.
  final ScrollNotificationPredicate notificationPredicate;

  @override
  Widget build(BuildContext context) => RefreshIndicator(
    onRefresh: onRefresh,
    edgeOffset: edgeOffset,
    notificationPredicate: notificationPredicate,
    color: context.ds.textSecondary,
    backgroundColor: Colors.transparent,
    elevation: 0,
    strokeWidth: 2,
    child: child,
  );
}
