import 'package:flutter/material.dart';

import '../../../data/words/plural.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

/// Removed lines as text: the theme's danger text tone.
Color removedText(Ds ds) => ds.dangerText;

/// `+3 −1`: lines added and removed, in the done and danger text tones. A side
/// that is zero is left out. Read aloud as words, not as signs.
class DiffStats extends StatelessWidget {
  const DiffStats({super.key, required this.added, required this.removed, this.style});

  final int added;
  final int removed;
  final TextStyle? style;

  /// The words a screen reader says.
  static String words(int added, int removed) => [
    if (added > 0) '${countOf(added, 'line')} added',
    if (removed > 0) '${countOf(removed, 'line')} removed',
  ].join(', ');

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final base = (style ?? Type.captionStrong).copyWith(fontFeatures: Type.tabular);
    return Semantics(
      label: words(added, removed),
      excludeSemantics: true,
      // Never wider than 40% of the screen: past that it shrinks to fit
      // instead of pushing the line it belongs to out of its row.
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.4),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerRight,
          child: Text.rich(
            TextSpan(
              children: [
                if (added > 0)
                  TextSpan(
                    text: '+$added',
                    style: base.copyWith(color: ds.addedText),
                  ),
                if (added > 0 && removed > 0) const TextSpan(text: ' '),
                if (removed > 0)
                  TextSpan(
                    text: '\u2212$removed',
                    style: base.copyWith(color: removedText(ds)),
                  ),
              ],
            ),
            maxLines: 1,
            softWrap: false,
          ),
        ),
      ),
    );
  }
}
