import 'package:flutter/widgets.dart';

import 'press.dart';
import 'roll_text.dart';
import 'theme.dart';

enum CountTone {
  /// How many need the person: the blocked fill.
  blocked,

  /// A plain tally: the quiet fill.
  neutral,

  /// What the person picked and will send (pictures on the paperclip).
  accent,
}

/// A small round count (`3`, `99+`): on a tab icon, a machine row, a
/// paperclip. 16 high, at least as wide, and the number rolls when it
/// changes ([RollText]). [ring] draws a 1.5 dp halo outside the pill in the
/// colour of what is underneath, so a badge over an icon reads as cut out.
///
/// The number is drawn, not announced: the owner's label says it in words
/// (`Agents, 2 need you`).
class CountBadge extends StatelessWidget {
  const CountBadge({super.key, required this.count, this.tone = CountTone.blocked, this.ring});

  final int count;
  final CountTone tone;
  final Color? ring;

  static const height = 16.0;
  static const ringWidth = 1.5;

  /// Past this the badge says `99+`.
  static const cap = 99;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final (fill, fg) = switch (tone) {
      // The deeper status-text orange: white on the paper shape colour is
      // 4.2:1, under the 4.5 an 11 pt number needs; on ink they are one colour.
      CountTone.blocked => (ds.blockedText, ds.onStatus),
      CountTone.neutral => (ds.fill, ds.textMuted),
      CountTone.accent => (ds.accent, ds.onAccent),
    };
    final ring = this.ring;
    return ExcludeSemantics(
      child: Container(
        height: height,
        constraints: const BoxConstraints(minWidth: height),
        padding: const EdgeInsets.symmetric(horizontal: Gap.xs),
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(Radii.pill),
          border: ring == null
              ? null
              : Border.all(color: ring, width: ringWidth, strokeAlign: BorderSide.strokeAlignOutside),
        ),
        // A fixed-height pill: the number grows with the text only as far as
        // the bars do. Centred at its own width: an `alignment` on the box
        // made the pill fill any loose width it was given (a Wrap, a row).
        child: Center(
          widthFactor: 1,
          child: MediaQuery.withClampedTextScaling(
            maxScaleFactor: kBarTextScale,
            child: RollText(
              text: count > cap ? '$cap+' : '$count',
              style: Type.badge.copyWith(color: fg),
              overflow: TextOverflow.visible,
            ),
          ),
        ),
      ),
    );
  }
}
