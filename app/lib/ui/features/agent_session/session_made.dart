import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/acp/background/background_work.dart' show BackgroundTask;
import '../../../data/acp/session_made.dart';
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
import '../files/files_navigation.dart' show machineSupportsFiles, openRemoteFile;
import '../files/photo_files.dart' show photoRoute;
import '../files/photo_grid.dart' show PhotoThumbFace;
import '../files/photo_thumbs.dart' show PhotoThumbs;
import 'session_select.dart';
import 'visible_text.dart';

/// What the sheet and the chip read from a session: the servers and pages, the
/// background tasks that say whether a server still runs, and whether anything
/// here may be called live (a saved copy or a link that is down knows nothing
/// of what runs now).
typedef _Snap = (List<MadeAsset>, List<BackgroundTask>, bool);

_Snap _snap(AgentSessionView s) =>
    (madeAssetsOf(s.state.items, cwd: s.cwd), s.backgroundWork.tasks, s.link == AgentLink.live && s.cachedAsOf == null);

bool _same(_Snap a, _Snap b) => sameMadeAssets(a.$1, b.$1) && identical(a.$2, b.$2) && a.$3 == b.$3;

/// The servers and pages a session put on the web, newest first, one tap from
/// the session bar. Each row opens in the phone's browser: a server through the
/// SSH connection, a page from its folder on the machine.
///
/// [opener] is the screen the sheet was opened from: a browser is only
/// launched while it is still there (a person who tapped a row and pressed
/// Back is not sent to a page over the board seconds later).
Future<void> showSessionMade(BuildContext opener, AgentSessionView session) =>
    showAppSheet<void>(opener, builder: (ctx) => SessionMadeSheet(session: session, opener: opener));

/// The tab each session was last left on, so the sheet opens where the person
/// was. Only the choice is kept (not what was on the tab): a kind that is no
/// longer there falls back to the newest one.
final _lastTab = <String, MadeKind>{};

/// The kinds that get a tab, in the order they are laid out.
const _tabKinds = [MadeKind.server, MadeKind.page, MadeKind.picture, MadeKind.doc];

/// Rows a list shows before `N more`, and tiles a grid does: what is BUILT, not
/// what is found.
const _listStep = 60;
const _gridStep = 24;

class SessionMadeSheet extends StatefulWidget {
  const SessionMadeSheet({super.key, required this.session, required this.opener});

  final AgentSessionView session;
  final BuildContext opener;

  @override
  State<SessionMadeSheet> createState() => _SessionMadeSheetState();
}

class _SessionMadeSheetState extends State<SessionMadeSheet> {
  /// The rows as the sheet found them, in that order, across every kind and
  /// tab. Nothing moves under a thumb while the sheet is open (AGENTS.md
  /// principle 3): a bottom sheet grows upward, so a row added anywhere shifts
  /// the ones beside it. A link that arrives meanwhile shows on the chip
  /// behind the sheet and in the list the next time it opens; the rows that
  /// are here keep their place and keep their state (a server stops being
  /// Running, a path is updated). Switching tabs only shows another part of
  /// this one order.
  List<String>? _order;

  /// The tab the person chose in this sheet, or the one they left last time.
  late MadeKind? _picked = _lastTab[widget.session.key];

  /// How many times `N more` was tapped, per list.
  final _more = <MadeKind, int>{};

  late final _entries = _EntryLoader(widget.session);

  List<MadeAsset> _stable(List<MadeAsset> assets) {
    final order = _order ??= [for (final a in assets) a.key];
    final byKey = {for (final a in assets) a.key: a};
    return [for (final k in order) ?byKey[k]];
  }

  void _pick(MadeKind kind) {
    _lastTab[widget.session.key] = kind;
    setState(() => _picked = kind);
  }

  void _showMore(MadeKind kind) => setState(() => _more[kind] = (_more[kind] ?? 0) + 1);

  /// How many of [kind]'s items are built.
  int _limit(MadeKind kind) => (kind == MadeKind.picture ? _gridStep : _listStep) * (1 + (_more[kind] ?? 0));

