import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/models/remote_file.dart';
import 'package:herdr_mobile/data/models/web_bridge.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/files/file_viewer_screen.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import 'support/fake_fs.dart';
import 'support/fake_transport.dart';

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

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  late FakeTransport transport;
  late _Launcher launcher;
  late FakeFs fs;

  Future<void> open(WidgetTester tester, String path, String content) async {
    fs.addFile(path, content);
    final machine = MachineConnection(
      profile: MachineProfile(id: 'm', label: 'devbox', host: 'h', username: 'u'),
      api: HerdrApi(transport..fs = fs),
      backoff: (_) => const Duration(hours: 1),
      pollInterval: const Duration(hours: 1),
    );
    final stat = RemoteStat(path: path, kind: RemoteEntryKind.file, size: fs.nodes[path]!.bytes.length);
    await tester.pumpWidget(MaterialApp(theme: AppTheme.light(), home: FileViewerScreen(machine: machine, stat: stat)));
    await _settle(tester);
  }

  setUp(() {
    transport = FakeTransport();
    launcher = _Launcher();
    UrlLauncherPlatform.instance = launcher;
    fs = FakeFs();
  });

  testWidgets('an HTML file opens in the browser from its own folder', (tester) async {
    await open(tester, '/home/dev/report/My Page.html', '<h1>hi</h1>');

    await tester.tap(find.byTooltip('Open in browser'));
    await _settle(tester);

    expect(transport.webBridges.single, isA<StaticSite>().having((s) => s.root, 'root', '/home/dev/report'));
    final url = Uri.parse(launcher.opened.single);
    expect((url.host, url.port, url.path), ('localhost', transport.webInfo.port, '/__herdr/open'));
    expect(url.queryParameters['to'], '/My%20Page.html');
  });

  testWidgets('an SVG, which has no drawn view, gets the button in the body as well', (tester) async {
    await open(tester, '/home/dev/charts/chart.svg', '<svg xmlns="http://www.w3.org/2000/svg"/>');

    expect(find.text('Open in browser'), findsOneWidget);
    await tester.tap(find.text('Open in browser'));
    await _settle(tester);

    expect(launcher.opened, hasLength(1));
    expect(Uri.parse(launcher.opened.single).queryParameters['to'], '/chart.svg');
  });

  testWidgets('a file that is not a page offers no browser button', (tester) async {
    await open(tester, '/home/dev/notes.txt', 'plain');

    expect(find.byTooltip('Open in browser'), findsNothing);
    expect(find.text('Open in browser'), findsNothing);
  });

  testWidgets('a failure is said, and nothing is opened', (tester) async {
    transport.webFailure = const HerdrTransportException('Cannot open a local port: no free port');
    await open(tester, '/home/dev/report/index.html', '<h1>hi</h1>');

    await tester.tap(find.byTooltip('Open in browser'));
    await _settle(tester);

    expect(find.text("Couldn't open on this phone: cannot open a local port: no free port."), findsOneWidget);
    expect(launcher.opened, isEmpty);
  });

  testWidgets('two taps while the connection is made open one tab, not two', (tester) async {
    final gate = Completer<void>();
    transport.webGate = gate;
    await open(tester, '/home/dev/report/index.html', '<h1>hi</h1>');

    await tester.tap(find.byTooltip('Open in browser'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byTooltip('Open in browser'));
    await tester.pump(const Duration(milliseconds: 100));
    gate.complete();
    await _settle(tester);

    expect(transport.webBridges, hasLength(1));
    expect(launcher.opened, hasLength(1));
  });
}
