import 'dart:convert';

import '../models/herdr_models.dart';
import '../models/remote_file.dart';
import '../repositories/fleet_agent.dart';
import '../repositories/machine_connection.dart';
import '../services/herdr_transport.dart' show HerdrApiException;
import '../services/remote_files.dart';
import 'agent_roots.dart';
import 'session_log_locator.dart';

/// Lists the foreground processes of a pane (`pane.process_info`).
typedef PaneProcesses = Future<List<PaneProcess>> Function(String paneId);

/// Finds the log of a Claude Code pane.
///
/// Claude writes `<config dir>/projects/{cwd with every non-alphanumeric character
/// replaced by "-"}/{sessionId}.jsonl` (the file is named by the session id and
/// does not exist until the first message). herdr's hook reports the session id
/// and the transcript path, but only once its integration is installed and the
/// session started or resumed after that. Without it, the running process
/// tells: `<config dir>/sessions/{pid}.json` maps a `claude` pid to its session id.
///
/// The config dir is `~/.claude` unless the process runs with
/// `CLAUDE_CONFIG_DIR` (read from its `/proc/<pid>/environ`). A session known
/// by id alone is looked for in `~/.claude`, then in the folders listed on the
/// machine ([MachineProfile.agentRoots]).
class ClaudeLocator implements SessionLogLocator {
  ClaudeLocator();

  /// Session ids (with the roots looked into) whose project folders were all
  /// looked into without finding the file.
  final _scanned = <String>{};

  /// machine/id -> path, as [CodexLocator] does: a session's file never moves.
  final _found = <String, String>{};

  static const _envVar = 'CLAUDE_CONFIG_DIR';

  /// Shown verbatim.
  static const unlinkedWhy =
      'herdr does not know which session this Claude Code runs. Install herdr\'s hook (the terminal\'s ⋯ menu has '
      '"Read as chat…", or run "herdr integration install claude" on the machine), then resume the session.';

  static const notYetWhy = 'Claude has not written this session yet.';

  static final _sessionId = RegExp(r'^[0-9a-f-]{36}$');
  static final _unsafeInName = RegExp(r'[^A-Za-z0-9]');

  /// The most project folders looked into for a session id.
  static const maxProjects = 200;

  /// The biggest `sessions/<pid>.json` read.
  static const maxPidFile = 64 * 1024;

  @override
  bool mayLocate(Pane pane) => FleetAgent.kindOf(pane) == 'claude';

  @override
  Future<LogLocation> locate(MachineConnection machine, Pane pane) => locateWith(
    machine.files,
    machine.api.paneProcessInfo,
    pane,
    machineId: machine.profile.id,
    extraRoots: machine.profile.agentRoots,
  );

  Future<LogLocation> locateWith(
    RemoteFiles files,
    PaneProcesses processes,
    Pane pane, {
    String machineId = '',
    List<String> extraRoots = const [],
  }) async {
    // The running process is the truth about which session the pane runs: the
    // session herdr reports is the one the hook saw last, and stays after the
    // agent in the pane was exited and started again.
    final byProcess = await _byProcess(files, processes, pane, machineId);
    if (byProcess != null) return byProcess;
    final session = pane.session;
    if (session != null) {
      if (session.kind == 'path' && isReadableLogPath(session.value)) {
        // herdr reports the path when the session starts; the file comes with
        // the first message.
        return await _exists(files, session.value) ? Located(session.value) : const NotYet(notYetWhy);
      }
      if (session.kind == 'id' && _sessionId.hasMatch(session.value)) {
        final home = await files.home();
        final roots = await candidateRoots(files, '$home/.claude', extraRoots);
        return _byId(files, session.value, roots, machineId, cwd: pane.cwd);
      }
    }
    return const Unlinked(unlinkedWhy);
  }

  /// The log of the session the `claude` process in [pane] runs
  /// (`<config dir>/sessions/<pid>.json` names it), or null when that cannot be
  /// told (an old herdr, no such process, no file of its own).
  Future<LogLocation?> _byProcess(RemoteFiles files, PaneProcesses processes, Pane pane, String machineId) async {
    final List<PaneProcess> running;
    try {
      running = await processes(pane.id);
    } on HerdrApiException {
      // An old herdr (unsupported) or one that refuses: the report is all there is.
      return null;
    }
    final home = await files.home();
    for (final p in running) {
      if (!_isClaude(p)) continue;
      // Where this process keeps its files: its own CLAUDE_CONFIG_DIR, else the default.
      final root = await processEnvRoot(files, p.pid, _envVar) ?? '$home/.claude';
      final json = await _readPidFile(files, '$root/sessions/${p.pid}.json');
      // The file must be this process's own: a stale one of a crashed process
      // whose pid was reused names another session.
      if (json == null || json['kind'] != 'interactive' || json['pid'] != p.pid) continue;
      final id = json['sessionId'];
      if (id is! String || !_sessionId.hasMatch(id)) continue;
      final cwd = json['cwd'];
      return _byId(files, id, [root], machineId, cwd: cwd is String ? cwd : pane.cwd);
    }
    return null;
  }

