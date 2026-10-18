import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/background/background_work.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/models/web_bridge.dart';
import 'package:herdr_mobile/data/observed/observed_contracts.dart' show SubagentInfo;
import 'package:herdr_mobile/data/repositories/agent_session.dart' show AgentLink, SubagentEntry, SubagentState;
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/agent_session/session_bar.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import '../support/fake_agent_session.dart';
import '../support/fake_fs.dart';
import '../support/fake_transport.dart';

class _Launcher extends UrlLauncherPlatform {
  final opened = <String>[];

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    opened.add(url);
    return true;
  }
}

TranscriptItem _say(String text) => TranscriptMessage(key: 'm$text', role: MessageRole.agent, blocks: [TextBlock(text)]);

TranscriptItem _wrote(String path) => TranscriptTool(
      ToolCall(
        toolCallId: 't$path',
        kind: ToolKind.edit,
        status: ToolStatus.completed,
        content: [ToolDiff(path: path, newText: '<h1>x</h1>')],
      ),
    );

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  late FakeTransport transport;
  late FakeFs fs;
  late _Launcher launcher;

  FakeAgentSession session(List<TranscriptItem> items) {
    final machine = MachineConnection(
      profile: const MachineProfile(id: 'm', label: 'devbox', host: 'h', username: 'u'),
      api: HerdrApi(transport..fs = fs),
      backoff: (_) => const Duration(hours: 1),
      pollInterval: const Duration(hours: 1),
    );
    return FakeAgentSession(state: AgentSessionState('s', items: items), machine: machine);
  }

  Future<void> pumpBar(WidgetTester tester, FakeAgentSession s) async {
    tester.view.physicalSize = const Size(412, 892) * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: AppTheme.light(), home: Scaffold(body: SessionBar(session: s))));
    await _settle(tester);
  }

  setUp(() {
    transport = FakeTransport();
    fs = FakeFs()..addFile('/home/dev/payments-api/reports/q3.html', '<h1>q3</h1>');
    launcher = _Launcher();
    UrlLauncherPlatform.instance = launcher;
  });

  testWidgets('a session that has put nothing on the web has no chip', (tester) async {
    await pumpBar(tester, session([_say('Refactored the ledger, no pages.')]));
    expect(find.text('Web'), findsNothing);
  });

  testWidgets('the chip counts what the transcript holds, and a new link appears in it', (tester) async {
    final s = session([_say('Serving http://localhost:5173/'), _wrote('/home/dev/payments-api/reports/q3.html')]);
    await pumpBar(tester, s);
    expect(find.text('Web'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);

    s.update((st) => AgentSessionState('s', items: [...st.items, _say('and http://localhost:8000/docs')]));
    await _settle(tester);
    expect(find.text('3'), findsOneWidget);
  });

  testWidgets('the sheet lists them newest first; a server says only what is known', (tester) async {
    final s = session([
      _say('Serving http://localhost:5173/'),
      _say('API on http://localhost:8000/docs'),
      _wrote('/home/dev/payments-api/reports/q3.html'),
    ]);
    s.setBackground(
      BackgroundWork(
        tasks: [
          const BackgroundTask(id: 'bg1', kind: BackgroundKind.shell, status: BackgroundStatus.running, title: 'vite --port 5173'),
          const BackgroundTask(id: 'bg2', kind: BackgroundKind.shell, status: BackgroundStatus.finished, title: 'uvicorn app:app --port 8000'),
        ],
      ),
    );
    await pumpBar(tester, s);
    await tester.tap(find.text('Web'));
    await _settle(tester);

    expect(find.text('Web in this session'), findsOneWidget);
    final titles = ['q3.html', 'localhost:8000/docs', 'localhost:5173'];
    final ys = [for (final t in titles) tester.getTopLeft(find.text(t)).dy];
    expect(ys, orderedEquals([...ys]..sort()), reason: 'newest first');
    expect(find.text('Running'), findsOneWidget);
    expect(find.textContaining('Stopped'), findsOneWidget);
    expect(find.text('reports/'), findsOneWidget);
  });

  testWidgets('a server opens on the phone through the connection, a page from its own folder', (tester) async {
    final s = session([_say('Serving http://localhost:5173/app'), _wrote('/home/dev/payments-api/reports/q3.html')]);
    await pumpBar(tester, s);

    await tester.tap(find.text('Web'));
    await _settle(tester);
    await tester.tap(find.text('localhost:5173/app'));
    await _settle(tester);
    expect(find.text('Web in this session'), findsNothing, reason: 'the sheet goes first');
    expect(transport.webBridges.single, isA<PortForward>().having((p) => p.port, 'port', 5173));
    expect(Uri.parse(launcher.opened.single).queryParameters['to'], '/app');

    await tester.tap(find.text('Web'));
    await _settle(tester);
    await tester.tap(find.text('q3.html'));
    await _settle(tester);
    expect(transport.webBridges.last, isA<StaticSite>().having((p) => p.root, 'root', '/home/dev/payments-api/reports'));
    expect(Uri.parse(launcher.opened.last).queryParameters['to'], '/q3.html');
  });

  testWidgets('a page the agent named that is not on the machine says so', (tester) async {
    final s = session([_say('I wrote reports/gone.html for you.')]);
    await pumpBar(tester, s);
    await tester.tap(find.text('Web'));
    await _settle(tester);

    await tester.tap(find.text('gone.html'));
    await _settle(tester);

    expect(find.text('gone.html is not on the machine any more.'), findsOneWidget);
    expect(launcher.opened, isEmpty);
  });

  BackgroundWork runningVite() => BackgroundWork(
        tasks: const [BackgroundTask(id: 'bg1', kind: BackgroundKind.shell, status: BackgroundStatus.running, title: 'vite --port 5173')],
      );

  testWidgets('a saved copy or a link that is down does not claim anything runs', (tester) async {
    final s = session([_say('Serving http://localhost:5173/')]);
    s.setBackground(runningVite());
    await pumpBar(tester, s);
    await tester.tap(find.text('Web'));
    await _settle(tester);
    expect(find.text('Running'), findsOneWidget);

    s.setSavedCopy(DateTime(2026, 5, 20, 6, 31));
    await _settle(tester);
    expect(find.text('Running'), findsNothing);
    expect(find.text('Seen'), findsOneWidget);

    s.setSavedCopy(null);
    s.setLink(AgentLink.reconnecting);
    await _settle(tester);
    expect(find.text('Running'), findsNothing);
  });

  testWidgets('rows do not move while the sheet is open; a link that arrives is there the next time', (tester) async {
    final s = session([_say('Serving http://localhost:5173/'), _say('API http://localhost:8000/docs')]);
    await pumpBar(tester, s);
    await tester.tap(find.text('Web'));
    await _settle(tester);
    final before = tester.getTopLeft(find.text('localhost:5173')).dy;

    s.update((st) => AgentSessionState('s', items: [...st.items, _say('Storybook http://localhost:6006/'), _say('again http://localhost:5173/x')]));
    await _settle(tester);

    expect(tester.getTopLeft(find.text('localhost:5173/x')).dy, before, reason: 'same row, same place, newest path');
    expect(find.text('localhost:6006'), findsNothing);

    await tester.tapAt(const Offset(200, 20));
    await _settle(tester);
    await tester.tap(find.text('Web'));
    await _settle(tester);
    expect(find.text('localhost:6006'), findsOneWidget);
    expect(tester.getTopLeft(find.text('localhost:5173/x')).dy, lessThan(tester.getTopLeft(find.text('localhost:6006')).dy), reason: 'newest first again');
  });

  testWidgets('a port that is not a web server is not opened from the list, and says why', (tester) async {
    final s = session([_say('The database is on http://localhost:5432/ and Docker on localhost:2375')]);
    await pumpBar(tester, s);
    await tester.tap(find.text('Web'));
    await _settle(tester);
    expect(find.text('PostgreSQL, not a web page'), findsOneWidget);

    await tester.tap(find.text('localhost:5432'));
    await _settle(tester);

    expect(transport.webBridges, isEmpty);
    expect(launcher.opened, isEmpty);
    expect(find.textContaining('That is a PostgreSQL port'), findsOneWidget);
  });

  testWidgets('a page on a machine without files is dimmed with its reason, not a surprise after the tap', (tester) async {
    fs = FakeFs();
    final s = session([_wrote('/home/dev/payments-api/reports/q3.html')]);
    transport.fs = null;
    await pumpBar(tester, s);
    await tester.tap(find.text('Web'));
    await _settle(tester);
    expect(find.text('Files are not available on this machine'), findsOneWidget);
  });

  testWidgets('a tap says it is opening, and a second tap while it connects opens nothing more', (tester) async {
    final s = session([_say('Serving http://localhost:5173/')]);
    await pumpBar(tester, s);
    await tester.tap(find.text('Web'));
    await _settle(tester);
    final gate = Completer<void>();
    transport.webGate = gate;
    await tester.tap(find.text('localhost:5173'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Opening localhost:5173…'), findsOneWidget);

    // A second tap on the same row, from a reopened sheet, while it connects.
    await tester.tap(find.text('Web'));
    await _settle(tester);
    await tester.tap(find.text('localhost:5173'));
    await _settle(tester);
    expect(transport.webBridges, hasLength(1));

    gate.complete();
    await _settle(tester);
    expect(launcher.opened, hasLength(1));
  });

  testWidgets('a person who tapped a row and went back is not sent to a browser seconds later', (tester) async {
    final s = session([_say('Serving http://localhost:5173/')]);
    final gate = Completer<void>();
    transport.webGate = gate;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Column(
              children: [
                SessionBar(session: s),
                TextButton(onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('board')))), child: const Text('go')),
              ],
            ),
          ),
        ),
      ),
    );
    tester.view.physicalSize = const Size(412, 892) * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await _settle(tester);
    await tester.tap(find.text('Web'));
    await _settle(tester);
    await tester.tap(find.text('localhost:5173'));
    await tester.pump();

    // The screen the sheet came from goes away while the connection is made.
    await tester.pumpWidget(MaterialApp(theme: AppTheme.light(), home: const Scaffold(body: Text('board'))));
    gate.complete();
    await _settle(tester);

    expect(launcher.opened, isEmpty);
  });

  testWidgets('a name that hides itself is shown with its characters made visible', (tester) async {
    final s = session([_wrote('/home/dev/payments-api/safe\u202Egpj.html')]);
    await pumpBar(tester, s);
    await tester.tap(find.text('Web'));
    await _settle(tester);
    expect(find.textContaining('\u202E'), findsNothing);
    expect(find.textContaining('U+202E'), findsOneWidget);
  });

  testWidgets('beside the subagents chip on a small phone, the Web chip wraps under it instead of shrinking it', (tester) async {
    final s = session([_say('Serving http://localhost:5173/')])
      ..observed = true
      ..roster = const [
        SubagentEntry(info: SubagentInfo(name: 'PongReply'), state: SubagentState.running),
        SubagentEntry(info: SubagentInfo(name: 'Other'), state: SubagentState.finished),
      ];
    tester.view.physicalSize = const Size(320, 640) * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.6)), child: child!),
        home: Scaffold(body: SessionBar(session: s)),
      ),
    );
    await _settle(tester);

    expect(tester.takeException(), isNull);
    final subagents = tester.getRect(find.text('1 of 2 running'));
    final web = tester.getRect(find.text('Web'));
    expect(web.right, lessThanOrEqualTo(320));
    expect(subagents.width, greaterThan(100), reason: 'its words are whole');
    expect(find.text('1 of 2 running'), findsOneWidget);
    expect(web.top >= subagents.bottom - 1 || web.left >= subagents.right, isTrue, reason: 'beside it or under it, never over it');
  });
}
