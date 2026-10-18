import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/models/web_bridge.dart';
import '../../../data/repositories/machine_connection.dart';
import '../../../data/repositories/web_preview.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import '../../support/open_link.dart';

/// What a tapped web link offers: the whole address (selectable, so nothing
/// is hidden behind a shortened label), then open or copy.
///
/// An address on the machine itself (`localhost`, a loopback address, a
/// `.local` name) is not reachable from the phone as it is. A plain `http` one
/// on a known [machine] is opened on the phone through the SSH connection
/// (`Open on phone`); any other only offers copy and says why. A plain `http`
/// link is opened only from here, after being shown.
Future<void> showLinkSheet(BuildContext context, String url, {MachineConnection? machine}) {
  final toaster = Toaster.of(context);
  void toast(String text, {ToastKind kind = ToastKind.info}) => toaster.show(text, kind: kind);

  final local = isMachineLocalUrl(url);
  final host = Uri.tryParse(url)?.host ?? '';
  final plain = url.toLowerCase().startsWith('http://');
  final https = url.toLowerCase().startsWith('https://');
  final previewable = machine != null && local && WebPreview.canPreview(url);

  return showAppSheet<void>(
    context,
    builder: (ctx) {
      final ds = ctx.ds;
      void copy() {
        Navigator.of(ctx).pop();
        copyText(context, url, what: 'Link copied');
      }

      Future<void> open() async {
        Navigator.of(ctx).pop();
        if (!await openTappedLink(url)) toast('Couldn’t open on this phone: no browser could open it.', kind: ToastKind.failed);
      }

      // The sheet goes first: the connection is asked after the screen has
      // answered the tap. A failure says why, and Copy link is one tap away
      // again from the same link.
      Future<void> openOnPhone() async {
        Navigator.of(ctx).pop();
        try {
          final entry = await machine!.web.forwardUrl(Uri.parse(url), onNote: toast);
          if (!await openPreviewUrl(entry)) {
            toast('Couldn’t open on this phone: no browser could open it.', kind: ToastKind.failed);
          }
        } on WebPreviewException catch (e) {
          toast(e.message, kind: ToastKind.failed);
        }
      }

      Widget note(IconData icon, String text) => Padding(
            padding: const EdgeInsets.only(top: Gap.md),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: Gap.hair),
                  child: Icon(icon, size: IconSize.row, color: ds.textSecondary),
                ),
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: Text(text, style: Type.secondary.copyWith(color: ds.textSecondary)),
                ),
              ],
            ),
          );

      return SheetScaffold(
        title: host.isEmpty ? 'Link' : host,
        kind: SheetKind.message,
        actions: [
          if (!local)
            AppButton(
              label: 'Open in browser',
              icon: LucideIcons.externalLink,
              expand: true,
              onPressed: open,
            )
          else if (previewable)
            AppButton(
              label: 'Open on phone',
              icon: LucideIcons.smartphone,
              expand: true,
              onPressed: openOnPhone,
            ),
          AppButton(
            label: 'Copy link',
            icon: LucideIcons.copy,
            kind: local && !previewable ? AppButtonKind.primary : AppButtonKind.secondary,
            expand: true,
            onPressed: copy,
          ),
        ],
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: Gap.xs),
            Panel(
              child: SelectableText(url, style: Mono.input.copyWith(color: ds.text)),
            ),
            if (previewable)
              note(
                LucideIcons.server,
                'This address is on ${machine.profile.label}. Open on phone reaches it over your SSH connection.',
              )
            else if (local && https)
              note(LucideIcons.server, 'HTTPS on the machine can’t be opened on the phone yet.')
            else if (local)
              note(LucideIcons.server, 'This address is on the machine, not your phone.')
            else if (plain)
              note(LucideIcons.triangleAlert, 'This link is not encrypted.'),
          ],
        ),
      );
    },
  );
}
