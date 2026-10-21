import '../models/made_files.dart';
import '../models/remote_file.dart';
import '../models/web_bridge.dart' show isPreviewHost;
import 'acp_models.dart';
import 'background/background_work.dart' show BackgroundStatus, BackgroundTask;
import 'session_state.dart';
import 'turns/tool_summary.dart' show commandOf, outputTextOf;
import 'turns/turns.dart' show pathOfCall;

/// What a session made for the person to look at: a dev server on the machine,
/// an HTML or SVG page, a picture, a document (`made_files.dart`). Found in the
/// transcript, so it is not lost when the chat scrolls: a link an agent printed
/// an hour ago is here.
///
/// What counts is deliberately narrow. Run over 6,000 recorded sessions, a
/// scanner that took every `localhost` URL and every `.html` name from commands
/// and their output was right for about 6% of its rows: it listed the Milvus a
/// `curl` probed, the pages a `curl -o` downloaded, the files a `grep` named.
/// So a row needs the agent to have MADE or ANNOUNCED the thing:
/// - a page: a completed edit, a file a command writes (`>`, `tee`, `-o`,
///   `cp`/`mv` target, `open`), a "Saved to ..." line a tool printed, or a path
///   in the agent's own words;
/// - a picture or a document: the same, except that a document must be a NEW
///   file (not an edit of a README) and that naming one in words needs a word of
///   making right before it ("saved screenshots/a.png"), because the chat names
///   existing files all day;
/// - a server: a link in the agent's own words, or a banner line a launched
///   command printed (`Local: http://localhost:5173/`).
enum MadeKind { server, page, picture, doc }

/// A server's state as far as the phone can tell. [seen] is the honest default:
/// a link in the output says the server existed, not that it still runs.
enum ServerState { running, stopped, seen }

/// One server or page, with the last place the transcript mentioned it.
class MadeAsset {
  const MadeAsset({
    required this.kind,
    required this.key,
    required this.title,
    required this.where,
    this.url,
    this.path,
    this.at,
    required this.order,
  });

  final MadeKind kind;

  /// One row per key: the server's `localhost:5173`, a page's absolute path.
  final String key;

  /// What the row says: `localhost:5173/docs`, `report.html`. Raw text from the
  /// agent: the screen shows it through `visibleText`.
  final String title;

  /// A page's folder (`reports/`); empty for a server and for the top folder.
  final String where;

  /// The server's link, cleaned: `http`, a machine-local host, a valid port, no
  /// credentials.
  final Uri? url;

  /// The page's absolute path, or `~/...` when the home folder is not known
  /// here (the file layer expands it).
  final String? path;

  /// When the last mention arrived; null when the transcript has no times.
  final DateTime? at;

  /// Position of the last mention in the transcript: bigger is newer.
  final int order;

  /// The port, for matching a background task.
  int? get port => url == null ? null : (url!.hasPort ? url!.port : 80);
}

/// The most rows of each kind a session shows (servers, pages, pictures, docs
/// each keep their newest this many): a transcript can mention hundreds of
/// ports or screenshots, and a flood of one kind must not push another out.
const madeAssetsCap = 150;

/// Whether [a] and [b] show the same rows. A tool call that streams replaces
/// the transcript list on every chunk and with it the list this returns; the
/// screens rebuild on a change of what they SHOW, not of the list.
bool sameMadeAssets(List<MadeAsset> a, List<MadeAsset> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    final x = a[i], y = b[i];
    if (x.key != y.key || x.title != y.title || x.where != y.where || x.at != y.at || x.url != y.url) return false;
  }
  return true;
}

/// The servers and pages of [items], newest mention first, one row each.
/// Memoized by list identity and [cwd] (the folder a relative path is taken
/// against; empty counts as unknown), and the scan of each item by the item.
List<MadeAsset> madeAssetsOf(List<TranscriptItem> items, {String? cwd}) {
  final base = cwd == null || cwd.isEmpty ? null : cwd;
  final byCwd = _lists[items] ??= {};
  return byCwd[base] ??= _build(items, base);
}

