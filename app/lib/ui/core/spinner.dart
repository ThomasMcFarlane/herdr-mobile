import 'dart:async';

import 'package:flutter/material.dart';

import 'motion.dart';
import 'theme.dart';

/// The one indeterminate spinner: a thin round-capped ring, for work the user
/// is waiting on (a button that is saving, a send in flight). It is the only
/// looping animation in the app; keep it short-lived and never use it as
/// decoration.
///
/// It keeps its room from the start but draws nothing for [Dwell.spinnerDelay],
/// so work that finishes fast never flashes it. Under reduced motion it is a
/// still three-quarter ring: busy, without a loop.
class BusySpinner extends StatefulWidget {
  const BusySpinner({super.key, this.size = 14, this.color});

  final double size;
  final Color? color;

  /// The ring's share of the circle under reduced motion.
  static const stillValue = 0.75;

  @override
  State<BusySpinner> createState() => _BusySpinnerState();
}

class _BusySpinnerState extends State<BusySpinner> {
  late final Timer _delay = Timer(Dwell.spinnerDelay, () {
    if (mounted) setState(() => _shown = true);
  });
  bool _shown = false;

  @override
  void initState() {
    super.initState();
    _delay;
  }

  @override
  void dispose() {
    _delay.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: widget.size,
    child: !_shown
        ? null
        : CircularProgressIndicator(
            value: Motion.reduced(context) ? BusySpinner.stillValue : null,
            strokeWidth: 2,
            strokeCap: StrokeCap.round,
            color: widget.color ?? context.ds.textSecondary,
          ),
  );
}
