import '../models/herdr_models.dart';
import '../models/remote_file.dart';
import '../repositories/fleet_agent.dart';
import '../repositories/machine_connection.dart';
import '../services/herdr_transport.dart' show HerdrApiException;
import '../services/remote_files.dart';
import 'agent_roots.dart';
import 'claude_locator.dart' show PaneProcesses;
import 'session_log_locator.dart';

/// Finds the log of a Codex pane.
///
/// Codex writes `<codex home>/sessions/YYYY/MM/DD/rollout-<local time>-<id>.jsonl`
/// when the first prompt is sent; the date folder and the name's stamp are the
/// HOST's local time at creation, and `<id>` is a UUIDv7 whose first 48 bits are
/// the creation time in milliseconds UTC. herdr's hook reports the thread id
/// only (not the path), and only once its integration is installed and the
/// session started or resumed after that. Without a session reference the pane
/// cannot be linked: Codex keeps no map from a process to its thread.
///
/// The codex home is `~/.codex` unless the process runs with `CODEX_HOME`
/// (read from its `/proc/<pid>/environ`). Without a codex process to ask, the
/// default and then the folders listed on the machine
/// ([MachineProfile.agentRoots]) are tried; a home that held a session is
/// tried first next time (a subagent's thread has no pane of its own).
class CodexLocator implements SessionLogLocator {
  CodexLocator();

  /// Shown verbatim.
  static const unlinkedWhy =
      'herdr does not know which session this Codex runs. Install herdr\'s hook (the terminal\'s ⋯ menu has '
      '"Read as chat…", or run "herdr integration install codex" on the machine; Codex asks you to trust it), then run "codex resume".';

  static const compressedWhy = 'Codex compressed this session after a week idle. Resume it in Codex to read it here.';

  static const notYetWhy = 'Codex has not written this session yet.';

  static final _uuid = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');

  /// The most directory listings made looking for a session by walking the
  /// date folders newest first.
  static const maxLists = 40;

  /// id -> path, per machine: a session's file never moves.
  final _found = <String, String>{};

  /// machine -> the home the last session was found in.
  final _homeHint = <String, String>{};

  static const _envVar = 'CODEX_HOME';

  @override
  bool mayLocate(Pane pane) => pane.session != null && FleetAgent.kindOf(pane) == 'codex';

  @override
  Future<LogLocation> locate(MachineConnection machine, Pane pane) => locateWith(
    machine.files,
    pane,
    machineId: machine.profile.id,
    processes: machine.api.paneProcessInfo,
    extraRoots: machine.profile.agentRoots,
  );

  Future<LogLocation> locateWith(
    RemoteFiles files,
    Pane pane, {
    String machineId = '',
    PaneProcesses? processes,
    List<String> extraRoots = const [],
  }) async {
    final session = pane.session;
    if (session == null) return const Unlinked(unlinkedWhy);
    if (session.kind == 'path' && isReadableLogPath(session.value)) return Located(session.value);
    if (session.kind == 'id') {
      return locateById(
        files,
        session.value,
        machineId: machineId,
        extraRoots: extraRoots,
        codexHome: processes == null ? null : await _homeOfProcess(files, processes, pane),
      );
    }
    return const Unlinked(unlinkedWhy);
  }

  /// The `CODEX_HOME` of the codex process in [pane], or null when there is
  /// none, it sets none, or herdr cannot list processes.
  Future<String?> _homeOfProcess(RemoteFiles files, PaneProcesses processes, Pane pane) async {
    final List<PaneProcess> running;
    try {
      running = await processes(pane.id);
    } on HerdrApiException {
      return null;
    }
    for (final p in running) {
      if (!_isCodex(p)) continue;
      final home = await processEnvRoot(files, p.pid, _envVar);
      if (home != null) return home;
    }
    return null;
  }

  /// Codex itself (a launcher script or the native binary): its `argv0`, the
  /// first word of its command line or its name is `codex`.
  static bool _isCodex(PaneProcess p) {
    if (p.pid < 1) return false;
    String base(String? s) => (s ?? '').split('/').where((x) => x.isNotEmpty).lastOrNull ?? '';
    final first = (p.cmdline ?? '').trim().split(RegExp(r'\s+')).first;
    return base(p.argv0) == 'codex' || base(first) == 'codex' || p.name == 'codex';
  }