/// A server's state against the session's background tasks: running while a
/// task that names its port is running, stopped when only ended ones do, else
/// just seen. [live] is false for a saved copy or a link that is not up: then
/// nothing here is known to run.
ServerState serverStateOf(MadeAsset server, Iterable<BackgroundTask> tasks, {bool live = true}) {
  final port = server.port;
  if (port == null || !live) return ServerState.seen;
  final pattern = RegExp('(?<!\\d)$port(?!\\d)');
  var named = false;
  for (final t in tasks) {
    if (!pattern.hasMatch(t.title) && !(t.detail != null && pattern.hasMatch(t.detail!))) continue;
    if (t.status == BackgroundStatus.running) return ServerState.running;
    named = true;
  }
  return named ? ServerState.stopped : ServerState.seen;
}

final _lists = Expando<Map<String?, List<MadeAsset>>>('session made list');
final _mentions = Expando<List<_Mention>>('session made mentions');
final _commandScans = Expando<List<_Mention>>('session made command');

enum _Act { server, file, drop }

/// One thing a transcript item said. [cd] is a `cd` the command made first.
class _Mention {
  const _Mention.server(this.url, this.at) : act = _Act.server, path = null, cwd = null, cd = null;
  const _Mention.file(this.path, this.cwd, this.cd, this.at) : act = _Act.file, url = null;
  const _Mention.drop(this.path, this.cwd, this.cd, this.at) : act = _Act.drop, url = null;

  final _Act act;
  final Uri? url;
  final String? path;
  final String? cwd;
  final String? cd;
  final DateTime? at;
}

List<MadeAsset> _build(List<TranscriptItem> items, String? sessionCwd) {
  final byKey = <String, MadeAsset>{};
  for (final (index, item) in items.indexed) {
    var seq = 0;
    for (final m in _mentionsOf(item)) {
      // Items are 1000 apart, the mentions of one item in the order scanned.
      final order = index * 1000 + seq++;
      switch (m.act) {
        case _Act.server:
          final asset = _serverOf(m.url!, m.at, order);
          // The command named a path and its own output only the server: the path stays.
          final prev = byKey[asset.key];
          if (prev != null && prev.order ~/ 1000 == index && prev.url?.path != '/' && asset.url?.path == '/') break;
          byKey[asset.key] = asset;
        case _Act.file:
          final asset = _fileOf(m, sessionCwd, order);
          if (asset != null) byKey[asset.key] = asset;
        case _Act.drop:
          final key = _placed(m, sessionCwd);
          if (key != null) byKey.remove(key);
      }
    }
  }
  final out = byKey.values.toList()..sort((a, b) => b.order.compareTo(a.order));
  // Newest first, so the first `madeAssetsCap` met of a kind are its newest.
  final seen = <MadeKind, int>{};
  final kept = [
    for (final a in out)
      if ((seen[a.kind] = (seen[a.kind] ?? 0) + 1) <= madeAssetsCap) a,
  ];
  return List.unmodifiable(kept);
}

List<_Mention> _mentionsOf(TranscriptItem item) {
  // A message that is still streaming grows under the same object and the
  // item list is not replaced by a chunk: it is read once it has settled.
  if (item is TranscriptMessage && item.live != null) return const [];
  return _mentions[item] ??= _scan(item);
}

/// Per item, at most this many mentions: one message cannot bury the rest.
const _perItem = 40;

