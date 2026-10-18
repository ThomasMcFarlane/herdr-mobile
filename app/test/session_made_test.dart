import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/background/background_work.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/data/acp/session_made.dart';
import 'package:herdr_mobile/data/models/made_files.dart';

var _n = 0;

TranscriptItem _say(String text, {MessageRole role = MessageRole.agent}) =>
    TranscriptMessage(key: 'm${_n++}', role: role, blocks: [TextBlock(text)]);

TranscriptItem _run(String command, {String? output, String? cwd, ToolStatus status = ToolStatus.completed}) => TranscriptTool(
      ToolCall(
        toolCallId: 't${_n++}',
        kind: ToolKind.execute,
        status: status,
        rawInput: {'command': command},
        output: output == null ? null : ToolOutput(text: output, exited: true, exitCode: 0),
        meta: cwd == null ? null : {'terminal_info': {'cwd': cwd}},
      ),
    );

TranscriptItem _patch(String path, {String? oldText, required String newText}) => TranscriptTool(
      ToolCall(
        toolCallId: 't${_n++}',
        kind: ToolKind.edit,
        status: ToolStatus.completed,
        content: [ToolDiff(path: path, oldText: oldText, newText: newText)],
        locations: [ToolLocation(path: path)],
      ),
    );

TranscriptItem _write(String path, {ToolKind kind = ToolKind.edit, ToolStatus status = ToolStatus.completed}) => TranscriptTool(
      ToolCall(
        toolCallId: 't${_n++}',
        kind: kind,
        status: status,
        content: [ToolDiff(path: path, newText: '<h1>x</h1>')],
        locations: [ToolLocation(path: path)],
      ),
    );

TranscriptItem _read(String path) => TranscriptTool(
      ToolCall(toolCallId: 't${_n++}', kind: ToolKind.read, status: ToolStatus.completed, locations: [ToolLocation(path: path)]),
    );

TranscriptItem _delete(String path) => TranscriptTool(
      ToolCall(toolCallId: 't${_n++}', kind: ToolKind.delete, status: ToolStatus.completed, locations: [ToolLocation(path: path)]),
    );

List<String> _keys(List<TranscriptItem> items, {String? cwd}) => [for (final a in madeAssetsOf(items, cwd: cwd)) a.key];

List<MadeKind> webAssetsKinds(List<String> names) => [
      for (final n in names)
        if (madeFileKindOf(n) case final k?)
          switch (k) {
            MadeFileKind.page => MadeKind.page,
            MadeFileKind.picture => MadeKind.picture,
            MadeFileKind.doc => MadeKind.doc,
          },
    ];

const _vite = '  VITE v5.2.0  ready in 312 ms\n\n  ➜  Local:   http://localhost:5173/\n  ➜  Network: http://192.168.1.20:5173/\n';

