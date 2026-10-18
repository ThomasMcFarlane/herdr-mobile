// Renders what opens pages on the phone to PNGs for review: the link sheet for
// an address on the machine (long machine name, long address), for an https one
// on the machine, with no machine and for a public one, and the file viewer for
// an HTML file (the globe in the header) and an SVG (Open in browser above
// View as text), and the session's Web sheet (chip in the bar, servers and
// pages newest first). Light and dark at 412x892, and 320x640 at 1.6 text scale. Off
// by default; it writes files:
//
//   WEB_SHOTS=1 flutter test test/ui/web_preview_shots_test.dart
//
// Output: $WEB_SHOTS_DIR (default /tmp/web_shots)/<case>-<light|dark>-<w>x<h>[-x1.6].png
@TestOn('vm')
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/background/background_work.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/models/remote_file.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/agent_session/session_bar.dart';
import 'package:herdr_mobile/ui/features/files/file_viewer_screen.dart';
import 'package:herdr_mobile/ui/features/pane/link_sheet.dart';

import '../support/fake_agent_session.dart';
import '../support/fake_fs.dart';
import '../support/fake_transport.dart';
import '../support/shot.dart' show loadAppFonts;

const _longMachine = 'Máy chủ phát triển của nhóm thanh toán (devbox-payments-eu-west-3)';

MachineConnection _machine(FakeFs fs, {String label = 'devbox'}) => MachineConnection(
      profile: MachineProfile(id: 'm', label: label, host: 'h', username: 'u'),
      api: HerdrApi(FakeTransport()..fs = fs),
      backoff: (_) => const Duration(hours: 1),
      pollInterval: const Duration(hours: 1),
    );

