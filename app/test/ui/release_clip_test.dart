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
import 'package:herdr_mobile/ui/features/agent_session/agent_session_screen.dart';
import 'package:herdr_mobile/ui/features/agent_session/status_line.dart' show statusNow;

import '../../screenshot_test/demo_fleet.dart';
import '../support/clip_recorder.dart';
import '../support/fake_agent_session.dart';
import '../support/shot.dart';
import '../support/turn_fixtures.dart';

void main() {
  if (Platform.environment['RELEASE_CLIP'] == null) {
    test('release clip is off (set RELEASE_CLIP=1)', () {}, skip: 'set RELEASE_CLIP=1 to record frames');
    return;
  }
  final dir = Platform.environment['RELEASE_CLIP_DIR'] ?? '/tmp/release_clip';
  setUpAll(loadAppFonts);

  // 0.1.27: a dev-server address in an answer is a link, and `Made` lists it
  // under its own icons beside a page the agent wrote. The Settings icons and
  // the picture icons are not in the clip: they are stills.
  testWidgets('0.1.27 walkthrough', (tester) async {
    final h = await DemoFleet.create();
    statusNow = () => at(100);
    addTearDown(() => statusNow = DateTime.now);
    final session = FakeAgentSession(
      title: 'Fix the Hà Nội locale bug',
      state: stateWith(
        items: [
          ...richTurn(),
          editAt('e3', '/home/dev/payments-api/reports/q3.html', 56, before: '', after: '<h1>q3</h1>'),
          agentAt(
            'm1',
            '`http://localhost:8791/` shows the fix, and the API is on 127.0.0.1:8000. I also wrote the report.',
            60,
          ),
        ],
      ),
    );
    final rec = ClipRecorder(dir);
    const total = 2;

    await shoot(
      tester,
      AgentSessionScreen(session: session),
      '$dir/last.png',
      wrap: (app) => demoProviders(h)(rec.wrap(app)),
      pump: (t) async {
        await t.pump(const Duration(seconds: 1));
        await rec.hold(t, const Duration(milliseconds: 800));

        // 1. The address the agent prints is a link.
        rec.chapter(1, total, 'A dev-server address is a link');
        final message = find.textContaining('shows the fix', findRichText: true);
        await t.ensureVisible(message);
        await rec.hold(t, const Duration(milliseconds: 600));
        final link = t.getTopLeft(message) + const Offset(60, 10);
        await rec.tapAt(t, link, 'Tap the address');
        await rec.hold(t, const Duration(milliseconds: 1800));
        await t.tapAt(const Offset(200, 60));
        await rec.hold(t, const Duration(milliseconds: 900));

        // 2. Made lists the servers under their own icon.
        rec.chapter(2, total, 'Made has its own icons', top: true);
        await rec.tap(t, find.text('Made'), 'Open Made');
        await rec.hold(t, const Duration(milliseconds: 1200));
        await rec.tap(t, find.text('Servers'), 'Servers');
        await rec.hold(t, const Duration(milliseconds: 2400));
      },
    );
    rec.finish();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
    session.dispose();
    h.dispose();
  });
}
