// One copy, one confirmation: where Android says "Copied to clipboard" itself
// (13 and later) the app says nothing of its own; it still says what the
// system cannot (a cut copy) and that the clipboard refused.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/services/system_clipboard.dart';
import 'package:herdr_mobile/ui/core/kit.dart';

late List<String> copied;

Future<void> copy(WidgetTester tester, {required bool systemConfirms, String? caveat, bool refuse = false}) async {
  copied = [];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method != 'Clipboard.setData') return null;
    if (refuse) throw PlatformException(code: 'denied');
    copied.add((call.arguments as Map)['text'] as String);
    return null;
  });
  addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
  SystemClipboard.confirms = systemConfirms;
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      navigatorObservers: [ToastRouteObserver()],
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: AppButton(
              label: 'copy',
              onPressed: () => copyText(context, '/srv/app/main.go', what: 'Path copied', caveat: caveat),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('copy'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  tearDown(() => SystemClipboard.confirms = false);

  testWidgets('where the system confirms a copy, the app says nothing: one confirmation, not two', (tester) async {
    await copy(tester, systemConfirms: true);
    expect(copied, ['/srv/app/main.go']);
    expect(find.byKey(toastKey), findsNothing);
  });

  testWidgets('where it does not, the app says what was copied', (tester) async {
    await copy(tester, systemConfirms: false);
    expect(find.text('Path copied'), findsOneWidget);
  });

  testWidgets('news the system cannot give is always said', (tester) async {
    await copy(tester, systemConfirms: true, caveat: 'Only the first 1 MB was copied');
    expect(find.text('Only the first 1 MB was copied'), findsOneWidget);
    expect(find.text('Path copied'), findsNothing);
  });

  testWidgets('a clipboard that refuses is said, whatever the system does', (tester) async {
    await copy(tester, systemConfirms: true, refuse: true);
    expect(find.text('Couldn’t copy: the clipboard refused it.'), findsOneWidget);
  });

  test('detect keeps the default off where there is no Android channel', () async {
    SystemClipboard.confirms = false;
    await SystemClipboard.detect();
    expect(SystemClipboard.confirms, isFalse);
  });
}
