import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/acp/background/background_work.dart' show BackgroundTask;
import '../../../data/acp/session_web.dart';
import '../../../data/models/remote_file.dart';
import '../../../data/models/web_bridge.dart' show sensitiveServiceOf;
import '../../../data/repositories/agent_session.dart';
import '../../../data/repositories/machine_connection.dart' show LinkState;
import '../../../data/repositories/web_preview.dart';
import '../../core/chrome.dart';
import '../../core/controls.dart';
import '../../core/glyphs.dart';
import '../../core/open_link.dart';
import '../../core/rows.dart';
import '../../core/theme.dart';
import '../../core/toast.dart';
import '../files/file_format.dart' show formatModified;
import '../files/files_navigation.dart' show machineSupportsFiles;
import 'session_select.dart';
import 'visible_text.dart';

/// What the sheet and the chip read from a session: the servers and pages, the
/// background tasks that say whether a server still runs, and whether anything
/// here may be called live (a saved copy or a link that is down knows nothing
/// of what runs now).
typedef _Snap = (List<WebAsset>, List<BackgroundTask>, bool);

_Snap _snap(AgentSessionView s) =>
    (webAssetsOf(s.state.items, cwd: s.cwd), s.backgroundWork.tasks, s.link == AgentLink.live && s.cachedAsOf == null);

bool _same(_Snap a, _Snap b) => sameWebAssets(a.$1, b.$1) && identical(a.$2, b.$2) && a.$3 == b.$3;

/// The servers and pages a session put on the web, newest first, one tap from
/// the session bar. Each row opens in the phone's browser: a server through the
/// SSH connection, a page from its folder on the machine.
///
/// [opener] is the screen the sheet was opened from: a browser is only
/// launched while it is still there (a person who tapped a row and pressed
/// Back is not sent to a page over the board seconds later).
Future<void> showSessionWeb(BuildContext opener, AgentSessionView session) =>
    showAppSheet<void>(opener, builder: (ctx) => SessionWebSheet(session: session, opener: opener));

class SessionWebSheet extends StatefulWidget {
  const SessionWebSheet({super.key, required this.session, required this.opener});

  final AgentSessionView session;
  final BuildContext opener;

  @override
  State<SessionWebSheet> createState() => _SessionWebSheetState();
}

class _SessionWebSheetState extends State<SessionWebSheet> {
  /// The rows as the sheet found them, in that order. Nothing moves under a
  /// thumb while the sheet is open (AGENTS.md principle 3): a bottom sheet
  /// grows upward, so a row added anywhere shifts the ones beside it. A link
  /// that arrives meanwhile shows on the chip behind the sheet and in the list
  /// the next time it opens; the rows that are here keep their place and keep
  /// their state (a server stops being Running, a path is updated).
  List<String>? _order;

