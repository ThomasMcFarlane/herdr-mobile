// The hidden Kit screen: held `Version …` in Settings opens it, and every
// catalog entry's page builds at the narrowest phone with large text.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/app_info.dart';
import 'package:herdr_mobile/data/repositories/app_settings.dart';
import 'package:herdr_mobile/data/repositories/notification_settings.dart';
import 'package:herdr_mobile/data/repositories/terminal_settings.dart';
import 'package:herdr_mobile/data/services/notifier.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/features/kit/kit_catalog.dart';
import 'package:herdr_mobile/ui/features/kit/kit_screen.dart';
import 'package:herdr_mobile/ui/features/settings/settings_screen.dart';
import 'package:provider/provider.dart';

import '../support/memory_app_settings_store.dart';
import '../support/memory_terminal_settings_store.dart';
import '../support/shot.dart' show loadAppFonts;

void _narrow(WidgetTester tester) {
  tester.view
    ..physicalSize = const Size(320, 640) * 2
    ..devicePixelRatio = 2;
  addTearDown(tester.view.reset);
}

Widget _app(Widget home, {double textScale = 1.6}) => MaterialApp(
      theme: AppTheme.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: home,
    );

/// Lets a push (or a one-shot drawing) finish without waiting on a spinner.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUpAll(loadAppFonts);

  testWidgets('holding Version in Settings opens the Kit screen; the first entry renders at 320 dp, 1.6x',
      (tester) async {
    _narrow(tester);
    final notifications = NotificationSettings(MemoryNotificationStore(const NotificationChoice()));
    await notifications.load();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => AppSettings(MemoryAppSettingsStore())),
          ChangeNotifierProvider(create: (_) => TerminalSettings(MemoryTerminalSettingsStore())),
          ChangeNotifierProvider.value(value: notifications),
          Provider<Notifier>.value(value: const NullNotifier()),
        ],
        child: _app(const SettingsScreen()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    final version = find.text('Version $appVersion');
    await tester.ensureVisible(version);
    await tester.pump();
    await tester.longPress(version);
    await _settle(tester);
    expect(find.byType(KitScreen), findsOneWidget);

    final first = kitCatalog.first;
    await tester.tap(find.text(first.name));
    await _settle(tester);
    expect(find.byType(KitEntryPage), findsOneWidget);
    // The states' own text scale: 1.6 as well.
    await tester.tap(find.text('1.6x'));
    await _settle(tester);
    expect(find.text(first.states.first.label), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final dark in [false, true]) {
    testWidgets('every entry builds at 320 dp, 1.6x, ${dark ? 'dark' : 'light'}', (tester) async {
      _narrow(tester);
      for (final entry in kitCatalog) {
        await tester.pumpWidget(_app(KitEntryPage(key: ValueKey(entry.slug), entry: entry, dark: dark, scale: 1.6)));
        await _settle(tester);
        expect(tester.takeException(), isNull, reason: entry.name);
      }
      await tester.pumpWidget(const SizedBox());
      await _settle(tester);
    });
  }
}
