// Renders every kit catalog entry (lib/ui/features/kit/kit_catalog.dart) to
// PNGs: light and dark, 412 x 892 and 320 x 640, text scale 1.0 and 1.6, with
// the real fonts. A tall entry grows the screen to show all of its states.
//
//   KIT_SHOTS=1 flutter test test/ui/kit_catalog_shots_test.dart
//
// Output: KIT_SHOTS_DIR (default /tmp/kit_catalog), one file per render,
// `<entry>-<light|dark>-<w>-<scale>.png`.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/features/kit/kit_catalog.dart';
import 'package:herdr_mobile/ui/features/kit/kit_screen.dart';

import '../support/shot.dart';

void main() {
  if (Platform.environment['KIT_SHOTS'] == null) {
    test('kit catalog shots are off (set KIT_SHOTS=1)', () {}, skip: 'set KIT_SHOTS=1 to render PNGs');
    return;
  }
  final out = Platform.environment['KIT_SHOTS_DIR'] ?? '/tmp/kit_catalog';

  setUpAll(() async {
    await loadAppFonts();
    Directory(out).createSync(recursive: true);
  });

  for (final entry in kitCatalog) {
    for (final brightness in Brightness.values) {
      for (final size in const [phone, Size(320, 640)]) {
        for (final scale in KitEntryPage.scales) {
          final name = '${entry.slug}-${brightness.name}-${size.width.round()}-$scale';
          testWidgets(name, (tester) async {
            await shoot(
              tester,
              KitEntryPage(entry: entry, dark: brightness == Brightness.dark, scale: scale),
              '$out/$name.png',
              brightness: brightness,
              size: size,
              pump: (tester) async {
                // Grow the screen by what the states' list cannot show.
                final body = tester.getSize(find.byKey(KitEntryPage.bodyKey)).height;
                final view = tester.getSize(find.byKey(KitEntryPage.scrollKey)).height;
                if (body > view) {
                  tester.view.physicalSize = Size(size.width, size.height + body - view) * phoneDpr;
                  await tester.pump();
                  await tester.pump(const Duration(milliseconds: 500));
                }
              },
            );
          });
        }
      }
    }
  }
}