  void _open(MadeAsset asset) => unawaited(openMadeAsset(context, widget.opener, widget.session, asset));

  /// [items] of one kind as rows: the first [_limit] of them and a `N more`
  /// row when there are others. [lastDivider] draws the hairline under the
  /// last row (something follows it).
  List<Widget> _rows(
    List<MadeAsset> items,
    MadeKind bucket, {
    required bool lastDivider,
    required List<BackgroundTask> tasks,
    required bool live,
    required bool files,
  }) {
    final limit = _limit(bucket);
    final built = items.length > limit ? items.sublist(0, limit) : items;
    final rest = items.length - built.length;
    return [
      for (final (i, asset) in built.indexed)
        _WebRow(
          asset: asset,
          state: asset.kind == MadeKind.server ? serverStateOf(asset, tasks, live: live) : null,
          filesAvailable: files,
          divider: i < built.length - 1 || rest > 0 || lastDivider,
          onTap: () => _open(asset),
        ),
      if (rest > 0) _MoreRow(count: rest, onTap: () => _showMore(bucket)),
    ];
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
        final kinds = [for (final k in _tabKinds) if (shown.any((a) => a.kind == k)) k];
        // The kind the person chose if it is still here, else the newest made
        // (servers only when nothing else exists).
        final newest = shown.where((a) => a.kind != MadeKind.server).firstOrNull?.kind ?? MadeKind.server;
        final tab = kinds.isEmpty ? null : (_picked != null && kinds.contains(_picked) ? _picked! : newest);
        final tabbed = kinds.length >= 2;
        final content = [for (final a in shown) if (a.kind == tab) a];
        final running = shown.any((a) => a.kind == MadeKind.server && serverStateOf(a, tasks, live: live) == ServerState.running);
        return Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, 8, Gap.lg, Gap.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: Gap.sm, bottom: Gap.sm),
                child: Semantics(
                  header: true,
                  child: Text('Made in this session', style: Type.label.copyWith(color: ds.textSecondary)),
                ),
              ),
              if (shown.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: Gap.xl),
                  child: Text(
                    'Nothing has come up in this session yet.',
                    style: Type.secondary.copyWith(color: ds.textSecondary),
                  ),
                ),
              if (tabbed)
                _KindTabs(
                  tabs: [
                    for (final k in kinds)
                      (k, _tabLabel(k), shown.where((a) => a.kind == k).length, k == MadeKind.server && running),
                  ],
                  selected: tab!,
                  onChanged: _pick,
                ),
              if (tab == MadeKind.picture)
                _PictureGrid(
                  assets: content,
                  limit: _limit(MadeKind.picture),
                  files: files,
                  loader: _entries,
                  onOpen: _open,
                  onMore: () => _showMore(MadeKind.picture),
                )
              else if (tab != null)
                ..._rows(content, tab, lastDivider: false, tasks: tasks, live: live, files: files),
            ],
          ),
        );
      },
    );
  }
}

String _tabLabel(MadeKind kind) => switch (kind) {
      MadeKind.page => 'Pages',
      MadeKind.picture => 'Pictures',
      MadeKind.doc => 'Docs',
      MadeKind.server => 'Servers',
    };

/// The switch between what was made: the app's one `Segmented`, a cell per kind
/// with its count, a live dot on Servers while one runs. The sheet only says
/// which kinds there are and which one is open; this is the one place that
/// decides how it looks.
class _KindTabs extends StatelessWidget {
  const _KindTabs({required this.tabs, required this.selected, required this.onChanged});

  /// Kind, label, count, and whether something of this kind is running now.
  final List<(MadeKind, String, int, bool)> tabs;
  final MadeKind selected;
  final ValueChanged<MadeKind> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
        // The title row already leaves Gap.sm above.
        padding: const EdgeInsets.only(bottom: Gap.xs),
        child: Segmented<MadeKind>(
          options: [
            for (final (kind, label, count, running) in tabs)
              SegmentOption(kind, label, count: count, leading: running ? const LinkDot(state: LinkState.online) : null),
          ],
          value: selected,
          onChanged: onChanged,
        ),
      );
}