  /// The log of thread [id] (a main session's or a subagent's). It is looked
  /// for in [codexHome] when the process says it, else in `~/.codex` and
  /// [extraRoots].
  Future<LogLocation> locateById(
    RemoteFiles files,
    String id, {
    String machineId = '',
    String? codexHome,
    List<String> extraRoots = const [],
  }) async {
    if (!_uuid.hasMatch(id)) return const NotYet(notYetWhy);
    final cached = _found['$machineId/$id'];
    if (cached != null) return Located(cached);
    final List<String> homes;
    if (codexHome != null) {
      homes = [codexHome];
    } else {
      final home = await files.home();
      homes = await candidateRoots(files, '$home/.codex', extraRoots);
      final hint = _homeHint[machineId];
      if (hint != null && homes.remove(hint)) homes.insert(0, hint);
    }
    var compressed = false;
    for (final codexRoot in homes) {
      final found = await _inRoot(files, id, '$codexRoot/sessions');
      compressed |= found.compressed;
      final path = found.path;
      if (path != null && isReadableLogPath(path)) {
        _found['$machineId/$id'] = path;
        _homeHint[machineId] = codexRoot;
        return Located(path);
      }
    }
    return compressed ? const Unlinked(compressedWhy) : const NotYet(notYetWhy);
  }

  Future<({String? path, bool compressed})> _inRoot(RemoteFiles files, String id, String root) async {
    var compressed = false;

    Future<String?> inDay(String dir) async {
      final entries = await _list(files, dir);
      if (entries == null) return null;
      for (final e in entries) {
        if (!e.name.startsWith('rollout-')) continue;
        if (e.name.endsWith('-$id.jsonl')) return '$dir/${e.name}';
        if (e.name.endsWith('-$id.jsonl.zst')) compressed = true;
      }
      return null;
    }

    String? path;
    if (id[14] == '7') {
      final ms = int.parse(id.replaceAll('-', '').substring(0, 12), radix: 16);
      final made = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
      for (final shift in const [-1, 0, 1]) {
        final d = made.add(Duration(days: shift));
        path = await inDay('$root/${_pad(d.year, 4)}/${_pad(d.month)}/${_pad(d.day)}');
        if (path != null) break;
      }
    }
    // A v7 id says its day; only an id that does not is looked for by walking.
    if (id[14] != '7') path ??= await _walk(files, root, inDay);
    return (path: path, compressed: compressed);
  }

  /// Date folders newest first, at most [maxLists] listings in all.
  Future<String?> _walk(RemoteFiles files, String root, Future<String?> Function(String dir) inDay) async {
    var lists = 1;
    final years = await _numbered(files, root);
    for (final y in years) {
      if (lists >= maxLists) return null;
      lists++;
      final months = await _numbered(files, '$root/$y');
      for (final m in months) {
        if (lists >= maxLists) return null;
        lists++;
        final days = await _numbered(files, '$root/$y/$m');
        for (final d in days) {
          if (lists >= maxLists) return null;
          lists++;
          final found = await inDay('$root/$y/$m/$d');
          if (found != null) return found;
        }
      }
    }
    return null;
  }

  /// The all-digit folder names of [dir], biggest first.
  Future<List<String>> _numbered(RemoteFiles files, String dir) async {
    final entries = await _list(files, dir);
    final names = [
      for (final e in entries ?? const <RemoteEntry>[])
        if (e.isDirectory && RegExp(r'^\d{1,4}$').hasMatch(e.name)) e.name,
    ]..sort((a, b) => b.compareTo(a));
    return names;
  }

  Future<List<RemoteEntry>?> _list(RemoteFiles files, String dir) async {
    try {
      return await files.list(dir);
    } on RemoteFileException catch (e) {
      return switch (e.kind) {
        RemoteFileErrorKind.notFound || RemoteFileErrorKind.permission || RemoteFileErrorKind.notADirectory => null,
        _ => throw e,
      };
    }
  }

  static String _pad(int n, [int width = 2]) => n.toString().padLeft(width, '0');
}
