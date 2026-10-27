// Renders What's new (Settings > About) to PNGs for review: the list built from the real
// CHANGELOG.md, and the notes sheet of the newest release, light and dark, at 412 dp and 320 dp
// with large text. Off by default; it writes files:
//
//   RELEASE_HISTORY_SHOTS=1 flutter test test/ui/release_history_shots_test.dart
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/app_info.dart';
import 'package:herdr_mobile/ui/features/settings/release_history_screen.dart';

import '../support/shot.dart';

void main() {
  if (Platform.environment['RELEASE_HISTORY_SHOTS'] == null) {
    test('release history shots are off (set RELEASE_HISTORY_SHOTS=1)', () {}, skip: 'set RELEASE_HISTORY_SHOTS=1 to render PNGs');
    return;
  }
  final out = Platform.environment['RELEASE_HISTORY_SHOTS_DIR'] ?? '/tmp/release_history_shots';
  setUpAll(() async {
    await loadAppFonts();
    Directory(out).createSync(recursive: true);
  });

  // Read up front: file I/O does not finish inside a widget test's clock.
  final changelog = File('../CHANGELOG.md').readAsStringSync();
  Future<String> real() async => changelog;

  for (final brightness in [Brightness.light, Brightness.dark]) {
    final name = brightness.name;
    testWidgets('list $name', (tester) async {
      await shoot(tester, ReleaseHistoryScreen(load: real), '$out/list-$name.png', brightness: brightness);
    });
    testWidgets('list $name narrow, large text', (tester) async {
      await shoot(
        tester,
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.6)),
          child: ReleaseHistoryScreen(load: real),
        ),
        '$out/list-$name-320-x1.6.png',
        brightness: brightness,
        size: const Size(320, 640),
      );
    });
    testWidgets('notes $name', (tester) async {
      await shoot(
        tester,
        ReleaseHistoryScreen(load: real),
        '$out/notes-$name.png',
        brightness: brightness,
        pump: (t) async {
          await t.tap(find.text('$appVersion \u00b7 Installed'));
          await t.pump();
          await t.pump(const Duration(milliseconds: 500));
        },
      );
    });
  }
}
