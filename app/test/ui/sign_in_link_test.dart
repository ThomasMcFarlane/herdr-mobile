// A machine's sign-in link (Tailscale SSH approval) opens in the phone's own
// browser, a Custom Tab with the person's sign-ins, never in herdr's page view:
// Google refuses sign-in inside embedded views, and Tailscale's login offers it.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/features/machines/approval_button.dart';
import 'package:herdr_mobile/ui/features/web/web_preview_screen.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

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

void main() {
  testWidgets('Open sign-in page goes to the phone\'s browser, not to the page view', (tester) async {
    final launcher = _Launcher();
    UrlLauncherPlatform.instance = launcher;
    final web = FakeWebView.install();
    const link = 'https://login.tailscale.com/a/l3503a0535f1bf';
    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.light(), home: const Scaffold(body: Center(child: ApprovalButton(url: link)))),
    );

    await tester.tap(find.text('Open sign-in page'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(launcher.opened, [link]);
    expect(launcher.modes, [PreferredLaunchMode.inAppBrowserView]);
    expect(find.byType(WebPreviewScreen), findsNothing);
    expect(web.loaded, isEmpty);
  });
}