  /// The foreground process is Claude Code itself: its `argv0` (or the first
  /// word of its command line) is `claude`. herdr's `name` is the version string
  /// for it (`2.1.293`), and the foreground list also holds helper processes
  /// (MCP servers) that may have `claude` somewhere in a path.
  static bool _isClaude(PaneProcess p) {
    if (p.pid < 1) return false;
    String base(String? s) => (s ?? '').split('/').where((x) => x.isNotEmpty).lastOrNull ?? '';
    final first = (p.cmdline ?? '').trim().split(RegExp(r'\s+')).first;
    return base(p.argv0) == 'claude' || base(first) == 'claude' || p.name == 'claude';
  }

  Future<Map<String, dynamic>?> _readPidFile(RemoteFiles files, String path) async {
    try {
      final bytes = await files.read(path, length: maxPidFile + 1);
      if (bytes.length > maxPidFile) return null;
      final json = jsonDecode(utf8.decode(bytes, allowMalformed: true));
      return json is Map<String, dynamic> ? json : null;
    } on FormatException {
      return null;
    } on RemoteFileException catch (e) {
      if (_absent(e)) return null;
      rethrow;
    }
  }

  /// The log of session [id]: in the folder its working directory names, else
  /// in whichever project folder holds it (a symlinked or renamed cwd), in each
  /// of the config [roots] in turn.
  Future<LogLocation> _byId(RemoteFiles files, String id, List<String> roots, String machineId, {String? cwd}) async {
    final cached = _found['$machineId/$id'];
    if (cached != null) return Located(cached);
    if (cwd != null && cwd.isNotEmpty) {
      for (final root in roots) {
        final guess = '$root/projects/${cwd.replaceAll(_unsafeInName, '-')}/$id.jsonl';
        if (isReadableLogPath(guess) && await _exists(files, guess)) return _remember(machineId, id, guess);
      }
    }
    // One full look for a session that has no file yet, not one per poll: after
    // it only the folder its working directory names is looked at.
    final scanKey = '$machineId/$id/${roots.join('\n')}';
    if (_scanned.contains(scanKey)) return const NotYet(notYetWhy);
    for (final root in roots) {
      final projects = '$root/projects';
      final List<RemoteEntry> dirs;
      try {
        dirs =
            [
              for (final e in await files.list(projects))
                if (e.isDirectory) e,
            ]..sort(
              (a, b) => (b.modified ?? DateTime.fromMillisecondsSinceEpoch(0)).compareTo(
                a.modified ?? DateTime.fromMillisecondsSinceEpoch(0),
              ),
            );
      } on RemoteFileException catch (e) {
        if (_absent(e)) continue;
        rethrow;
      }
      for (final dir in dirs.take(maxProjects)) {
        final path = '$projects/${dir.name}/$id.jsonl';
        if (isReadableLogPath(path) && await _exists(files, path)) return _remember(machineId, id, path);
      }
    }
    _scanned.add(scanKey);
    return const NotYet(notYetWhy);
  }

  LogLocation _remember(String machineId, String id, String path) {
    _found['$machineId/$id'] = path;
    return Located(path);
  }

  Future<bool> _exists(RemoteFiles files, String path) async {
    try {
      final stat = await files.stat(path);
      return stat.kind == RemoteEntryKind.file;
    } on RemoteFileException catch (e) {
      if (_absent(e)) return false;
      rethrow;
    }
  }

  /// A file or folder that is not there (or not for this user to read) is an
  /// answer; a dropped link is not.
  static bool _absent(RemoteFileException e) => switch (e.kind) {
    RemoteFileErrorKind.notFound ||
    RemoteFileErrorKind.permission ||
    RemoteFileErrorKind.notAFile ||
    RemoteFileErrorKind.notADirectory => true,
    _ => false,
  };
}
