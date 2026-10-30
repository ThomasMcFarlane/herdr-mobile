// Renders the board grouped by project to PNGs for review: the demo fleet
// with payments-api's main checkout and three worktrees (branches read from
// `worktree.list`), and the same fleet with no repo info at all (every
// workspace plain: projects are folders). Light and dark, 412 and 320 dp
// wide, text scale 1 and 1.6, plus tall frames (412 x1, 320 x1.6) that show
// the whole board. Not part of `flutter test` (the folder is `screenshot_test`):
//
//   BOARD_SHOTS_DIR=/tmp/board_shots flutter test screenshot_test/board_projects_shots_test.dart
//
// Output: $BOARD_SHOTS_DIR (default /tmp/board_shots)/<case>-<tone>-<w>-x<scale>.png
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/shell/home_shell.dart';

import '../test/support/shot.dart';
import 'demo_fleet.dart';

void main() {
  final out = Directory(Platform.environment['BOARD_SHOTS_DIR'] ?? '/tmp/board_shots');

  setUpAll(() async {
    await loadAppFonts();
    out.createSync(recursive: true);
  });

  const sizes = [Size(412, 892), Size(320, 640)];
  const scales = [1.0, 1.6];

  Future<void> boardShot(
    WidgetTester tester,
    String path, {
    required bool worktrees,
    required Brightness b,
    required Size size,
    required double scale,
  }) async {
    final h = await DemoFleet.create(timed: true, worktrees: worktrees);
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await shoot(
      tester,
      const HomeShell(),
      path,
      brightness: b,
      size: size,
      imageScale: 2,
      wrap: demoProviders(h),
      pump: (t) async {
        await h.ageStatuses(t);
        for (var i = 0; i < 30; i++) {
          await t.pump(const Duration(milliseconds: 100));
        }
      },
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    h.dispose();
  }

  for (final (name, worktrees) in const [('projects', true), ('plain', false)]) {
    for (final b in Brightness.values) {
      for (final size in sizes) {
        for (final scale in scales) {
          testWidgets('$name ${b.name} ${size.width.toInt()} x$scale', (tester) async {
            await boardShot(
              tester,
              '${out.path}/$name-${b.name}-${size.width.toInt()}-x$scale.png',
              worktrees: worktrees,
              b: b,
              size: size,
              scale: scale,
            );
          });
        }
      }
      testWidgets('$name ${b.name} whole board, 320 x1.6', (tester) async {
        await boardShot(
          tester,
          '${out.path}/$name-${b.name}-320-x1.6-tall.png',
          worktrees: worktrees,
          b: b,
          size: const Size(320, 2600),
          scale: 1.6,
        );
      });
      testWidgets('$name ${b.name} whole board', (tester) async {
        await boardShot(
          tester,
          '${out.path}/$name-${b.name}-412-tall.png',
          worktrees: worktrees,
          b: b,
          size: const Size(412, 1900),
          scale: 1,
        );
      });
    }
  }
}
