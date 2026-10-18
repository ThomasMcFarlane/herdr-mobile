import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/remote_file.dart';
import 'package:herdr_mobile/data/models/web_bridge.dart';
import 'package:herdr_mobile/data/repositories/fleet_repository.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/features/files/file_viewer_screen.dart';
import 'package:herdr_mobile/ui/features/web/web_preview_screen.dart';

import 'support/fake_fs.dart';
import 'support/fake_transport.dart';
import 'support/fake_webview.dart';

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  late FakeTransport transport;
  late FakeWebView web;
  late FakeFs fs;
  late FleetRepository fleet;

  Future<void> open(WidgetTester tester, String path, String content) async {
    fs.addFile(path, content);
    final machine = pageMachine(transport..fs = fs, label: 'devbox');
    final stat = RemoteStat(path: path, kind: RemoteEntryKind.file, size: fs.nodes[path]!.bytes.length);
    await tester.pumpWidget(
      withFleet(fleet, MaterialApp(theme: AppTheme.light(), home: FileViewerScreen(machine: machine, stat: stat))),
    );
    await _settle(tester);
  }

  setUp(() {
    transport = FakeTransport();
    web = FakeWebView.install();
    fs = FakeFs();
    fleet = emptyFleet();
    addTearDown(fleet.dispose);
  });

  testWidgets('an HTML file is shown as a page in herdr, served from its own folder', (tester) async {
    await open(tester, '/home/dev/report/My Page.html', '<h1>hi</h1>');

    await tester.tap(find.byTooltip('Show as page'));
    await _settle(tester);

    expect(find.byType(WebPreviewScreen), findsOneWidget);
    expect(transport.webBridges.single, isA<StaticSite>().having((s) => s.root, 'root', '/home/dev/report'));
    final entry = web.loaded.first;
    expect((entry.host, entry.port, entry.path), ('localhost', transport.webInfo.port, '/__herdr/open'));
    expect(entry.queryParameters['to'], '/My%20Page.html');
  });

  testWidgets('an SVG, which has no drawn view, gets the button in the body as well', (tester) async {
    await open(tester, '/home/dev/charts/chart.svg', '<svg xmlns="http://www.w3.org/2000/svg"/>');

    expect(find.text('Show as page'), findsOneWidget);
    await tester.tap(find.text('Show as page'));
    await _settle(tester);

    expect(web.loaded.first.queryParameters['to'], '/chart.svg');
  });

  testWidgets('a file that is not a page offers no page button', (tester) async {
    await open(tester, '/home/dev/notes.txt', 'plain');

    expect(find.byTooltip('Show as page'), findsNothing);
    expect(find.text('Show as page'), findsNothing);
  });

  testWidgets('a failure is said on the page\'s screen, with Retry, and nothing is loaded', (tester) async {
    transport.webFailure = const HerdrTransportException('Cannot open a local port: no free port');
    await open(tester, '/home/dev/report/index.html', '<h1>hi</h1>');

    await tester.tap(find.byTooltip('Show as page'));
    await _settle(tester);

    expect(find.text('Cannot open a local port: no free port.'), findsOneWidget);
    expect(web.loaded, isEmpty);

    transport.webFailure = null;
    await tester.tap(find.text('Retry'));
    await _settle(tester);
    expect(web.loaded, isNotEmpty);
    expect(find.text('Retry'), findsNothing);
  });
}
