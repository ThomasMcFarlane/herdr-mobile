import 'package:flutter/widgets.dart';

import 'spinner.dart';
import 'theme.dart';

/// Work the person is waiting on, said in a line: the spinner and what is
/// loading (`Loading earlier messages…`). Announced once as it appears.
///
/// [padding] defaults to the page gutter; [center] puts the line in the
/// middle of a wide space (a list's foot, a bar); [maxLines] cuts it with an
/// ellipsis where its height is fixed (a bar).
class LoadingRow extends StatelessWidget {
  const LoadingRow(
    this.label, {
    super.key,
    this.padding = const EdgeInsets.symmetric(horizontal: Gap.gutter, vertical: Gap.md),
    this.center = false,
    this.maxLines,
  });

  final String label;
  final EdgeInsetsGeometry padding;
  final bool center;
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Semantics(
      liveRegion: true,
      label: label,
      excludeSemantics: true,
      child: Padding(
        padding: padding,
        child: Row(
          mainAxisAlignment: center ? MainAxisAlignment.center : MainAxisAlignment.start,
          children: [
            const BusySpinner(),
            const SizedBox(width: Gap.sm),
            Flexible(
              child: Text(
                label,
                maxLines: maxLines,
                overflow: maxLines == null ? null : TextOverflow.ellipsis,
                style: Type.secondary.copyWith(color: ds.textMuted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