List<_Mention> _scan(TranscriptItem item) {
  final out = <_Mention>[];
  switch (item) {
    case TranscriptMessage(role: MessageRole.agent, :final text, :final at):
      _say(text.length > _textCap ? text.substring(0, _textCap) : text, at, out);
    case TranscriptTool(:final call, :final at):
      final done = call.status == ToolStatus.completed;
      // A command that did not run (denied, failed, cancelled, still waiting)
      // wrote and removed nothing. Only a server banner is read before the end:
      // a server never finishes, and its address is printed while it runs.
      final printing = done || call.status == ToolStatus.inProgress;
      // Paths a delete diff of this call removes: the edit below must not list them again.
      final deleted = <String>{};
      for (final c in call.content) {
        if (c is ToolDiff && done) {
          // A page counts whenever it was written; a document only when the
          // agent CREATED it (an edit of a README is not something it made). A
          // patch that leaves nothing behind (Codex deletes a file this way: old
          // text, no new text) is a removal, and an empty "new" file is not a document.
          final kind = _kindOf(c.path);
          final p = kind == null ? null : _cleanPath(c.path);
          if (p == null) continue;
          if (c.newText.isEmpty && c.oldText != null) {
            out.add(_Mention.drop(p, call.cwd, null, at));
            deleted.add(p);
          } else if (kind == MadeFileKind.page || kind == MadeFileKind.doc && c.oldText == null && c.newText.isNotEmpty) {
            out.add(_Mention.file(p, call.cwd, null, at));
          }
        }
      }
      if (done && (call.kind == ToolKind.edit || call.kind == ToolKind.delete)) {
        final p = pathOfCall(call);
        final kind = p == null ? null : _kindOf(p);
        if (p != null && kind != null) {
          final clean = _cleanPath(p);
          if (clean != null) {
            if (call.kind == ToolKind.delete) {
              out.add(_Mention.drop(clean, call.cwd, null, at));
            } else if (kind == MadeFileKind.page && !deleted.contains(clean)) {
              out.add(_Mention.file(clean, call.cwd, null, at));
            }
          }
        }
      }
      if (call.kind == ToolKind.execute) {
        final command = commandOf(call);
        if (command != null) {
          if (done) {
            // The patches of a streaming call replace the call but keep its input.
            final key = call.rawInput;
            final scanned = key is Map ? (_commandScans[key] ??= _scanCommand(command, call.cwd)) : _scanCommand(command, call.cwd);
            out.addAll(scanned.map((m) => _withTime(m, at)));
          }
          // What a launched command printed names the server. Not what a probe printed.
          final printed = outputTextOf(call);
          if (printed != null && printing && !_isProbe(command)) {
            _banners(printed, command, at, out);
            if (done) _saved(printed, call.cwd, at, out);
          }
        }
      }
    default:
  }
  return out.length > _perItem ? out.sublist(0, _perItem) : out;
}

_Mention _withTime(_Mention m, DateTime? at) => switch (m.act) {
  _Act.server => _Mention.server(m.url, at),
  _Act.file => _Mention.file(m.path, m.cwd, m.cd, at),
  _Act.drop => _Mention.drop(m.path, m.cwd, m.cd, at),
};

const _textCap = 20000;

// ----- the agent's own words -----

final _url = RegExp(
  r'https?://(?:[^\s/@<>"`]+@)?(?:\[[0-9a-fA-F:.]+\]|[A-Za-z0-9.\-]+)(?::\d{1,5})?(?:[/?#][^\s<>"`)\]}]*)?',
  caseSensitive: false,
);
final _closingPunct = RegExp(r'''[.,;:!?'"]+$''');
final _markRun = RegExp(r'[*_~]+$');
// A bare `host:port` in prose: the spellings a dev server prints. Not after `/`
// (the scheme case, read by [_url]), `@` (`postgres://u@127.0.0.1:5432`), `:`
// (a tunnel, `ssh -L 8080:127.0.0.1:5432`), `.` or `-` (a longer name).
final _bareLocalhost = RegExp(
  r'(?<![\w/.\-@:])(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\]):(\d{2,5})(?![\w])',
  caseSensitive: false,
);
final _fence = RegExp(r'```[\s\S]*?```');
final _token = RegExp(r'''[^\s"'`()<>\[\]{}|;,=*?]+''');
// A word of making. `built` is apart: it also says what a build step did to the
// app ("I built the app"), so it counts only when the path follows it directly
// ("built dist/index.html"). `opened` and `output` are not here: the chat opens
// and outputs existing files all day.
final _madeVerb = RegExp(
  r'\b(?:created?|wrote|written|writing|saved?|generated?|exported?|produced?|made|report at|tạo|lưu|xuất|ghi)\b',
  caseSensitive: false,
);
final _builtVerb = RegExp(r'^built$', caseSensitive: false);
final _clauseBreak = RegExp(r'[,;:!?\n]|\.(?:\s|$)|\s(?=(?:and|then|but)\s)', caseSensitive: false);
final _wordEdge = RegExp(r'''^[`*_"'(\[]+|[`*_"')\]]+$''');