/// `12 more`: shows the next batch of a list.
class _MoreRow extends StatelessWidget {
  const _MoreRow({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListRow(
        leading: const IconTile(icon: LucideIcons.chevronDown),
        leadingOnTitle: false,
        title: '$count more',
        divider: false,
        onTap: onTap,
      );
}

/// Rows being opened, so a second tap while the connection is made does not
/// start a second open and a second browser tab.
final _opening = <String>{};

/// Closes the sheet, then opens [asset]: a server or page in the phone's
/// browser (saying it is opening; a failure replaces the toast with its
/// reason), a picture in the photo viewer and a document in the file viewer.
Future<void> openMadeAsset(BuildContext sheet, BuildContext opener, AgentSessionView session, MadeAsset asset) async {
  final toaster = Toaster.of(sheet);
  final navigator = Navigator.of(opener);
  final machine = session.machine;
  final service = asset.kind == MadeKind.server && asset.port != null ? sensitiveServiceOf(asset.port!) : null;
  if (service != null) {
    // Not a web page: opened only from the link in the chat, where the whole
    // address is on the screen and the tap is the person's own.
    Navigator.of(sheet).pop();
    toaster.show('That is a $service port. Open the link from the chat if you mean to.');
    return;
  }
  void failed(String text) => toaster.show(text, kind: ToastKind.failed);
  if (asset.kind != MadeKind.server && !machineSupportsFiles(machine)) {
    Navigator.of(sheet).pop();
    failed('Files are not available on this machine.');
    return;
  }
  final id = '${session.key}\u0000${asset.key}';
  if (!_opening.add(id)) return;
  Navigator.of(sheet).pop();
  try {
    switch (asset.kind) {
      case MadeKind.doc:
        // The screen goes up at once and finds the file inside (it says what
        // went wrong itself).
        if (opener.mounted) unawaited(openRemoteFile(opener, machine, asset.path!, cwd: session.cwd));
      case MadeKind.picture:
        toaster.show('Opening ${visibleText(asset.title)}…');
        final stat = await machine.files.stat(await machine.files.resolve(asset.path!, cwd: session.cwd));
        if (!opener.mounted) return;
        unawaited(navigator.push(photoRoute<void>(machine, stat, listSiblings: false)));
      case MadeKind.server || MadeKind.page:
        toaster.show('Opening ${visibleText(asset.title)}…');
        final entry = asset.kind == MadeKind.server
            ? await machine.web.forwardUrl(asset.url!, onNote: (note) => toaster.show(note))
            : await machine.web.staticUrl(
                await machine.files.stat(await machine.files.resolve(asset.path!, cwd: session.cwd)),
              );
        if (!opener.mounted) return;
        if (!await openPreviewUrl(entry)) failed("Couldn't open on this phone: no browser could open it.");
    }
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

  final MadeAsset asset;

  /// Only for a server.
  final ServerState? state;
  final bool filesAvailable;
  final bool divider;
  final VoidCallback onTap;

  bool get _isFile => asset.kind != MadeKind.server;

  /// What the row says under its name: the state of a server (said only as far
  /// as the phone knows), the folder and time of a file.
  String? get _subtitle {
    final when = formatModified(asset.at);
    final service = asset.kind == MadeKind.server && asset.port != null ? sensitiveServiceOf(asset.port!) : null;
    if (service != null) return '$service, not a web page';
    if (_isFile && !filesAvailable) return 'Files are not available on this machine';
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
    final blocked = asset.kind == MadeKind.server && asset.port != null && sensitiveServiceOf(asset.port!) != null;
    final unavailable = _isFile && !filesAvailable;
    return ListRow(
      leading: IconTile(
        icon: switch (asset.kind) {
          MadeKind.server => LucideIcons.server,
          MadeKind.page => LucideIcons.globe,
          MadeKind.picture => LucideIcons.image,
          MadeKind.doc => LucideIcons.fileText,
        },
        color: running ? ds.done : null,
      ),
      leadingOnTitle: false,
      title: visibleText(asset.title),
      subtitle: _subtitle,
      divider: divider,
      dim: state == ServerState.stopped || blocked || unavailable,
      onTap: unavailable ? null : onTap,
      trailing: running ? const LinkDot(state: LinkState.online) : null,
    );
  }
}

/// The stat of a made picture, once per picture and sheet, a few at a time.
/// A tile asks only when it is built, so a picture nobody sees costs nothing;
/// its thumbnail is then read by [PhotoThumbs] (three at a time, dropped when
/// the tile goes).
class _EntryLoader {
  _EntryLoader(this._session);

  final AgentSessionView _session;
  final _byKey = <String, Future<RemoteEntry?>>{};
  final _waiting = Queue<Completer<void>>();
  var _running = 0;

  static const _parallel = 4;

  /// The listing entry of [asset]'s file, or null when it cannot be read (gone,
  /// refused, not a file): its tile stays quiet.
  Future<RemoteEntry?> of(MadeAsset asset) => _byKey[asset.key] ??= _load(asset);

  Future<void> _turn() {
    if (_running < _parallel) {
      _running++;
      return Future.value();
    }
    final turn = Completer<void>();
    _waiting.add(turn);
    return turn.future;
  }

  void _next() {
    if (_waiting.isEmpty) {
      _running--;
    } else {
      _waiting.removeFirst().complete();
    }
  }

  Future<RemoteEntry?> _load(MadeAsset asset) async {
    await _turn();
    try {
      final files = _session.machine.files;
      final stat = await files.stat(await files.resolve(asset.path!, cwd: _session.cwd));
      if (!stat.isFile) return null;
      return RemoteEntry(
        name: stat.name,
        path: stat.path,
        kind: RemoteEntryKind.file,
        resolvedKind: RemoteEntryKind.file,
        size: stat.size,
        modified: stat.modified,
      );
    } on Object {
      return null;
    } finally {
      _next();
    }
  }
}

/// The pictures as a grid, three across: a 4:3 thumbnail and the file name
/// under it. Built as rows of three, so only the first [limit] tiles exist.
class _PictureGrid extends StatelessWidget {
  const _PictureGrid({
    required this.assets,
    required this.limit,
    required this.files,
    required this.loader,
    required this.onOpen,
    required this.onMore,
  });

  final List<MadeAsset> assets;
  final int limit;
  final bool files;
  final _EntryLoader loader;
  final ValueChanged<MadeAsset> onOpen;
  final VoidCallback onMore;

  static const _columns = 3;
  static const _gap = 8.0;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final built = assets.length > limit ? assets.sublist(0, limit) : assets;
    final rest = assets.length - built.length;
    final cells = <Widget>[
      for (final a in built)
        _PictureTile(key: ValueKey(a.key), asset: a, loader: loader, enabled: files, onTap: () => onOpen(a)),
      if (rest > 0) _MoreTile(count: rest, onTap: onMore),
    ];
    Widget grid = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var start = 0; start < cells.length; start += _columns)
          Padding(
            padding: EdgeInsets.only(top: start == 0 ? 0 : Gap.md),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < _columns; i++) ...[
                  if (i > 0) const SizedBox(width: _gap),
                  Expanded(child: start + i < cells.length ? cells[start + i] : const SizedBox.shrink()),
                ],
              ],
            ),
          ),
      ],
    );
    // Unavailable stays, dimmed, and says why once instead of under every tile.
    if (!files) grid = Opacity(opacity: 0.55, child: grid);
    return Padding(
      padding: const EdgeInsets.only(top: Gap.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!files)
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.md),
              child: Text(
                'Files are not available on this machine',
                style: Type.secondary.copyWith(color: ds.textSecondary),
              ),
            ),
          grid,
        ],
      ),
    );
  }
}

