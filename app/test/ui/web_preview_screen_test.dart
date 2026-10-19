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
import 'package:webview_flutter/webview_flutter.dart' show WebViewWidget;

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

  testWidgets('the bar names the page by its address on the machine, then by its title, and says each once', (tester) async {
    web.titles['http://localhost:51111/'] = 'Web test';
    final gate = transport.webGate = Completer();
    await pump(tester, ServerPage(Uri.parse('http://localhost:3000/')));

    expect(find.text('localhost:3000'), findsOneWidget, reason: 'the machine\'s port, not the phone\'s 51111');
    expect(find.text('build-box'), findsOneWidget, reason: 'the title is the address: the pill keeps the machine alone');

    gate.complete();
    await _settle(tester);
    expect(find.text('Web test'), findsOneWidget);
    expect(find.text('localhost:3000 · build-box'), findsOneWidget);
    expect(web.javaScript, isTrue, reason: 'dev pages need it');
  });

  testWidgets('reading down folds the bar away, a scroll up or the top brings it back, never under a finger', (tester) async {
    await pump(tester, ServerPage(Uri.parse('http://localhost:3000/')));
    double pageTop() => tester.getTopLeft(find.byType(WebViewWidget)).dy;
    final withBar = pageTop();
    final dpr = tester.view.devicePixelRatio;

    // Device pixels, as Android reports them: 10 dp, then 200 dp down.
    web.scrollTo(10 * dpr);
    web.scrollTo(200 * dpr);
    await _settle(tester);
    expect(pageTop(), lessThan(withBar), reason: 'the page gets the bar\'s height while it is read');

    web.scrollTo(170 * dpr);
    await _settle(tester);
    expect(pageTop(), withBar, reason: 'a scroll up brings the bar back');

    // A finger on the page: the bar waits until it lifts.
    final finger = await tester.startGesture(tester.getCenter(find.byType(WebViewWidget)));
    web.scrollTo(400 * dpr);
    await _settle(tester);
    expect(pageTop(), withBar, reason: 'nothing moves under a finger');
    await finger.up();
    await _settle(tester);
    expect(pageTop(), lessThan(withBar));

    web.scrollTo(0);
    await _settle(tester);
    expect(pageTop(), withBar, reason: 'the top of the page shows the bar');
  });

  testWidgets('Back goes back in the page first, then leaves, never through the entry page', (tester) async {
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
    expect(find.byType(WebPreviewScreen), findsNothing, reason: 'the first page has nothing behind it');
    expect(web.current, 'http://localhost:51111/', reason: 'the view never went back to the entry page ("Opening…")');
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('a page that fails to load says what happened, once, and Retry opens it again', (tester) async {
    web.failing.add('http://localhost:51111/page2.html');
    await pump(tester, ServerPage(Uri.parse('http://localhost:3000/')));
    await web.navigate('http://localhost:51111/page2.html');
    await _settle(tester);

    expect(find.text('Couldn’t load this page'), findsOneWidget, reason: 'the bar already names it');
    expect(find.textContaining('Retry opens it again'), findsOneWidget);
    final asked = transport.webBridges.length;

    web.failing.clear();
    await tester.tap(find.text('Retry'));
    await _settle(tester);
    expect(transport.webBridges, hasLength(asked + 1), reason: 'the listener is asked for again');
    expect(web.loaded.last.toString(), 'http://localhost:51111/page2.html', reason: 'back at the page that failed');
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets('a load error the machine caused is said in plain words, never as a Chromium code alone', (tester) async {
    await pump(tester, ServerPage(Uri.parse('http://localhost:3000/')));
    web.failWith('http://localhost:51111/x', 'net::ERR_EMPTY_RESPONSE');
    await web.navigate('http://localhost:51111/x');
    await _settle(tester);
    expect(find.textContaining('closed the connection without an answer'), findsOneWidget);
    expect(find.textContaining('net::'), findsNothing);
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

  testWidgets('a page of the web opens nowhere by itself: the person is told, and Open takes it to the browser', (tester) async {
    await pump(tester, ServerPage(Uri.parse('http://localhost:3000/')));
    final before = web.loaded.length;

    // What a script can do with no tap: `location=`, `window.open`, a refresh.
    expect(await web.navigate('https://accounts.google.com/o/oauth2/v2/auth?client_id=x'), isFalse);
    await _settle(tester);
    expect(launcher.opened, isEmpty, reason: 'a page must never push herdr behind the browser');
    expect(web.loaded, hasLength(before), reason: 'nothing from the web loads inside herdr');
    expect(find.text('accounts.google.com isn’t from build-box.'), findsOneWidget);

    await tester.tap(find.text('Open'));
    await _settle(tester);
    expect(launcher.opened, ['https://accounts.google.com/o/oauth2/v2/auth?client_id=x']);
    expect(launcher.modes, [PreferredLaunchMode.inAppBrowserView]);
    expect(web.current, 'http://localhost:51111/');
  });

  testWidgets('plain http of the web goes through the link sheet, which shows the address first', (tester) async {
    await pump(tester, ServerPage(Uri.parse('http://localhost:3000/')));
    await web.navigate('http://example.org/a');
    await _settle(tester);
    await tester.tap(find.text('Open'));
    await _settle(tester);
    expect(launcher.opened, isEmpty);
    expect(find.text('http://example.org/a'), findsOneWidget);
    expect(find.text('This link is not encrypted.'), findsOneWidget);
  });

  testWidgets('a page posted to another site says it is not from the machine, and copies its own address', (tester) async {
    await pump(tester, ServerPage(Uri.parse('http://localhost:3000/')));
    web.titles['https://evil.example.com/login'] = 'Sign in';
    web.land('https://evil.example.com/login');
    await _settle(tester);

    expect(find.text('evil.example.com · not from build-box'), findsOneWidget);
    expect(
      find.descendant(of: find.byType(AppTopBar), matching: find.textContaining('localhost:3000')),
      findsNothing,
      reason: 'never the machine\'s address over another site',
    );

    await tester.tap(find.byTooltip('Page options'));
    await _settle(tester);
    await tester.tap(find.text('Copy link'));
    await _settle(tester);
    expect(copied, ['https://evil.example.com/login']);
  });

  testWidgets('another port of the machine is not loaded on its own, is one deliberate tap away, and Back returns', (tester) async {
    await pump(tester, ServerPage(Uri.parse('http://localhost:3000/')));

    expect(await web.navigate('http://localhost:8791/api'), isFalse);
    await _settle(tester);
    expect(launcher.opened, isEmpty, reason: 'the phone\'s own localhost is not the machine\'s');
    expect(find.text('localhost:8791 isn’t open on this phone.'), findsOneWidget);

    transport.webInfo = const WebBridgeInfo(port: 8791, token: _token, entryPort: 51999);
    web.pagePort = 8791;
    await tester.tap(find.text('Open'));
    await _settle(tester);
    expect(transport.webBridges.last, isA<PortForward>().having((f) => f.port, 'port', 8791));
    expect(web.current, 'http://localhost:8791/api');

    await tester.tap(find.byTooltip('Back'));
    await _settle(tester);
    expect(web.current, 'http://localhost:51111/', reason: 'past the second entry page, to the page that linked it');
    expect(find.byType(WebPreviewScreen), findsOneWidget);
  });

  testWidgets('a file link is refused once, said, and never loops', (tester) async {
    await pump(tester, ServerPage(Uri.parse('http://localhost:3000/')));
    web.downloads.add('http://localhost:51111/report.zip');
    await web.navigate('http://localhost:51111/report.zip');
    await _settle(tester);
    expect(web.asked.where((u) => u.endsWith('report.zip')), hasLength(2), reason: 'Android asks again for a file; the second is refused');
    expect(find.textContaining('herdr doesn’t download files'), findsOneWidget);
  });

  testWidgets('a single-page app\'s route gets its title once the app has set it', (tester) async {
    web.titles['http://localhost:51111/'] = 'Dashboard';
    await pump(tester, ServerPage(Uri.parse('http://localhost:3000/')));
    web.pushState('http://localhost:51111/settings');
    await tester.pump();
    web.titles['http://localhost:51111/settings'] = 'Settings'; // set after the route rendered
    await tester.pump(Dwell.titleSettle);
    await _settle(tester);
    expect(find.text('Settings'), findsOneWidget);
  });

  testWidgets('a dropped connection is said, and the page opens again by itself when it is back', (tester) async {
    machine.start();
    await _settle(tester);
    expect(machine.isLive, isTrue, reason: 'set-up');
    await pump(tester, ServerPage(Uri.parse('http://localhost:3000/')));
    final asked = transport.webBridges.length;

    machine.suspend(); // what the 90 s rule does when Android froze herdr
    await _settle(tester);
    expect(find.text('Lost the connection to build-box'), findsOneWidget);

    machine.reconnect();
    await _settle(tester);
    expect(find.text('Lost the connection to build-box'), findsNothing);
    expect(transport.webBridges, hasLength(asked + 1), reason: 'opened again, without a tap');
    expect(web.current, 'http://localhost:51111/');
    machine.dispose();
  });

  testWidgets('the connection is held while the screen is open, named for the notice, and let go when it closes', (tester) async {
    await pump(tester, ServerPage(Uri.parse('http://localhost:3000/')));
    expect(fleet.held, isTrue);
    expect(fleet.heldPages, ['localhost:3000 on build-box']);

    Navigator.of(tester.element(find.byType(WebPreviewScreen))).pop();
    await _settle(tester);
    expect(fleet.held, isFalse);
  });

  testWidgets('cookies, web storage and the cache are cleared before the first page and when the last screen closes', (tester) async {
    await pump(tester, ServerPage(Uri.parse('http://localhost:3000/')));
    expect((web.cookiesCleared, web.storageCleared, web.cacheCleared), (1, 1, 1));

    Navigator.of(tester.element(find.byType(WebPreviewScreen))).pop();
    await _settle(tester);
    expect((web.cookiesCleared, web.storageCleared, web.cacheCleared), (2, 2, 2));
  });

  testWidgets('a page loading draws the hairline as far as it has got, and it is plain again when the page is in', (tester) async {
    await pump(tester, ServerPage(Uri.parse('http://localhost:3000/')));
    final accent = AppTheme.light().extension<Ds>()!.accent;
    Finder bar() => find.byWidgetPredicate((w) => w is ColoredBox && w.color == accent);

    web.startLoading('http://localhost:51111/page2.html', 40);
    await _settle(tester);
    final width = tester.getSize(find.byType(WebPreviewScreen)).width;
    final size = tester.getSize(bar());
    expect(size.height, greaterThan(0));
    expect(size.width, closeTo(width * 0.4, 1));

    await web.navigate('http://localhost:51111/page2.html');
    await _settle(tester);
    expect(bar(), findsNothing);
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

  testWidgets('the page sits above the gesture bar', (tester) async {
    tester.view.padding = const FakeViewPadding(bottom: 48);
    addTearDown(tester.view.reset);
    await pump(tester, ServerPage(Uri.parse('http://localhost:3000/')));
    final page = tester.getRect(find.byType(WebViewWidget));
    final screen = tester.getRect(find.byType(WebPreviewScreen));
    expect(screen.bottom - page.bottom, closeTo(48 / tester.view.devicePixelRatio, 0.5));
  });
}