/// Whether a word of making stands right before the path at [start] in [prose]:
/// only the clause the path is in is read (after the last `.`, `,`, `;`, `:`,
/// `!`, `?`, line break, `and`, `then` or `but`), and the verb must be within
/// its last 4 words ("saved the chart to charts/x.png", "created docs/spec.md").
/// Further back it is another thing the agent did ("I created the handler and
/// then updated the README.md"), or a path in a sentence about something else.
bool _madeBefore(String prose, int start) {
  final before = prose.substring(start - 80 < 0 ? 0 : start - 80, start);
  var tail = before;
  for (final b in _clauseBreak.allMatches(before)) {
    tail = before.substring(b.end);
  }
  final words = [
    for (final w in tail.split(RegExp(r'\s+')))
      if (w.replaceAll(_wordEdge, '').isNotEmpty) w.replaceAll(_wordEdge, ''),
  ];
  if (words.isEmpty) return false;
  if (_builtVerb.hasMatch(words.last)) return true;
  return _madeVerb.hasMatch(words.skip(words.length > 4 ? words.length - 4 : 0).join(' '));
}

void _say(String text, DateTime? at, List<_Mention> out) {
  for (final m in _url.allMatches(text)) {
    final s = _serverUri(m.group(0)!, text.substring(0, m.start), keepPath: true);
    if (s != null) out.add(_Mention.server(s, at));
  }
  for (final m in _bareLocalhost.allMatches(text)) {
    final port = int.parse(m.group(1)!);
    if (port >= 1 && port <= 65535) out.add(_Mention.server(Uri(scheme: 'http', host: 'localhost', port: port, path: '/'), at));
  }
  // Pages: a code block shows what a file CONTAINS (`<img src="logo.svg">`), so
  // it is not read; a bare name needs a verb of making just before it.
  final prose = text.replaceAll(_fence, ' ').replaceAll(_url, ' ');
  for (final m in _token.allMatches(prose)) {
    final raw = m.group(0)!;
    if (raw.length > 400) continue;
    // Nearly every token is a plain word: reject it before the costlier clean-up.
    if (!raw.contains('.')) continue;
    final p = _cleanPath(raw);
    final kind = p == null ? null : _kindOf(p);
    if (p == null || kind == null) continue;
    // A page with a folder in it counts; a bare name, and any picture or
    // document (the chat names existing README.md files and screenshots all day),
    // only right after a word of making.
    if (!p.contains('/') || kind != MadeFileKind.page) {
      if (!_madeBefore(prose, m.start)) continue;
    }
    out.add(_Mention.file(p, null, null, at));
  }
}

// ----- commands -----

/// The command up to where a heredoc body starts: what follows is the content
/// of a file, whose own links and names are not what the agent made.
String _commandHead(String command) {
  final out = <String>[];
  for (final line in command.split('\n').take(6)) {
    out.add(line.length > 2000 ? line.substring(0, 2000) : line);
    if (line.contains('<<')) break;
  }
  return out.join('\n');
}

final _segments = RegExp(r'&&|\|\||[;|\n]');
const _wrappers = {'sudo', 'nohup', 'time', 'env', 'command', 'builtin'};

/// What a command that reads or probes does not make: its output is not a
/// banner. `localhost` after `ssh` or `docker exec` is another host.
const _probes = {
  'cat', 'rg', 'grep', 'egrep', 'sed', 'awk', 'git', 'head', 'tail', 'less', 'more', 'curl', 'wget', 'http',
  'ssh', 'scp', 'kubectl', 'jq', 'ls', 'find', 'echo', 'printf', 'diff', 'nl', 'wc', 'psql', 'redis-cli', 'gh', 'nc',
};

bool _isProbe(String command) {
  for (final seg in _commandHead(command).split(_segments)) {
    final w = _words(seg).where((w) => !w.contains('=') && !_wrappers.contains(w)).toList();
    if (w.isEmpty) continue;
    final first = w.first;
    if (_probes.contains(first)) return true;
    if ((first == 'docker' || first == 'podman') && w.length > 1 && (w[1] == 'exec' || w[1] == 'run' && w.contains('-it'))) return true;
  }
  return false;
}

