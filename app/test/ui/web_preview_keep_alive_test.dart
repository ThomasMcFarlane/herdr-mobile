// The bug this screen fixes, end to end: a page opened from a terminal link
// must keep the machine's connection while the person is away from herdr.
// In a Custom Tab herdr went to the background, the fleet let the connection
// go after 90 s, and the page waited on "Opening…" forever.
//
// The real pieces: the fleet, the notifier that runs the Watching notice
// (with alerts off, as by default), the link sheet and the page screen; only
// Android (the notice, the WebView) is faked.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/attention_notifier.dart';
import 'package:herdr_mobile/data/repositories/attention_set.dart';
import 'package:herdr_mobile/data/repositories/fleet_repository.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/repositories/machine_repository.dart';
import 'package:herdr_mobile/data/repositories/notification_settings.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';
import 'package:herdr_mobile/data/services/notifier.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/features/pane/link_sheet.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import '../support/fake_network.dart';
import '../support/fake_notifier.dart';
import '../support/fake_transport.dart';
import '../support/fake_webview.dart';
import '../support/memory_stores.dart';

class _Launcher extends UrlLauncherPlatform {
  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async => true;
}

Future<void> _settle(WidgetTester tester, [int frames = 6]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// The app's pieces for one machine, `build-box`, alerts off.
class _App {
  _App(Notifier notifier) {
    machines = MachineRepository(profiles: MemoryProfileStore(), secrets: MemorySecretStore());
    fleet = FleetRepository(
      machines: machines,
      network: FakeNetwork(),
      connect: (profile, secrets) => MachineConnection(
        profile: profile,
        api: HerdrApi(transport),
        backoff: (_) => const Duration(hours: 1),
        pollInterval: const Duration(hours: 1),
      ),
    );
    settings = NotificationSettings(MemoryNotificationStore())..load();
    attentionSet = AttentionSet(fleet: fleet);
    attention = AttentionNotifier(fleet: fleet, attention: attentionSet, settings: settings, notifier: notifier);
  }

  final transport = FakeTransport();
  late final MachineRepository machines;
  late final FleetRepository fleet;
  late final NotificationSettings settings;
  late final AttentionSet attentionSet;
  late final AttentionNotifier attention;

  MachineConnection get connection => fleet.connection('m')!;

  Future<void> start(WidgetTester tester) async {
    await machines.save(
      const MachineProfile(id: 'm', label: 'build-box', host: 'h', username: 'u'),
      secrets: const MachineSecrets(password: 'x'),
    );
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: fleet,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => showLinkSheet(context, 'http://localhost:3000/', machine: connection),
                  child: const Text('link'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(connection.isLive, isTrue, reason: 'set-up');
  }

  /// The person taps a localhost link in the terminal and opens the page.
  Future<void> openPage(WidgetTester tester) async {
    await tester.tap(find.text('link'));
    await _settle(tester, 10);
    await tester.tap(find.text('Open page'));
    await _settle(tester);
    expect(find.text('Open page'), findsNothing, reason: 'the sheet closed: the page was asked for');
  }

  void life(AppLifecycleState state) {
    fleet.onLifecycleState(state);
    attention.onLifecycleState(state);
  }

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await attention.dispose();
    attentionSet.dispose();
    fleet.dispose(); // its connections' timers end with it
    settings.dispose();
    await tester.pump();
  }
}

void main() {
  setUp(() {
    UrlLauncherPlatform.instance = _Launcher();
    FakeWebView.install();
  });

  testWidgets('a page opened on the phone runs the Watching notice and keeps the connection past the 90 s away', (tester) async {
    final notifier = FakeNotifier();
    final app = _App(notifier);
    await app.start(tester);
    await app.openPage(tester);
    expect(notifier.pages.last, 'localhost:3000 on build-box', reason: 'started while the app is in front, naming the page');

    // The person switches to another app for two minutes.
    app.life(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 91));
    await tester.pump(const Duration(seconds: 30));
    expect(app.connection.isLive, isTrue, reason: 'the page is carried over this connection');

    app.life(AppLifecycleState.resumed);
    await app.dispose(tester);
  });

  testWidgets('with no notice (iOS, or Android refused it) the connection goes after 90 s; back, the page says so and comes back by itself', (tester) async {
    final app = _App(const NullNotifier());
    await app.start(tester);
    await app.openPage(tester);
    final asked = app.transport.webBridges.length;

    app.life(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 91));
    expect(app.connection.isLive, isFalse, reason: 'nothing keeps Android from freezing herdr: the old rule');
    await _settle(tester);
    expect(find.text('Lost the connection to build-box'), findsOneWidget);

    app.life(AppLifecycleState.resumed);
    await _settle(tester, 20);
    expect(app.connection.isLive, isTrue);
    expect(find.text('Lost the connection to build-box'), findsNothing);
    expect(app.transport.webBridges, hasLength(asked + 1), reason: 'the page opened again without a tap');
    await app.dispose(tester);
  });
}
