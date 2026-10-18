import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'tokens.dart';

/// Where a page shown in herdr comes from, as a browser shows it: a globe,
/// the page's [address] and, after a dot, [where] it is served from (the
/// machine), in one quiet pill. It sits in a top bar's `bottom`, under the
/// title, so the screen reads as a web page and not as one of herdr's own.
///
/// [address] is left out (null) when the title already says it, so the
/// address is said once. [foreign]: the page shown is not from [where] (a
/// form a page posted to another site); the pill then shows the real host
/// (or, when the title is that host, only the warning) with a warning mark
/// and `not from <where>` in the warning tone, so content from elsewhere
/// never sits under the machine's name.
///
/// Not a button: the address is the page's, and Copy link lives in the
/// screen's `⋯`.
class AddressPill extends StatelessWidget {
  const AddressPill({super.key, required this.address, required this.where, this.foreign = false});

  final String? address;
  final String where;
  final bool foreign;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final quiet = Type.caption.copyWith(color: ds.textSecondary);
    final address = this.address;
    return Padding(
      padding: const EdgeInsets.only(top: Gap.xs),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: foreign ? ds.blockedWash : ds.fill,
            borderRadius: BorderRadius.circular(Radii.pill),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: Gap.xs),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  foreign ? LucideIcons.triangleAlert : LucideIcons.globe,
                  size: IconSize.inline,
                  color: foreign ? ds.blockedText : ds.textSecondary,
                ),
                const SizedBox(width: Gap.xs),
                Flexible(
                  child: Text.rich(
                    TextSpan(children: [
                      if (address != null) TextSpan(text: address, style: Type.caption.copyWith(color: ds.text)),
                      if (address != null) const TextSpan(text: ' · '),
                      if (foreign)
                        TextSpan(text: 'not from $where', style: Type.captionStrong.copyWith(color: ds.blockedText))
                      else
                        TextSpan(text: where),
                    ]),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: quiet,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