List<String> _words(String segment) {
  final out = <String>[];
  final buf = StringBuffer();
  String? quote;
  for (final ch in segment.split('')) {
    if (quote != null) {
      if (ch == quote) {
        quote = null;
      } else {
        buf.write(ch);
      }
    } else if (ch == '"' || ch == "'") {
      quote = ch;
    } else if (ch == ' ' || ch == '\t') {
      if (buf.isNotEmpty) {
        out.add(buf.toString());
        buf.clear();
      }
    } else {
      buf.write(ch);
    }
  }
  if (buf.isNotEmpty) out.add(buf.toString());
  return out;
}

const _outFlags = {'-o', '--output', '--out', '--outfile', '--screenshot', '--save', '--export', '--html'};

/// The pages a command writes, moves or removes: only what its words say it
/// writes (a redirect, `tee`, an output flag, a `cp`/`mv` target, `open`). A
/// leading `cd X` moves where a relative name is taken from.
List<_Mention> _scanCommand(String command, String? callCwd) {
  final out = <_Mention>[];
  String? cd;
  void page(String raw) {
    final p = _cleanPath(raw);
    if (p != null && _kindOf(p) != null) out.add(_Mention.file(p, callCwd, cd, null));
  }

  void drop(String raw) {
    final p = _cleanPath(raw);
    if (p != null && _kindOf(p) != null) out.add(_Mention.drop(p, callCwd, cd, null));
  }

  for (final seg in _commandHead(command).split(_segments)) {
    final all = _words(seg);
    var i = 0;
    while (i < all.length && (all[i].contains('=') && !all[i].startsWith('-') || _wrappers.contains(all[i]))) {
      i++;
    }
    if (i >= all.length) continue;
    final cmd = all[i];
    final args = all.sublist(i + 1);
    if (cmd == 'cd') {
      if (args.isNotEmpty) {
        final to = args.first;
        cd = cd == null || RemotePath.isAbsolute(to) || RemotePath.usesHome(to) ? to : RemotePath.normalize('$cd/$to');
      }
      continue;
    }
    // Redirects, wherever they stand in the segment.
    for (var j = 0; j < all.length; j++) {
      final w = all[j];
      if (w == '>' || w == '>>') {
        if (j + 1 < all.length) page(all[j + 1]);
      } else if (w.startsWith('>') && !w.startsWith('>&') && w.length > 1) {
        page(w.replaceFirst(RegExp(r'^>>?'), ''));
      }
    }
    final plain = [for (final a in args) if (!a.startsWith('-') && !a.startsWith('>')) a];
    switch (cmd) {
      case 'tee':
        plain.forEach(page);
      case 'cp':
        if (plain.length >= 2) page(plain.last);
      case 'mv':
        if (plain.length >= 2) {
          page(plain.last);
          plain.sublist(0, plain.length - 1).forEach(drop);
        }
      case 'rm' || 'unlink':
        plain.forEach(drop);
      case 'open' || 'xdg-open' || 'start' || 'sensible-browser':
        plain.forEach(page);
      case 'curl' || 'wget':
        // A download is not something the agent made.
        break;
      default:
        for (var j = 0; j < args.length; j++) {
          final a = args[j];
          if (_outFlags.contains(a) && j + 1 < args.length) {
            page(args[j + 1]);
          } else if (a.startsWith('--') && a.contains('=')) {
            final eq = a.indexOf('=');
            if (_outFlags.contains(a.substring(0, eq))) page(a.substring(eq + 1));
          }
        }
    }
  }
  return out;
}

// ----- what a launched command printed -----