/// One picture: the thumbnail when it can be had, a quiet tile with a picture
/// glyph until then and when the file is gone or unreadable.
class _PictureTile extends StatefulWidget {
  const _PictureTile({super.key, required this.asset, required this.loader, required this.enabled, required this.onTap});

  final MadeAsset asset;
  final _EntryLoader loader;
  final bool enabled;
  final VoidCallback onTap;

  @override
  State<_PictureTile> createState() => _PictureTileState();
}

class _PictureTileState extends State<_PictureTile> {
  RemoteEntry? _entry;
  var _gone = false;

  @override
  void initState() {
    super.initState();
    // Nothing is asked of a machine that cannot answer.
    if (widget.enabled) {
      unawaited(
        widget.loader.of(widget.asset).then((entry) {
          if (!mounted) return;
          setState(() {
            _entry = entry;
            _gone = entry == null;
          });
        }),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final entry = _entry;
    final name = visibleText(widget.asset.title);
    return PressBuilder(
      onTap: widget.enabled ? widget.onTap : null,
      haptic: true,
      semanticLabel: name,
      builder: (context, pressed) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AspectRatio(
            aspectRatio: 4 / 3,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(Radii.control),
              child: entry == null
                  ? _QuietTile(icon: _gone ? LucideIcons.imageOff : LucideIcons.image, faint: !_gone, pressed: pressed)
                  : PhotoThumbFace(files: widget.loader._session.machine.files, entry: entry, thumbs: PhotoThumbs.shared, pressed: pressed),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: Gap.xs),
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Type.caption.copyWith(color: ds.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

/// A tile with only a glyph on the quiet fill.
class _QuietTile extends StatelessWidget {
  const _QuietTile({required this.icon, this.faint = false, this.pressed = false, this.text});

  final IconData icon;
  final bool faint;
  final bool pressed;
  final String? text;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(
          color: ds.fill,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 24, color: faint ? ds.textTertiary.withValues(alpha: 0.6) : ds.textMuted),
                if (text != null) ...[
                  const SizedBox(height: Gap.xs),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(text!, maxLines: 1, style: Type.caption.copyWith(color: ds.textSecondary)),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (pressed) ColoredBox(color: ds.text.withValues(alpha: 0.12)),
      ],
    );
  }
}

/// `12 more` in the grid: the next batch of tiles.
class _MoreTile extends StatelessWidget {
  const _MoreTile({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => PressBuilder(
        onTap: onTap,
        haptic: true,
        builder: (context, pressed) => AspectRatio(
          aspectRatio: 4 / 3,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(Radii.control),
            child: _QuietTile(icon: LucideIcons.chevronDown, pressed: pressed, text: '$count more'),
          ),
        ),
      );
}

/// `Made 3` beside the subagents chip under the session's title: the number of
/// servers, pages, pictures and documents the session has made. Takes no room
/// while there are none.
class MadeChip extends StatelessWidget {
  const MadeChip({super.key, required this.session});

  final AgentSessionView session;

  @override
  Widget build(BuildContext context) => SessionSelect<(List<MadeAsset>, bool)>(
        session: session,
        select: (s) => (madeAssetsOf(s.state.items, cwd: s.cwd), s.subagents.isNotEmpty || s.subagentSummary.total > 0),
        same: (a, b) => sameMadeAssets(a.$1, b.$1) && a.$2 == b.$2,
        builder: (context, v) {
          final (assets, besideSubagents) = v;
          if (assets.isEmpty) return const SizedBox.shrink();
          return Padding(
            // The bar's row places the chips; this one follows the subagents chip.
            padding: EdgeInsets.only(left: besideSubagents ? Gap.sm : 0, bottom: 2),
            child: AppChip(
              label: 'Made',
              count: assets.length,
              semanticLabel: assets.length == 1 ? '1 item made' : '${assets.length} items made',
              leading: Icon(LucideIcons.globe, size: 14, color: context.ds.textSecondary),
              onTap: () => unawaited(showSessionMade(context, session)),
            ),
          );
        },
      );
}
