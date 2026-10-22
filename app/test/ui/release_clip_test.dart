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
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/background/background_work.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/ui/features/photos/photo_viewer.dart' show PhotoViewer;
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';
import 'package:herdr_mobile/ui/features/agent_session/agent_session_screen.dart';
import 'package:herdr_mobile/ui/features/agent_session/status_line.dart' show statusNow;
import 'package:image/image.dart' as img;

import '../../screenshot_test/demo_fleet.dart';
import '../support/clip_recorder.dart';
import '../support/fake_agent_session.dart';
import '../support/fake_fs.dart';
import '../support/fake_transport.dart';
import '../support/shot.dart';
import '../support/turn_fixtures.dart';

TranscriptItem _launch(String command) => TranscriptTool(
      ToolCall(toolCallId: 't$command', kind: ToolKind.execute, status: ToolStatus.completed, rawInput: {'command': command}),
    );

TranscriptItem _say(String text) => TranscriptMessage(key: 'm$text', role: MessageRole.agent, blocks: [TextBlock(text)]);

TranscriptItem _wrote(String path) => TranscriptTool(
      ToolCall(
        toolCallId: 't$path',
        kind: ToolKind.edit,
        status: ToolStatus.completed,
        content: [ToolDiff(path: path, newText: '<h1>x</h1>')],
      ),
    );

Uint8List _png(int hue) {
  final image = img.Image(width: 160, height: 120);
  for (final p in image) {
    p.setRgb((60 + p.x + hue) % 256, (200 - p.y + hue) % 256, (90 + hue * 3) % 256);
  }
  return Uint8List.fromList(img.encodePng(image));
}

void main() {
  if (Platform.environment['RELEASE_CLIP'] == null) {
    test('release clip is off (set RELEASE_CLIP=1)', () {}, skip: 'set RELEASE_CLIP=1 to record frames');
    return;
  }
  final dir = Platform.environment['RELEASE_CLIP_DIR'] ?? '/tmp/release_clip';
  setUpAll(loadAppFonts);

  // 0.1.29: `Made` names an app by what runs and keeps its pages under it, its
  // tabs swipe, and a picture opens over the list with the others to swipe to.
  testWidgets('0.1.29 walkthrough', (tester) async {
    final h = await DemoFleet.create();
    statusNow = () => at(100);
    addTearDown(() => statusNow = DateTime.now);
    const base = '/home/dev/payments-api';
    final fs = FakeFs();
    for (var i = 0; i < 6; i++) {
      fs.addFile('$base/screenshots/checkout_${i + 1}.png', _png(i * 31));
    }
    fs.addFile('$base/reports/q3.html', '<h1>q3</h1>');
    final machine = MachineConnection(
      profile: const MachineProfile(id: 'm', label: 'devbox', host: 'h', username: 'u'),
      api: HerdrApi(FakeTransport()..fs = fs),
      backoff: (_) => const Duration(hours: 1),
      pollInterval: const Duration(hours: 1),
    );
    final session = FakeAgentSession(
      title: 'Fix the checkout totals',
      machine: machine,
      state: stateWith(
        items: [
          ...richTurn(),
          _launch('cd /w && nohup python label_server.py --port 8765 > log 2>&1 &'),
          _say('Labelling is on http://localhost:8765/ and the review queue on http://localhost:8765/review.'),
          _launch('npm run dev'),
          _say('The storefront is on http://localhost:5173/ and its checkout on http://localhost:5173/checkout.'),
          _wrote('$base/reports/q3.html'),
          for (var i = 1; i <= 6; i++) _say('I saved screenshots/checkout_$i.png'),
        ],
      ),
    );
    session.setBackground(
      BackgroundWork(
        tasks: const [BackgroundTask(id: 'bg1', kind: BackgroundKind.shell, status: BackgroundStatus.running, title: 'npm run dev -- --port 5173')],
      ),
    );
    final rec = ClipRecorder(dir);
    const total = 3;

    await shoot(
      tester,
      AgentSessionScreen(session: session),
      '$dir/last.png',
      wrap: (app) => demoProviders(h)(rec.wrap(app)),
      pump: (t) async {
        Future<void> real() async {
          // Thumbnails and pictures are read and decoded on the engine's real clock.
          for (var i = 0; i < 8; i++) {
            await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
            await rec.hold(t, const Duration(milliseconds: 100));
          }
        }

        await t.pump(const Duration(seconds: 1));
        await rec.hold(t, const Duration(milliseconds: 800));

        // 1. Apps say what is running, with their pages under them.
        rec.chapter(1, total, 'Apps say what is running', top: true);
        await rec.tap(t, find.text('Made'), 'Open Made');
        await rec.hold(t, const Duration(milliseconds: 900));
        await rec.tap(t, find.text('Apps'), 'Apps');
        await rec.hold(t, const Duration(milliseconds: 2200));

        // 2. The tabs swipe.
        rec.chapter(2, total, 'Swipe between tabs', top: true);
        final size = t.view.physicalSize / t.view.devicePixelRatio;
        final list = Offset(size.width / 2, size.height * 0.72);
        await rec.drag(t, list, const Offset(-240, 0), 'Swipe sideways', over: const Duration(milliseconds: 500), rest: const Duration(milliseconds: 600));
        await rec.hold(t, const Duration(milliseconds: 700));
        await rec.drag(t, list, const Offset(-240, 0), 'Again', over: const Duration(milliseconds: 500), rest: const Duration(milliseconds: 600));
        await real();
        await rec.hold(t, const Duration(milliseconds: 1000));

        // 3. A picture opens over the list; swipe to the next; Back returns to the list.
        rec.chapter(3, total, 'Open a picture, swipe to the next', top: true);
        await rec.tap(t, find.text('checkout_6.png'), 'Open a picture');
        await real();
        await rec.hold(t, const Duration(milliseconds: 900));
        await rec.drag(t, Offset(size.width * 0.8, size.height * 0.45), const Offset(-280, 0), 'Swipe to the next', over: const Duration(milliseconds: 500), rest: const Duration(milliseconds: 500));
        await real();
        await rec.hold(t, const Duration(milliseconds: 900));
        Navigator.of(t.element(find.byType(PhotoViewer))).pop();
        await rec.hold(t, const Duration(milliseconds: 1600));
      },
    );
    rec.finish();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
    session.dispose();
    h.dispose();
  });
}
