// The bug this screen fixes, end to end: a page opened from a terminal link
// must keep the machine's connection while the person is away from herdr.
// In a Custom Tab herdr went to the background, the fleet let the
// connection go after 90 s, and the page waited on "Opening…" forever.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/fleet_repository.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/repositories/machine_repository.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/features/pane/link_sheet.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import '../support/fake_network.dart';
import '../support/fake_transport.dart';
import '../support/fake_webview.dart';
import '../support/memory_stores.dart';

class _Launcher extends UrlLauncherPlatform {
  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async => true;
}

void main() {
  testWidgets('a page opened on the phone keeps the connection past the 90 s away', (tester) async {
    UrlLauncherPlatform.instance = _Launcher();
    FakeWebView.install();
    final transport = FakeTransport();
    final machines = MachineRepository(profiles: MemoryProfileStore(), secrets: MemorySecretStore());
    final fleet = FleetRepository(
      machines: machines,
      network: FakeNetwork(),
      connect: (profile, secrets) => MachineConnection(
        profile: profile,
        api: HerdrApi(transport),
        backoff: (_) => const Duration(hours: 1),
        pollInterval: const Duration(hours: 1),
      ),
    );
    machines.save(
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
                  onPressed: () => showLinkSheet(context, 'http://localhost:3000/', machine: fleet.connection('m')),
                  child: const Text('link'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    final connection = fleet.connection('m')!;
    expect(connection.isLive, isTrue, reason: 'set-up');

    await tester.tap(find.text('link'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.text('Open on phone'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Open on phone'), findsNothing, reason: 'the sheet closed: the page was asked for');
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // The person switches to another app for two minutes.
    fleet.onLifecycleState(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 91));
    await tester.pump(const Duration(seconds: 30));
    expect(connection.isLive, isTrue, reason: 'the page is carried over this connection');

    fleet.onLifecycleState(AppLifecycleState.resumed);
    await tester.pumpWidget(const SizedBox());
    fleet.dispose(); // its connections' timers end with it
    await tester.pump();
  });
}