void main() {
  group('servers', () {
    test('a launch prints its address on a banner line; one row per port under any loopback spelling', () {
      final items = [
        _run('npm run dev', output: _vite),
        _say('Also on http://127.0.0.1:5173/ and http://0.0.0.0:5173.'),
      ];
      final assets = madeAssetsOf(items);
      expect(assets.map((a) => a.key), ['localhost:5173']);
      expect(assets.single.title, 'localhost:5173');
    });

    test('the banners real dev servers print are read', () {
      for (final banner in [
        '  - Local:        http://localhost:3000\n',
        ' * Running on http://127.0.0.1:5000\n',
        'INFO:     Uvicorn running on http://127.0.0.1:8000 (Press CTRL+C to quit)\n',
        'Serving HTTP on 0.0.0.0 port 8000 (http://0.0.0.0:8000/) ...\n',
        'Project is running at: http://localhost:8080/\n',
        'Web Server is available at http://localhost:1313/\n',
        'Local URL: http://localhost:8501\n',
      ]) {
        expect(_keys([_run('start-it', output: banner)]), hasLength(1), reason: banner);
      }
    });

    test('what a probe or a log prints is not a server the agent started', () {
      // 1,304 of 1,861 rows from 6,000 real sessions came from these.
      final items = [
        _run('curl -s http://localhost:11434/api/tags', output: '{"models":[]}\nlocal http://localhost:11434/api/tags\n'),
        _run('cat docker-compose.yml', output: 'local: http://localhost:19530\n'),
        _run("rg 'localhost:9002' src", output: 'src/a.ts: Local: http://localhost:9002\n'),
        _run("ssh box 'npm run dev'", output: _vite),
        _run('docker exec db sh', output: 'Listening on http://localhost:5432\n'),
        _run('make test', output: List.filled(200, 'GET http://localhost:9000/health 200 ok').join('\n')),
        _run('git diff', output: '+  url: http://localhost:3000\n'),
      ];
      expect(_keys(items), isEmpty);
    });

    test('"local" and "network" in a log line are not an address the agent launched', () {
      final items = [
        _run('npm run dev', output: 'Network request to http://localhost:8000/api failed\n'),
        _run('python app.py', output: 'using local proxy http://127.0.0.1:7890\n'),
        _run('npm test', output: 'Server listening on http://127.0.0.1:38211\n'),
        _run('go test ./...', output: 'Server listening on http://127.0.0.1:38212\nLocal: http://localhost:38213/\n'),
        _run('pytest -q', output: 'Uvicorn running on http://127.0.0.1:38214\n'),
        _run('npx vitest run', output: 'Local: http://localhost:38215/\n'),
        _run('cd app && flutter test', output: 'Serving HTTP on 0.0.0.0 port 38216 (http://0.0.0.0:38216/)\n'),
        _run('make check', output: 'Server listening on http://127.0.0.1:38217\n'),
      ];
      expect(_keys(items), isEmpty);
    });

    test('a launch that says "listening on" is still a server, from a command that starts something', () {
      expect(_keys([_run('node server.js', output: 'Server listening on http://127.0.0.1:3001\n')]), ['localhost:3001']);
      expect(_keys([_run('npm run dev', output: _vite)]), ['localhost:5173']);
      expect(_keys([_run('uvicorn app:app', output: 'INFO:     Uvicorn running on http://127.0.0.1:8000\n')]), ['localhost:8000']);
      expect(_keys([_run('python -m http.server 8000', output: 'Serving HTTP on 0.0.0.0 port 8000 (http://0.0.0.0:8000/) ...\n')]), ['localhost:8000']);
    });

    test('a command that failed or was cancelled names no server; one still running does', () {
      for (final s in [ToolStatus.failed, ToolStatus.cancelled, ToolStatus.pending]) {
        expect(_keys([_run('npm run dev', output: _vite, status: s)]), isEmpty, reason: '$s');
      }
      expect(_keys([_run('npm run dev', output: _vite, status: ToolStatus.inProgress)]), ['localhost:5173']);
    });

    test('a command\'s own text names no server', () {
      expect(_keys([_run('curl http://localhost:3000/health && npm run dev')]), isEmpty);
    });

    test('the agent\'s own link keeps its path; a bare localhost:port counts too; output only the origin', () {
      final items = [
        _say('Open http://localhost:8000/docs for the API, and the app is on localhost:5173.'),
        _run('npm start', output: 'Local: http://localhost:4000/internal/debug/x\n'),
      ];
      final byKey = {for (final a in madeAssetsOf(items)) a.key: a};
      expect(byKey['localhost:8000']!.title, 'localhost:8000/docs');
      expect(byKey['localhost:5173'], isNotNull);
      expect(byKey['localhost:4000']!.url!.path, '/');
    });

    test('only plain http to the machine itself, spelled the ways a dev server spells it', () {
      final items = [
        _say(
          'https://localhost:8443/admin http://192.168.1.20:3000 http://printer.local:9100/ http://127.0.0.5:6379/ '
          'http://evil.localhost:3000/ http://redis.svc.cluster.local:6379 http://localhost:0/ http://localhost:65536/ '
          'http://localhost@example.com/ http://example.com#@localhost http://127.0.0.1.example.com/ '
          'http://[::1]:5173/ HTTP://LOCALHOST:3000/',
        ),
      ];
      expect(_keys(items), ['localhost:3000', 'localhost:5173']);
    });

    test('credentials in a link are not kept', () {
      final s = madeAssetsOf([_say('http://user:secret@localhost:3000/x')]).single;
      expect(s.url.toString(), 'http://localhost:3000/x');
    });

    test('a link the agent set in bold, italics or code is the link without the marks or the full stop', () {
      final cases = {
        '**http://127.0.0.1:8766/**': 'localhost:8766',
        '__http://localhost:3000/docs__': 'localhost:3000/docs',
        'See *http://localhost:3001/a*.': 'localhost:3001/a',
        'See _http://localhost:3002/b_.': 'localhost:3002/b',
        '~~http://localhost:3003/c~~': 'localhost:3003/c',
        '`http://localhost:3004/d`': 'localhost:3004/d',
        '(on http://localhost:3005/e).': 'localhost:3005/e',
        '**http://localhost:3006/f?x=1**!': 'localhost:3006/f',
      };
      for (final c in cases.entries) {
        final s = madeAssetsOf([_say(c.key)]).single;
        expect(s.title, c.value, reason: c.key);
        expect(s.url!.path, isNot(contains('*')), reason: c.key);
        expect(s.url!.toString(), isNot(endsWith('_')), reason: c.key);
      }
      expect(madeAssetsOf([_say('**http://localhost:3006/f?x=1**')]).single.url.toString(), 'http://localhost:3006/f?x=1');
    });

    test('a server mentioned again moves to the top and takes the newest path', () {
      final items = [
        _say('Running http://localhost:3000/'),
        _say('Report at http://localhost:4000/'),
        _say('Try http://localhost:3000/health'),
      ];
      expect(madeAssetsOf(items).map((a) => a.title), ['localhost:3000/health', 'localhost:4000']);
    });

    test('a user message is not something the session made', () {
      expect(_keys([_say('Please run http://localhost:3000', role: MessageRole.user)]), isEmpty);
    });

    test('state: running only while a running task names the port; stopped when only ended ones do; else just seen', () {
      final server = madeAssetsOf([_say('http://localhost:5173/')]).single;
      BackgroundTask task(String title, BackgroundStatus s) =>
          BackgroundTask(id: title, kind: BackgroundKind.shell, status: s, title: title);
      expect(serverStateOf(server, const []), ServerState.seen);
      expect(serverStateOf(server, [task('vite --port 5173', BackgroundStatus.running)]), ServerState.running);
      expect(serverStateOf(server, [task('vite --port 5173', BackgroundStatus.paused)]), ServerState.stopped, reason: 'paused serves nothing');
      expect(serverStateOf(server, [task('vite --port 5173', BackgroundStatus.finished)]), ServerState.stopped);
      expect(
        serverStateOf(server, [task('vite --port 5173', BackgroundStatus.finished), task('npm run dev -- --port 5173', BackgroundStatus.running)]),
        ServerState.running,
      );
      expect(serverStateOf(server, [task('serve -p 51730', BackgroundStatus.running)]), ServerState.seen, reason: 'a longer number is another port');
      expect(
        serverStateOf(server, [task('vite --port 5173', BackgroundStatus.running)], live: false),
        ServerState.seen,
        reason: 'a saved copy or a link that is down knows of nothing running now',
      );
    });
  });

  group('pages the agent wrote', () {
    test('a file a tool wrote is a page; a file it only read is not; an edit that has not completed changed nothing', () {
      final items = [
        _write('/home/dev/app/report.html'),
        _read('/home/dev/app/old.html'),
        _write('/home/dev/app/main.dart'),
        _write('/a/pending.html', status: ToolStatus.pending),
      ];
      expect(_keys(items), ['/home/dev/app/report.html']);
    });

    test('a page that was deleted or moved away is not listed', () {
      final items = [
        _write('/a/one.html'),
        _write('/a/two.html'),
        _write('/a/three.html'),
        _delete('/a/one.html'),
        _run('rm /a/two.html'),
        _run('mv /a/three.html /a/four.html'),
      ];
      expect(_keys(items), ['/a/four.html']);
    });

    test('a page written again is one row, newest first', () {
      expect(_keys([_write('/a/one.html'), _write('/a/two.html'), _write('/a/one.html')]), ['/a/one.html', '/a/two.html']);
    });

    test('dependencies and system files are not the session\'s pages', () {
      final items = [_write('/w/node_modules/pkg/index.html'), _write('/usr/share/doc/x/index.html'), _write('/w/.git/a.html'), _write('/w/mine.html')];
      expect(_keys(items), ['/w/mine.html']);
    });
  });

  group('pages a command writes', () {
    test('a redirect, tee, an output flag, a copy target and open name what the command makes', () {
      final items = [
        _run('python gen_report.py > reports/q3.html', cwd: '/home/dev/app'),
        _run('python gen.py | tee out/b.html', cwd: '/home/dev/app'),
        _run('coverage html --output=cov/index.html', cwd: '/home/dev/app'),
        _run('cp template.html site/c.html', cwd: '/home/dev/app'),
        _run('xdg-open site/c.html', cwd: '/home/dev/app'),
      ];
      expect(_keys(items), [
        '/home/dev/app/site/c.html',
        '/home/dev/app/cov/index.html',
        '/home/dev/app/out/b.html',
        '/home/dev/app/reports/q3.html',
      ]);
    });

    test('a command that did not run wrote and removed nothing', () {
      for (final s in [ToolStatus.pending, ToolStatus.inProgress, ToolStatus.failed, ToolStatus.cancelled]) {
        expect(_keys([_run('echo x > a.html', cwd: '/w', status: s)]), isEmpty, reason: '$s writes nothing');
        expect(_keys([_run('echo x > a.html', cwd: '/w'), _run('rm a.html', cwd: '/w', status: s)]), ['/w/a.html'], reason: '$s removes nothing');
        expect(_keys([_run('python shot.py', output: 'Saved screenshot to screenshots/a.png\n', cwd: '/w', status: s)]), isEmpty, reason: '$s');
      }
    });

    test('a leading cd moves where a relative name is taken from', () {
      final items = [_run('cd /tmp/scratch/report && python gen.py > out.html', cwd: '/home/dev/app'), _run('cd sub && cd deep; echo x > y.html', cwd: '/w')];
      expect(_keys(items), ['/w/sub/deep/y.html', '/tmp/scratch/report/out.html']);
    });

    test('a command that only mentions a file, reads it, lists it or downloads it made nothing', () {
      // 417 of 513 page rows in 6,000 real sessions were these.
      final items = [
        _run('grep -n title report.html', cwd: '/w'),
        _run('cat site/index.html', cwd: '/w'),
        _run('ls htmlcov', output: 'index.html\nz_1_a_py.html\n', cwd: '/w'),
        _run('curl -sL -o page.html https://example.com/a', cwd: '/w'),
        _run('wget -O page2.html https://example.com/b', cwd: '/w'),
        _run('git diff -- docs/a.html', cwd: '/w'),
        _run('python gen.py', cwd: '/w'),
      ];
      expect(_keys(items), isEmpty);
    });

    test('the body of a heredoc is a file\'s content, not something the agent made', () {
      final items = [
        _run("cat > site/index.html <<'EOF'\n<a href=\"about.html\">x</a>\n<a href=\"/contact.html\">y</a>\nEOF", cwd: '/w'),
      ];
      expect(_keys(items), ['/w/site/index.html']);
    });

    test('shell variables, urls and Windows paths are not paths of the machine', () {
      final items = [
        _run(r'echo hi > $OUT/flow/t.html', cwd: '/w'),
        _run(r'echo hi > C:\Users\me\a.html', cwd: '/w'),
      ];
      expect(_keys(items), isEmpty);
    });

    test('a relative name with no folder to take it from is not guessed', () {
      expect(_keys([_run('echo x > a.html')]), isEmpty);
      expect(_keys([_run('echo x > a.html')], cwd: ''), isEmpty, reason: 'an empty folder is an unknown one');
      expect(_keys([_run('echo x > a.html')], cwd: '/w'), ['/w/a.html']);
    });
  });

  group('pages the agent names', () {
    test('a path with a folder in it counts; a markdown link too; a code block does not', () {
      final items = [
        _say('See `coverage/index.html` and [the chart](diagrams/architecture.svg).\n```html\n<img src="logo.svg"><a href="reports/x.html">x</a>\n```'),
      ];
      expect(_keys(items, cwd: '/home/dev/app'), ['/home/dev/app/diagrams/architecture.svg', '/home/dev/app/coverage/index.html']);
    });

    test('a bare file name counts only right after a word of making', () {
      expect(_keys([_say('The index.html in a Vite app is the entry point.')], cwd: '/w'), isEmpty);
      expect(_keys([_say('I created report.html for you.')], cwd: '/w'), ['/w/report.html']);
      expect(_keys([_say('Đã tạo report.html cho bạn.')], cwd: '/w'), ['/w/report.html']);
    });

    test('the word of making must be right before the path, in the same clause', () {
      for (final said in [
        'I created the new handler and then updated the README.md accordingly',
        'I opened README.md and read it',
        'I built the app, and the usage is documented in docs/usage.md',
        'Wrote the script. The file docs/old-spec.pdf was left unchanged.',
        'I created the handler and then updated the README.md',
        'Output: README.md',
      ]) {
        expect(_keys([_say(said)], cwd: '/w'), isEmpty, reason: said);
      }
      for (final (said, key) in [
        ('I saved the chart to charts/x.png', '/w/charts/x.png'),
        ('I created docs/spec.md', '/w/docs/spec.md'),
        ('Wrote report.pdf', '/w/report.pdf'),
        ('I built dist/index.html', '/w/dist/index.html'),
        ('I created a new report.html', '/w/report.html'),
        ('I fixed the bug and then created summary.md', '/w/summary.md'),
      ]) {
        expect(_keys([_say(said)], cwd: '/w'), [key], reason: said);
      }
    });

    test('a line number, an anchor, a full stop and file:// are not part of the path', () {
      final items = [_say('Wrote /tmp/out/final.html. Then /tmp/out/a.html:12 and /tmp/out/b.html#top and file:///tmp/out/c.html.')];
      expect(_keys(items), ['/tmp/out/c.html', '/tmp/out/b.html', '/tmp/out/a.html', '/tmp/out/final.html']);
    });

    test('a path inside a url is not a page, and a server is still found', () {
      expect(_keys([_say('Wrote /tmp/out/final.html. Then http://localhost:8000/not-a-page.html is served.')]), ['/tmp/out/final.html', 'localhost:8000']);
    });

    test('the same file under its spellings is one row', () {
      final items = [_say('see ./reports/a.html and reports/a.html and ../app/reports/a.html and /w/app/reports/a.html')];
      expect(_keys(items, cwd: '/w/app'), ['/w/app/reports/a.html']);
    });
  });

  group('bounds', () {
    test('a session lists at most madeAssetsCap rows and one item at most 40 mentions', () {
      final many = [for (var i = 0; i < 400; i++) _say('http://localhost:${3000 + i}/')];
      final assets = madeAssetsOf(many);
      expect(assets, hasLength(madeAssetsCap));
      expect(assets.first.key, 'localhost:3399', reason: 'the newest are kept');
      final oneMessage = _say([for (var i = 0; i < 200; i++) 'http://localhost:${4000 + i}/'].join(' '));
      expect(madeAssetsOf([oneMessage]).length, lessThanOrEqualTo(40));
    });

    test('a flood of one kind never pushes another kind out', () {
      final items = [_say('http://localhost:3000/'), for (var i = 0; i < madeAssetsCap + 50; i++) _say('I saved shots/$i.png')];
      final assets = madeAssetsOf(items, cwd: '/w');
      expect(assets.where((a) => a.kind == MadeKind.server), hasLength(1));
      final pictures = assets.where((a) => a.kind == MadeKind.picture).toList();
      expect(pictures, hasLength(madeAssetsCap));
      expect(pictures.first.key, '/w/shots/${madeAssetsCap + 49}.png');
      expect(pictures.last.key, '/w/shots/50.png', reason: 'each kind keeps its newest');
      expect(assets.last.key, 'localhost:3000', reason: 'still newest first overall');
    });

    test('text with no break in it is read in linear time', () {
      // A lazy match with a following lookahead was quadratic: 64 KB took 30 s.
      final blob = 'a' * 60000;
      final dots = 'a.' * 30000;
      final b64 = 'data:image/png;base64,${'QUJD' * 15000}';
      final watch = Stopwatch()..start();
      madeAssetsOf([_say(blob), _say(dots), _say(b64), _run('echo ${'x' * 30000} > out.html', cwd: '/w')]);
      expect(watch.elapsedMilliseconds, lessThan(1500));
    });
  });

  group('the list', () {
    test('the same list answers from memory, per folder', () {
      final items = [_say('http://localhost:3000/'), _write('/a/one.html')];
      expect(identical(madeAssetsOf(items, cwd: '/a'), madeAssetsOf(items, cwd: '/a')), isTrue);
      final other = madeAssetsOf(items, cwd: '/b');
      expect(identical(madeAssetsOf(items, cwd: '/a'), madeAssetsOf(items, cwd: '/a')), isTrue, reason: 'another folder does not evict');
      expect(other, isNotNull);
    });

    test('a longer list scans only what is new and keeps newest first', () {
      final items = [_say('http://localhost:3000/'), _write('/a/one.html')];
      final longer = [...items, _say('http://localhost:4000/')];
      expect(_keys(longer), ['localhost:4000', '/a/one.html', 'localhost:3000']);
    });

    test('a streaming tool call keeps its server while its output grows', () {
      final call = ToolCall(toolCallId: 'x', kind: ToolKind.execute, status: ToolStatus.inProgress, rawInput: {'command': 'npm run dev'});
      TranscriptItem at(String text) => TranscriptTool(call.copyWith(output: ToolOutput(text: text)));
      expect(_keys([at('starting\n')]), isEmpty);
      expect(_keys([at(_vite)]), ['localhost:5173']);
      expect(_keys([at('$_vite${'GET / 200\n' * 500}')]), ['localhost:5173']);
    });

    test('sameMadeAssets compares what the rows show, not the list that holds them', () {
      final a = madeAssetsOf([_say('http://localhost:3000/'), _run('ls', output: 'a\n')]);
      final b = madeAssetsOf([_say('http://localhost:3000/'), _run('ls', output: 'a\nb\n')]);
      expect(identical(a, b), isFalse);
      expect(sameMadeAssets(a, b), isTrue);
      expect(sameMadeAssets(a, madeAssetsOf([_say('http://localhost:3000/health')])), isFalse);
    });
  });

  group('pictures and documents', () {
    TranscriptItem create(String path) => TranscriptTool(
          ToolCall(
            toolCallId: 't${_n++}',
            kind: ToolKind.edit,
            status: ToolStatus.completed,
            content: [ToolDiff(path: path, newText: '# x')],
          ),
        );

    TranscriptItem edit(String path) => TranscriptTool(
          ToolCall(
            toolCallId: 't${_n++}',
            kind: ToolKind.edit,
            status: ToolStatus.completed,
            content: [ToolDiff(path: path, oldText: 'a', newText: 'b')],
          ),
        );

    test('the kind comes from the name; svg is a page, source and data are nothing', () {
      expect(webAssetsKinds(['/a/x.png', '/a/x.JPG', '/a/x.svg', '/a/x.html', '/a/x.md', '/a/x.pdf', '/a/x.csv', '/a/x.dart', '/a/x.json', '/a/x.txt', '/a/x.log']), [
        MadeKind.picture,
        MadeKind.picture,
        MadeKind.page,
        MadeKind.page,
        MadeKind.doc,
        MadeKind.doc,
        MadeKind.doc,
      ]);
    });

    test('a document counts when the agent created it, not when it edited one', () {
      final items = [create('/w/docs/design.md'), edit('/w/README.md'), edit('/w/docs/old.pdf')];
      expect(_keys(items), ['/w/docs/design.md']);
    });

    test('a picture or document a command writes counts; one it only reads or downloads does not', () {
      final items = [
        _run('python plot.py --output out/chart.png', cwd: '/w'),
        _run('pandoc notes.md -o out/report.pdf', cwd: '/w'),
        _run('cat > docs/plan.md <<EOF\n# Plan\nEOF', cwd: '/w'),
        _run('grep -n x docs/old.md', cwd: '/w'),
        _run('curl -o logo.png https://example.com/logo.png', cwd: '/w'),
        _run('cp shots/a.png /tmp/keep/a.png', cwd: '/w'),
      ];
      expect(_keys(items), ['/tmp/keep/a.png', '/w/docs/plan.md', '/w/out/report.pdf', '/w/out/chart.png']);
    });

    test('a tool that says it saved a file is believed; a listing is not', () {
      final items = [
        _run('python shot.py', output: 'Saved screenshot to screenshots/checkout.png\nDone\n', cwd: '/w'),
        _run('ls screenshots', output: 'checkout.png\nother.png\n', cwd: '/w'),
        _run('git status', output: 'new file: docs/a.md\nwrote nothing\n', cwd: '/w'),
      ];
      expect(_keys(items), ['/w/screenshots/checkout.png']);
    });

    test('in the agent\'s words a picture or document needs a word of making; a page with a folder does not', () {
      final items = [
        _say('Please update docs/guide.md and look at screenshots/old.png.'),
        _say('I saved screenshots/new.png and created docs/summary.md.'),
        _say('Open reports/q3.html'),
      ];
      expect(_keys(items, cwd: '/w'), ['/w/reports/q3.html', '/w/docs/summary.md', '/w/screenshots/new.png']);
    });

    test('a removed picture or document leaves the list', () {
      final items = [create('/w/docs/a.md'), _run('rm /w/docs/a.md'), _run('python p.py -o /w/out.png'), _delete('/w/out.png')];
      expect(_keys(items), isEmpty);
    });

    test('a patch that leaves nothing behind removes the file, as Codex deletes one; an empty new file is no document', () {
      final items = [
        _patch('/w/a.html', newText: '<p>x</p>'),
        _patch('/w/docs/b.md', newText: '# b'),
        _patch('/w/a.html', oldText: '<p>x</p>', newText: ''),
        _patch('/w/docs/b.md', oldText: '# b', newText: ''),
        _patch('/w/docs/empty.md', newText: ''),
      ];
      expect(_keys(items), isEmpty);
      expect(_keys([_patch('/w/a.html', newText: '<p>x</p>'), _patch('/w/a.html', oldText: '<p>x</p>', newText: '<p>y</p>')]), ['/w/a.html']);
    });

    test('the kinds are told apart on the rows', () {
      final items = [create('/w/a.md'), _write('/w/p.html'), _run('python p.py -o /w/c.png'), _say('http://localhost:3000/')];
      expect([for (final a in madeAssetsOf(items, cwd: '/w')) a.kind], [MadeKind.server, MadeKind.picture, MadeKind.page, MadeKind.doc]);
    });
  });
}
