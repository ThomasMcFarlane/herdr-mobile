import 'package:flutter/material.dart';

import 'theme.dart';

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
