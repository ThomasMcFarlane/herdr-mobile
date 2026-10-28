// Records the walkthrough clip of the release being prepared: the real app on
// the invented demo fleet, going through the release's change list, as frames
// plus touches.json for make_clip.sh (skill herdr-changelog). Rewrite the
// script below each release; git keeps the old ones. Off by default; it
// writes files:
//
//   RELEASE_CLIP=1 flutter test test/ui/release_clip_test.dart
//
// Output: $RELEASE_CLIP_DIR (default /tmp/release_clip)/frames/*.png, touches.json
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/repositories/agent_screens.dart' show PaneAgent;
import 'package:herdr_mobile/ui/features/pane/pane_screen.dart';

import '../../screenshot_test/demo_fleet.dart';
import '../support/clip_recorder.dart';
import '../support/shot.dart';

const _esc = '\x1b';
String _c(int r, int g, int b, String s) => '$_esc[38;2;$r;$g;${b}m$s$_esc[0m';
String _dim(String s) => '$_esc[2m$s$_esc[0m';
String _bold(String s) => '$_esc[1m$s$_esc[0m';
String _row(int bg, String s) => '$_esc[48;2;${bg == 0 ? '30;58;40' : '66;30;34'}m${s.padRight(44)}$_esc[0m';

String _green(String s) => _c(76, 183, 130, s);

/// What an agent that finished a change has on screen: a diff in colour, the
/// test run, and a numbered list of what it could do next.
String _output() => [
  ' ${_c(154, 163, 242, '>')} Fix the flaky retry test in checkout.',
  '',
  ' ${_green('●')} ${_bold('Update')}(services/checkout/retry.go)',
  _dim('   └ Updated with 3 additions and 1 removal'),
  _dim('     31   func NewRetrier(c Clock, cfg Config) {'),
  _row(1, '     32 -   return &Retrier{cfg: cfg}'),
  _row(0, '     32 +   r := &Retrier{clock: c, cfg: cfg}'),
  _row(0, '     33 +   r.jitter = 0'),
  _row(0, '     34 +   return r'),
  _dim('     35   }'),
  '',
  ' ${_green('●')} ${_bold('Bash')}(go test ./services/checkout)',
  '   └ ${_green('ok')} payments/checkout ${_dim('0.84s')}',
  '',
  ' ${_green('●')} The test now passes 50 runs in a row.',
  '   I can go on with:',
  '',
  '   1. Run the whole checkout suite',
  '   2. Open a pull request for the fix',
  '   3. Stop here',
].join('\n');

void main() {
  if (Platform.environment['RELEASE_CLIP'] == null) {
    test('release clip is off (set RELEASE_CLIP=1)', () {}, skip: 'set RELEASE_CLIP=1 to record frames');
    return;
  }
  final dir = Platform.environment['RELEASE_CLIP_DIR'] ?? '/tmp/release_clip';
  setUpAll(loadAppFonts);

  // 0.1.42: text selected in a pane shows in a brighter indigo on the dark
  // terminal (it was almost the colour of the page).
  testWidgets('0.1.42 walkthrough', (tester) async {
    final h = await DemoFleet.create();
    h.transports['a']!.paneTexts['a1:p2'] = _output();
    final rec = ClipRecorder(dir);

    await shoot(
      tester,
      PaneScreen(agent: PaneAgent('a', 'a1:p2')),
      '$dir/last.png',
      brightness: Brightness.dark,
      wrap: (app) => demoProviders(h)(rec.wrap(app)),
      pump: (t) async {
        await h.online(t);
        await h.setStatus(t, 'a1:p2', 'idle');
        await t.pump(const Duration(seconds: 1));
        await rec.hold(t, const Duration(milliseconds: 1200));

        // 1. Selected text is easy to see.
        rec.chapter(1, 1, 'Selected text is easy to see');
        // Rows are ~14.9 dp apart from y = 100: start on the word `Updated` and
        // end on the last menu row.
        const from = Offset(85, 145);
        await rec.hold(t, const Duration(milliseconds: 500));
        await rec.pressDrag(
          t,
          from,
          const Offset(175, 223),
          'Press and hold, then drag',
          press: const Duration(milliseconds: 700),
          over: const Duration(milliseconds: 1600),
          // Held under the finger: lifting would open the copy toolbar, which a
          // test draws in the placeholder font.
          rest: const Duration(milliseconds: 1500),
        );
      },
    );
    rec.finish();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
    h.dispose();
  });
}
