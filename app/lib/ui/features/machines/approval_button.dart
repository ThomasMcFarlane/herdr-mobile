import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:herdr_mobile/ui/core/kit.dart';
import '../../support/open_link.dart';

/// "Open sign-in page": sends the person to the link a machine's login banner
/// asked them to approve (Tailscale SSH check mode). The connection is waiting
/// and continues on its own once it is approved.
///
/// Sits on a tinted panel, so it is the quiet secondary kind: the panel
/// already carries the urgency.
class ApprovalButton extends StatelessWidget {
  const ApprovalButton({super.key, required this.url});

  final String url;

  @override
  Widget build(BuildContext context) => AppButton(
        label: 'Open sign-in page',
        icon: LucideIcons.externalLink,
        kind: AppButtonKind.secondary,
        compact: true,
        onPressed: () async {
          final toaster = Toaster.of(context);
          if (!await openInBrowser(url)) {
            toaster.show('Couldn’t open on this phone: no browser could open it.', kind: ToastKind.failed);
          }
        },
      );
}