void main() {
  if (Platform.environment['WEB_SHOTS'] == null) {
    test('web shots are off (set WEB_SHOTS=1)', () {}, skip: 'set WEB_SHOTS=1 to render PNGs');
    return;
  }
  final out = Platform.environment['WEB_SHOTS_DIR'] ?? '/tmp/web_shots';

  setUpAll(() async {
    await loadAppFonts();
    Directory(out).createSync(recursive: true);
  });

  Future<void> shoot(
    WidgetTester tester,
    String name,
    Widget home,
    Size size,
    Brightness brightness, {
    double scale = 1,
    Future<void> Function()? then,
  }) async {
    const dpr = 2.625;
    tester.view.physicalSize = size * dpr;
    tester.view.devicePixelRatio = dpr;
    tester.view.padding = const FakeViewPadding(top: 24 * dpr, bottom: 20 * dpr);
    tester.view.viewPadding = tester.view.padding;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
          child: RepaintBoundary(key: key, child: child!),
        ),
        home: home,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await then?.call();
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final ui.Image image = await boundary.toImage(pixelRatio: 1.5);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final tag = '${size.width.toInt()}x${size.height.toInt()}${scale == 1 ? '' : '-x$scale'}';
      await File('$out/$name-${brightness.name}-$tag.png').writeAsBytes(data!.buffer.asUint8List());
    });
    expect(tester.takeException(), isNull, reason: '$name ${brightness.name} $size');
  }

  /// A page with a button standing in for the tapped link, then the sheet.
  Widget sheetHome(String url, MachineConnection? machine) => Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => showLinkSheet(context, url, machine: machine),
              child: const Text('tap the link'),
            ),
          ),
        ),
      );

  final longUrl = 'http://localhost:5173/reports/2026-q3/payments-reconciliation-dashboard/index.html?tenant=eu-west-3&range=last-90-days&compare=previous-period#anomalies';

  Future<void> openSheet(WidgetTester tester) async {
    await tester.tap(find.text('tap the link'));
    await tester.pump(const Duration(milliseconds: 100));
  }

  final sizes = <(Size, double)>[(const Size(412, 892), 1), (const Size(320, 640), 1.6)];
  final cases = <String, Widget Function()>{
    'sheet-machine-link': () => sheetHome(longUrl, _machine(FakeFs(), label: _longMachine)),
    'sheet-machine-short': () => sheetHome('http://localhost:3000', _machine(FakeFs())),
    'sheet-machine-https': () => sheetHome('https://localhost:8443/admin', _machine(FakeFs())),
    'sheet-no-machine': () => sheetHome('http://127.0.0.1:8080/app', null),
    'sheet-public': () => sheetHome('https://example.com/docs', _machine(FakeFs())),
  };

  for (final (size, scale) in sizes) {
    for (final b in Brightness.values) {
      for (final entry in cases.entries) {
        testWidgets('${entry.key} ${b.name} ${size.width.toInt()} x$scale', (tester) async {
          await shoot(tester, entry.key, entry.value(), size, b, scale: scale, then: () => openSheet(tester));
        });
      }

      testWidgets('viewer-html ${b.name} ${size.width.toInt()} x$scale', (tester) async {
        final fs = FakeFs()
          ..addFile('/home/dev/Báo cáo doanh thu quý ba/Tổng hợp thanh toán và đối soát chi tiết theo từng khu vực.html', '<h1>Báo cáo</h1>\n<p>x</p>\n' * 20);
        const path = '/home/dev/Báo cáo doanh thu quý ba/Tổng hợp thanh toán và đối soát chi tiết theo từng khu vực.html';
        final stat = RemoteStat(path: path, kind: RemoteEntryKind.file, size: fs.nodes[path]!.bytes.length);
        await shoot(tester, 'viewer-html', FileViewerScreen(machine: _machine(fs), stat: stat), size, b, scale: scale);
      });

      testWidgets('viewer-svg ${b.name} ${size.width.toInt()} x$scale', (tester) async {
        const path = '/home/dev/charts/chart.svg';
        final fs = FakeFs()..addFile(path, '<svg xmlns="http://www.w3.org/2000/svg" width="200" height="100"><rect width="200" height="100" fill="blue"/></svg>');
        final stat = RemoteStat(path: path, kind: RemoteEntryKind.file, size: fs.nodes[path]!.bytes.length);
        await shoot(tester, 'viewer-svg', FileViewerScreen(machine: _machine(fs), stat: stat), size, b, scale: scale);
      });
    }
  }

  // The session's Web sheet: realistic, mixed data (long and Vietnamese names,
  // a running server, a stopped one, one the phone only saw).
  FakeAgentSession webSession() {
    TranscriptItem say(String text) => TranscriptMessage(key: 'm${text.hashCode}', role: MessageRole.agent, blocks: [TextBlock(text)]);
    TranscriptItem wrote(String path) => TranscriptTool(
          ToolCall(
            toolCallId: 't$path',
            kind: ToolKind.edit,
            status: ToolStatus.completed,
            content: [ToolDiff(path: path, newText: '<h1>x</h1>')],
          ),
        );
    const base = '/home/dev/payments-api';
    final session = FakeAgentSession(
      state: AgentSessionState(
        's',
        items: [
          say('Serving http://localhost:5173/'),
          say('API docs on http://localhost:8000/docs'),
          wrote('$base/htmlcov/index.html'),
          wrote('$base/diagrams/architecture.svg'),
          say('Dashboard preview at http://localhost:4173/'),
          wrote('$base/reports/Báo cáo đối soát Q3 — bản cuối cùng.html'),
          wrote('$base/design/ui-kit.html'),
          say('Wrote slides.html and talk/notebook-export-with-a-very-long-name-for-the-quarterly-review.html'),
        ],
      ),
    );
    session.setBackground(
      BackgroundWork(
        tasks: const [
          BackgroundTask(id: 'bg1', kind: BackgroundKind.shell, status: BackgroundStatus.running, title: 'vite --port 5173'),
          BackgroundTask(id: 'bg2', kind: BackgroundKind.shell, status: BackgroundStatus.finished, title: 'uvicorn app:app --port 8000'),
        ],
      ),
    );
    return session;
  }

  for (final (size, scale) in sizes) {
    for (final b in Brightness.values) {
      testWidgets('web-sheet ${b.name} ${size.width.toInt()} x$scale', (tester) async {
        final session = webSession();
        await shoot(
          tester,
          'web-sheet',
          Scaffold(body: SessionBar(session: session)),
          size,
          b,
          scale: scale,
          then: () async {
            await tester.tap(find.text('Web'));
            await tester.pump(const Duration(milliseconds: 300));
          },
        );
      });
    }
  }
}