// A labelled address ("Local:   http://localhost:5173/", "Network: http://...",
// "Local URL: http://localhost:8501"): the label opens the line and the URL
// follows it. The bare words `local` and `network` were too wide ("Network
// request to http://localhost:8000/api failed", "using local proxy
// http://127.0.0.1:7890").
final _labelled = RegExp(r'^[^\w]*(?:local|network)(?:\s+url)?\s*:\s*https?://', caseSensitive: false);
final _banner = RegExp(
  r'running (?:on|at)|serving http|ready (?:on|at|in)|started server|available at|'
  r'server (?:is )?(?:running|started)|development server|dev server|web server|app running|open .{0,20} at|view it at|you can now view',
  caseSensitive: false,
);
// "Listening on" is also what a fixture server inside a test, a proxy or a
// client library prints, so it counts only from a command that looks like a
// launch: it names one of these words. The list is short on purpose: a command
// outside it (`make check`) can still print a labelled or "running on" banner.
final _listening = RegExp(r'listening (?:on|at)|server (?:is )?listening', caseSensitive: false);
final _launchLike = RegExp(
  r'dev|serve|start|run|uvicorn|gunicorn|http\.server|flask|vite|next|npm|yarn|pnpm|bun|node|deno|python|php|ruby|rails',
  caseSensitive: false,
);
// A test run starts servers of its own and prints their addresses; none of it
// is something the person can open.
final _testRun = RegExp(
  r'(?:^|[\s;&|(])(?:pytest|py\.test|jest|mocha|tox|vitest\s+run|go\s+test|cargo\s+test|flutter\s+test|dart\s+test|make\s+test|'
  r'(?:npm|yarn|pnpm|bun)(?:\s+run)?\s+test(?::[\w-]+)?)(?![\w-])',
  caseSensitive: false,
);

/// A launch prints where it is up on a line of its own ("Local: http://...",
/// "Uvicorn running on http://...", "Serving HTTP on 0.0.0.0 port 8000
/// (http://0.0.0.0:8000/)"), near the top. Only those lines of the first 8 KB
/// are read, and only for the origin: a log that names the server on every
/// line, or an API response with a path, makes no row. Never from a test run.
void _banners(String printed, String command, DateTime? at, List<_Mention> out) {
  final head = _commandHead(command);
  if (_testRun.hasMatch(head)) return;
  final launch = _launchLike.hasMatch(head);
  final text = printed.length > 8192 ? printed.substring(0, 8192) : printed;
  for (final line in text.split('\n')) {
    final l = line.length > 300 ? line.substring(0, 300) : line;
    if (!_labelled.hasMatch(l) && !_banner.hasMatch(l) && !(launch && _listening.hasMatch(l))) continue;
    for (final m in _url.allMatches(l)) {
      final s = _serverUri(m.group(0)!, l.substring(0, m.start), keepPath: false);
      if (s != null) out.add(_Mention.server(s, at));
    }
  }
}

final _savedVerb = RegExp(r'\b(?:saved|wrote|written|generated|exported|created|screenshot)\b', caseSensitive: false);

/// A tool that makes a file says so on a line of its own ("Saved screenshot to
/// out/a.png", "Wrote reports/q3.html"): the first 8 KB, a line with a word of
/// making and a path with a folder in it. A listing or a log names files
/// without the word.
void _saved(String printed, String? cwd, DateTime? at, List<_Mention> out) {
  final head = printed.length > 8192 ? printed.substring(0, 8192) : printed;
  for (final line in head.split('\n')) {
    final l = line.length > 300 ? line.substring(0, 300) : line;
    if (!_savedVerb.hasMatch(l)) continue;
    for (final m in _token.allMatches(l.replaceAll(_url, ' '))) {
      final raw = m.group(0)!;
      if (raw.length > 400) continue;
      final p = _cleanPath(raw);
      if (p != null && p.contains('/') && _kindOf(p) != null) out.add(_Mention.file(p, cwd, null, at));
    }
  }
}

// ----- servers -----

