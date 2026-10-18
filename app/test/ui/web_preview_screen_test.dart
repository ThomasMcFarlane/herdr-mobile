// A page from a machine shown in herdr: what the bar says, Back through the
// page's history, a failed load, Copy link, where other links go, and the
// hold on the connection while the screen is up.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/web_bridge.dart';
import 'package:herdr_mobile/data/repositories/fleet_repository.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/features/web/web_preview_screen.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import '../support/fake_fs.dart';
import '../support/fake_transport.dart';
import '../support/fake_webview.dart';

class _Launcher extends UrlLauncherPlatform {
  final opened = <String>[];
  final modes = <PreferredLaunchMode>[];

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    opened.add(url);
    modes.add(options.mode);
    return true;
  }
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

const _token = '0123456789abcdef0123456789abcdef';

void main() {
  late FakeTransport transport;
  late FakeWebView web;
  late _Launcher launcher;
  late FleetRepository fleet;
  late MachineConnection machine;
  late List<String> copied;

  setUp(() {
    // The dev server is on 3000 on the machine; the phone's listener got 51111.
    transport = FakeTransport()..webInfo = const WebBridgeInfo(port: 51111, token: _token, entryPort: 51999);
    web = FakeWebView.install(pagePort: 51111);
    launcher = _Launcher();
    UrlLauncherPlatform.instance = launcher;
    fleet = emptyFleet();
    addTearDown(fleet.dispose);
    machine = pageMachine(transport);
    copied = [];
  });

  /// A home screen with a button that opens [page], as the callers do.
  Future<void> pump(WidgetTester tester, WebPage page) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(
      withFleet(
        fleet,
        MaterialApp(
          theme: AppTheme.light(),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => openWebPreview(context, machine, page),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await _settle(tester);
  }

  testWidgets('the bar names the page by its address on the machine, then by its title', (tester) async {
    web.titles['http://localhost:51111/'] = 'Web test';
    final gate = transport.webGate = Completer();
    await pump(tester, ServerPage(Uri.parse('http://localhost:3000/')));

    expect(find.text('localhost:3000'), findsOneWidget, reason: 'the machine\'s port, not the phone\'s 51111');
    expect(find.text('localhost:3000 · build-box'), findsOneWidget);

    gate.complete();
    await _settle(tester);
    expect(find.text('Web test'), findsOneWidget);
    expect(find.text('localhost:3000 · build-box'), findsOneWidget);
    expect(web.javaScript, isTrue, reason: 'dev pages need it');
  });

  testWidgets('Back goes back in the page first, then leaves; the entry page is never a step', (tester) async {
    await pump(tester, ServerPage(Uri.parse('http://localhost:3000/')));
    expect(web.current, 'http://localhost:51111/');

    await web.navigate('http://localhost:51111/page2.html');
    await _settle(tester);
    expect(web.current, 'http://localhost:51111/page2.html');

    await tester.tap(find.byTooltip('Back'));
    await _settle(tester);
    expect(find.byType(WebPreviewScreen), findsOneWidget);
    expect(web.current, 'http://localhost:51111/');

    await tester.tap(find.byTooltip('Back'));
    await _settle(tester);
    expect(find.byType(WebPreviewScreen), findsNothing, reason: 'past the entry page, out of the screen');
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('a page that fails to load says what happened and Retry opens it again', (tester) async {
    web.failing.add('http://localhost:51111/page2.html');
    await pump(tester, ServerPage(Uri.parse('http://localhost:3000/')));
    await web.navigate('http://localhost:51111/page2.html');
    await _settle(tester);

    expect(find.text('Couldn’t load localhost:3000/page2.html'), findsOneWidget);
    expect(find.textContaining('Retry opens it again'), findsOneWidget);
    final asked = transport.webBridges.length;

    web.failing.clear();
    await tester.tap(find.text('Retry'));
    await _settle(tester);
    expect(transport.webBridges, hasLength(asked + 1), reason: 'the listener is asked for again');
    expect(web.loaded.last.toString(), 'http://localhost:51111/page2.html', reason: 'back at the page that failed');
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets('Copy link copies the page\'s address on the machine, never the phone\'s tokened URL', (tester) async {
    await pump(tester, ServerPage(Uri.parse('http://localhost:3000/')));
    await web.navigate('http://localhost:51111/page2.html#b');
    await _settle(tester);

    await tester.tap(find.byTooltip('Page options'));
    await _settle(tester);
    await tester.tap(find.text('Copy link'));
    await _settle(tester);

    expect(copied, ['http://localhost:3000/page2.html#b']);
    expect(copied.single, isNot(contains(_token)));
  });

  testWidgets('a file\'s page copies its path on the machine', (tester) async {
    transport.webInfo = const WebBridgeInfo(port: 51111, token: _token);
    transport.fs = FakeFs()..addFile('/home/dev/site/index.html', '<h1>hi</h1>');
    await pump(tester, const FilePage('/home/dev/site/index.html'));
    expect(find.text('index.html'), findsWidgets);

    await tester.tap(find.byTooltip('Page options'));
    await _settle(tester);
    await tester.tap(find.text('Copy path'));
    await _settle(tester);
    expect(copied, ['/home/dev/site/index.html']);
  });

  testWidgets('a link to the web goes to the phone\'s browser, a sign-in redirect too, and the page stays', (tester) async {
    await pump(tester, ServerPage(Uri.parse('http://localhost:3000/')));
    final before = web.loaded.length;

    expect(await web.navigate('https://accounts.google.com/o/oauth2/v2/auth?client_id=x'), isFalse);
    expect(await web.navigate('https://login.tailscale.com/a/l3503a0535f1bf'), isFalse);
    await _settle(tester);

    expect(launcher.opened, ['https://accounts.google.com/o/oauth2/v2/auth?client_id=x', 'https://login.tailscale.com/a/l3503a0535f1bf']);
    expect(launcher.modes, everyElement(PreferredLaunchMode.inAppBrowserView));
    expect(web.loaded, hasLength(before), reason: 'nothing from the web loads inside herdr');
    expect(web.current, 'http://localhost:51111/');
  });

  testWidgets('another port of the machine is not loaded on its own, and is one deliberate tap away', (tester) async {
    await pump(tester, ServerPage(Uri.parse('http://localhost:3000/')));

    expect(await web.navigate('http://localhost:8791/api'), isFalse);
    await _settle(tester);
    expect(launcher.opened, isEmpty, reason: 'the phone\'s own localhost is not the machine\'s');
    expect(find.text('localhost:8791 isn’t open on this phone.'), findsOneWidget);

    transport.webInfo = const WebBridgeInfo(port: 8791, token: _token, entryPort: 51999);
    await tester.tap(find.text('Open'));
    await _settle(tester);
    expect(transport.webBridges.last, isA<PortForward>().having((f) => f.port, 'port', 8791));
    expect(web.loaded.any((u) => u.path == '/__herdr/open' && u.queryParameters['to'] == '/api'), isTrue);
  });

  testWidgets('the connection is held up while the screen is open, and let go when it closes', (tester) async {
    await pump(tester, ServerPage(Uri.parse('http://localhost:3000/')));
    expect(fleet.held, isTrue);
    expect(fleet.keepAliveInBackground, isTrue);

    Navigator.of(tester.element(find.byType(WebPreviewScreen))).pop();
    await _settle(tester);
    expect(fleet.held, isFalse);
    expect(fleet.keepAliveInBackground, isFalse);
  });

  testWidgets('while nothing is shown the view is the screen\'s colour; a page gets the web\'s white', (tester) async {
    final gate = transport.webGate = Completer();
    await pump(tester, ServerPage(Uri.parse('http://localhost:3000/')));
    expect(web.backgrounds, isNotEmpty);
    expect(web.backgrounds, everyElement(AppTheme.light().extension<Ds>()!.bg), reason: 'no white before a page is in');

    gate.complete();
    await _settle(tester);
    expect(web.backgrounds.last, const Color(0xFFFFFFFF));
  });
}