  List<WebAsset> _stable(List<WebAsset> assets) {
    final order = _order ??= [for (final a in assets) a.key];
    final byKey = {for (final a in assets) a.key: a};
    return [for (final k in order) ?byKey[k]];
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    return SessionSelect<_Snap>(
      session: session,
      select: _snap,
      same: _same,
      builder: (context, snap) {
        final (assets, tasks, live) = snap;
        final shown = _stable(assets);
        final ds = context.ds;
        final files = machineSupportsFiles(session.machine);
        return Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, 8, Gap.lg, Gap.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: Gap.sm, bottom: Gap.sm),
                child: Semantics(
                  header: true,
                  child: Text('Web in this session', style: Type.label.copyWith(color: ds.textSecondary)),
                ),
              ),
              if (shown.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: Gap.xl),
                  child: Text(
                    'No dev server or page has come up in this session yet.',
                    style: Type.secondary.copyWith(color: ds.textSecondary),
                  ),
                ),
              for (final (i, asset) in shown.indexed)
                _WebRow(
                  asset: asset,
                  state: asset.kind == WebKind.server ? serverStateOf(asset, tasks, live: live) : null,
                  filesAvailable: files,
                  divider: i < shown.length - 1,
                  onTap: () => unawaited(openWebAsset(context, widget.opener, session, asset)),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Rows being opened, so a second tap while the connection is made does not
/// start a second open and a second browser tab.
final _opening = <String>{};

/// Closes the sheet, says it is opening, then opens [asset] in the browser;
/// a failure replaces the toast with its reason.
Future<void> openWebAsset(BuildContext sheet, BuildContext opener, AgentSessionView session, WebAsset asset) async {
  final toaster = Toaster.of(sheet);
  final machine = session.machine;
  final service = asset.kind == WebKind.server && asset.port != null ? sensitiveServiceOf(asset.port!) : null;
  if (service != null) {
    // Not a web page: opened only from the link in the chat, where the whole
    // address is on the screen and the tap is the person's own.
    Navigator.of(sheet).pop();
    toaster.show('That is a $service port. Open the link from the chat if you mean to.');
    return;
  }
  final id = '${session.key}\u0000${asset.key}';
  if (!_opening.add(id)) return;
  Navigator.of(sheet).pop();
  void failed(String text) => toaster.show(text, kind: ToastKind.failed);
  toaster.show('Opening ${visibleText(asset.title)}…');
  try {
    final entry = switch (asset.kind) {
      WebKind.server => await machine.web.forwardUrl(
          asset.url!,
          onNote: (note) => toaster.show(note),
        ),
      WebKind.page => await machine.web.staticUrl(
          await machine.files.stat(await machine.files.resolve(asset.path!, cwd: session.cwd)),
        ),
    };
    if (!opener.mounted) return;
    if (!await openPreviewUrl(entry)) failed("Couldn't open on this phone: no browser could open it.");
  } on WebPreviewException catch (e) {
    failed(e.message);
  } on RemoteFileException catch (e) {
    failed(
      e.kind == RemoteFileErrorKind.notFound
          ? '${visibleText(asset.title)} is not on the machine any more.'
          : visibleText(e.message),
    );
  } finally {
    _opening.remove(id);
  }
}

class _WebRow extends StatelessWidget {
  const _WebRow({
    required this.asset,
    required this.state,
    required this.filesAvailable,
    required this.divider,
    required this.onTap,
  });

  final WebAsset asset;

  /// Only for a server.
  final ServerState? state;
  final bool filesAvailable;
  final bool divider;
  final VoidCallback onTap;

  /// What the row says under its name: the state of a server (said only as far
  /// as the phone knows), the folder and time of a page.
  String? get _subtitle {
    final when = formatModified(asset.at);
    final service = asset.kind == WebKind.server && asset.port != null ? sensitiveServiceOf(asset.port!) : null;
    if (service != null) return '$service, not a web page';
    if (asset.kind == WebKind.page && !filesAvailable) return 'Files are not available on this machine';
    final text = switch (state) {
      ServerState.running => 'Running',
      ServerState.stopped => when.isEmpty ? 'Stopped' : 'Stopped · $when',
      ServerState.seen => when.isEmpty ? 'Seen' : 'Seen $when',
      null => [visibleText(asset.where), when].where((s) => s.isNotEmpty).join(' · '),
    };
    return text.isEmpty ? null : text;
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final running = state == ServerState.running;
    final blocked = asset.kind == WebKind.server && asset.port != null && sensitiveServiceOf(asset.port!) != null;
    return ListRow(
      leading: IconTile(
        icon: asset.kind == WebKind.server ? LucideIcons.server : LucideIcons.globe,
        color: running ? ds.done : null,
      ),
      leadingOnTitle: false,
      title: visibleText(asset.title),
      subtitle: _subtitle,
      divider: divider,
      dim: state == ServerState.stopped || blocked || (asset.kind == WebKind.page && !filesAvailable),
      onTap: onTap,
      trailing: running ? const LinkDot(state: LinkState.online) : null,
    );
  }
}

/// `Web 3` beside the subagents chip under the session's title: the number of
/// servers and pages the session has put on the web. Takes no room while there
/// are none.
class WebChip extends StatelessWidget {
  const WebChip({super.key, required this.session});

  final AgentSessionView session;

  @override
  Widget build(BuildContext context) => SessionSelect<(List<WebAsset>, bool)>(
        session: session,
        select: (s) => (webAssetsOf(s.state.items, cwd: s.cwd), s.subagents.isNotEmpty || s.subagentSummary.total > 0),
        same: (a, b) => sameWebAssets(a.$1, b.$1) && a.$2 == b.$2,
        builder: (context, v) {
          final (assets, besideSubagents) = v;
          if (assets.isEmpty) return const SizedBox.shrink();
          return Padding(
            // The bar's row places the chips; this one follows the subagents chip.
            padding: EdgeInsets.only(left: besideSubagents ? Gap.sm : 0, bottom: 2),
            child: AppChip(
              label: 'Web',
              count: assets.length,
              semanticLabel: assets.length == 1 ? '1 page or server' : '${assets.length} pages and servers',
              leading: Icon(LucideIcons.globe, size: 14, color: context.ds.textSecondary),
              onTap: () => unawaited(showSessionWeb(context, session)),
            ),
          );
        },
      );
}