/// [before] is the text just before the link.
Uri? _serverUri(String raw, String before, {required bool keepPath}) {
  // What closes the sentence or the markdown around the link is not the link:
  // `**http://127.0.0.1:8766/**` was read as the path `/**`, a row named
  // `localhost:8766/**` that asked the server for a page that is not there.
  // A run of `*`, `_` or `~` is a mark only when the same run opens the link
  // (`**url**`, `_url_`, `~~url~~`): `?q=snake_` keeps its `_`.
  var trimmed = raw.replaceFirst(_closingPunct, '');
  final opening = _markRun.firstMatch(before)?.group(0);
  if (opening != null && trimmed.endsWith(opening)) {
    trimmed = trimmed.substring(0, trimmed.length - opening.length).replaceFirst(_closingPunct, '');
  }
  final uri = Uri.tryParse(trimmed);
  if (uri == null || uri.scheme.toLowerCase() != 'http' || !isPreviewHost(uri.host)) return null;
  // `:0` parses as no port at all, so the digits are read from the text.
  final written = RegExp(r'^https?://(?:[^/@]*@)?(?:\[[^\]]*\]|[^/:?#]*):(\d+)', caseSensitive: false).firstMatch(trimmed);
  final port = written != null ? int.parse(written.group(1)!) : (uri.hasPort ? uri.port : 80);
  if (port < 1 || port > 65535) return null;
  // Rebuilt: no credentials, no fragment.
  return Uri(
    scheme: 'http',
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    path: keepPath && uri.path.isNotEmpty ? uri.path : '/',
    query: keepPath && uri.hasQuery && uri.query.isNotEmpty ? uri.query : null,
  );
}

MadeAsset _serverOf(Uri url, DateTime? at, int order) {
  final port = url.hasPort ? url.port : 80;
  final path = url.path == '/' ? '' : _display(url.path);
  return MadeAsset(
    kind: MadeKind.server,
    key: 'localhost:$port',
    title: 'localhost${url.hasPort ? ':$port' : ''}$path',
    where: '',
    url: url,
    at: at,
    order: order,
  );
}

String _display(String encoded) {
  try {
    return Uri.decodeComponent(encoded);
  } on FormatException {
    return encoded;
  }
}

// ----- pages -----

final _noise = RegExp(r'(?:^|/)(?:node_modules|site-packages|\.git|\.dart_tool)/|^/(?:usr|proc|sys|lib|opt)/');
final _drive = RegExp(r'^[A-Za-z]:[\\/]');

MadeFileKind? _kindOf(String path) => _noise.hasMatch(path) ? null : madeFileKindOf(path);

/// A path as the scanner will keep it, or null when it is not a usable path of
/// the machine: a shell variable, a URL, a Windows drive, `~user`.
String? _cleanPath(String raw) {
  var p = raw.trim();
  if (p.startsWith('file://')) p = p.substring(7);
  p = p.replaceFirst(RegExp(r'[.,:;!?]+$'), '').replaceFirst(RegExp(r':\d+(?::\d+)?$'), '').replaceFirst(RegExp(r'#[^/]*$'), '');
  if (p.isEmpty || p.contains(r'$') || p.contains('`') || p.contains('://') || _drive.hasMatch(p)) return null;
  if (p.startsWith('~') && !p.startsWith('~/')) return null;
  if (p.startsWith('//')) return null;
  return p;
}

/// The key of [m]'s path (absolute, normalized), or null when a relative path
/// has no folder to be taken against.
String? _placed(_Mention m, String? sessionCwd) {
  final path = m.path!;
  if (RemotePath.isAbsolute(path)) return RemotePath.normalize(path);
  if (RemotePath.usesHome(path)) return RemotePath.normalize(path);
  final cwd = m.cwd ?? sessionCwd;
  if (cwd == null || cwd.isEmpty || !RemotePath.isAbsolute(cwd)) return null;
  final base = m.cd == null ? cwd : RemotePath.resolve(m.cd!, cwd: cwd, home: null);
  if (base == null) return null;
  return RemotePath.resolve(path, cwd: base);
}

MadeAsset? _fileOf(_Mention m, String? sessionCwd, int order) {
  final key = _placed(m, sessionCwd);
  final fileKind = key == null ? null : _kindOf(key);
  if (key == null || fileKind == null) return null;
  final name = RemotePath.basename(key);
  final parent = RemotePath.parent(key);
  final folder = parent == '/' || parent == '.' ? '' : '${RemotePath.basename(parent)}/';
  final kind = switch (fileKind) {
    MadeFileKind.page => MadeKind.page,
    MadeFileKind.picture => MadeKind.picture,
    MadeFileKind.doc => MadeKind.doc,
  };
  return MadeAsset(kind: kind, key: key, title: name, where: folder, path: key, at: m.at, order: order);
}
