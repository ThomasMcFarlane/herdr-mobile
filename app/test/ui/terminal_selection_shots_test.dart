// Renders a pane with its output selected (dark and paper themes) to PNGs, to
// judge the selection colour against real agent output. Off by default; it
// writes files:
//
//   TERMINAL_SELECTION_SHOTS=1 flutter test test/ui/terminal_selection_shots_test.dart
//
// TERMINAL_SELECTION_SHOTS_DIR picks the folder (default /tmp/terminal_selection_shots).
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/render/terminal/terminal_view.dart';

import '../support/shot.dart';

const _esc = '\x1b';

/// What an agent's TUI really paints: a diff in colour, a menu with a pointer,
/// dim hints, bold headings.
final _screen = [
  '$_esc[1m$_esc[36m●$_esc[0m $_esc[1mUpdate(app/lib/ui/core/tokens.dart)$_esc[0m',
  '  $_esc[2m⎿$_esc[0m  Added 5 lines, removed 1 line',
  '     $_esc[32m145 +  Color get selection => accent.withValues(alpha: 0.5);$_esc[0m',
  '     $_esc[31m146 -  Color get selection => accent.withValues(alpha: 0.28);$_esc[0m',
  '',
  '$_esc[1mDo you want to proceed?$_esc[0m',
  '$_esc[36m❯ 1. Yes$_esc[0m',
  '  2. Yes, and don\'t ask again for dart format commands',
  '  3. No, and tell Claude what to do differently $_esc[2m(esc)$_esc[0m',
  '',
  '$_esc[2m? for shortcuts$_esc[0m',
].join('\r\n');

void main() {
  if (Platform.environment['TERMINAL_SELECTION_SHOTS'] == null) {
    test(
      'terminal selection shots are off (set TERMINAL_SELECTION_SHOTS=1)',
      () {},
      skip: 'set TERMINAL_SELECTION_SHOTS=1 to render PNGs',
    );
    return;
  }
  final out = Platform.environment['TERMINAL_SELECTION_SHOTS_DIR'] ?? '/tmp/terminal_selection_shots';
  setUpAll(() async {
    await loadAppFonts();
    Directory(out).createSync(recursive: true);
  });

  for (final brightness in Brightness.values) {
    testWidgets('selected output, ${brightness.name}', (tester) async {
      await shoot(
        tester,
        Scaffold(
          body: SafeArea(child: TerminalView(text: _screen)),
        ),
        '$out/selected_${brightness.name}.png',
        brightness: brightness,
        pump: (t) async {
          t.state<SelectableRegionState>(find.byType(SelectableRegion)).selectAll();
          await t.pump(const Duration(milliseconds: 200));
        },
      );
    });
  }
}
