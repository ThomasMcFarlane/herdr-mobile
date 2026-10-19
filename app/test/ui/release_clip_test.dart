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
import 'package:herdr_mobile/data/repositories/agent_session.dart';
import 'package:herdr_mobile/data/repositories/notification_settings.dart';
import 'package:herdr_mobile/data/repositories/quick_phrases.dart';
import 'package:herdr_mobile/data/services/notifier.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/features/agents/agent_swipe.dart';
import 'package:herdr_mobile/ui/shell/home_shell.dart';
import 'package:provider/provider.dart';

import '../../screenshot_test/demo_fleet.dart';
import '../support/clip_recorder.dart';
import '../support/fake_agent_session.dart';
import '../support/memory_quick_phrases_store.dart';
import '../support/shot.dart';
import '../support/turn_fixtures.dart';

void main() {
  if (Platform.environment['RELEASE_CLIP'] == null) {
    test('release clip is off (set RELEASE_CLIP=1)', () {}, skip: 'set RELEASE_CLIP=1 to record frames');
    return;
  }
  final dir = Platform.environment['RELEASE_CLIP_DIR'] ?? '/tmp/release_clip';
  setUpAll(loadAppFonts);

  // 0.1.17, "One design language" and "See the next agent while you swipe".
  testWidgets('0.1.17 walkthrough', (tester) async {
    final h = await DemoFleet.create(timed: true);
    final session = FakeAgentSession(
      key: 'a/k1',
      title: 'Review the ledger migration plan',
      cwd: projectDir,
      machine: h.fleet.connection('a'),
      state: stateWith(items: richTurn()),
    );
    final sessions = FakeAgentSessions([session]);
    final rec = ClipRecorder(dir);
    const total = 6;
    // A person watching on a phone: enough to see each result land, no more.
    const beat = Duration(milliseconds: 500);

    await shoot(
      tester,
      const HomeShell(),
      '$dir/last.png',
      wrap: (app) => demoProviders(h, extra: [
        ListenableProvider<AgentSessions>.value(value: sessions),
        // Settings reads these.
        ChangeNotifierProvider(create: (_) => NotificationSettings(MemoryNotificationStore())),
        ChangeNotifierProvider(create: (_) => QuickPhrases(MemoryQuickPhrasesStore(['continue', 'run the tests']))),
        Provider<Notifier>.value(value: const NullNotifier()),
      ])(rec.wrap(app)),
      pump: (t) async {
        await h.ageStatuses(t);
        await h.terminalSettings.setWrap(true);
        await t.pump(const Duration(milliseconds: 600));

        rec.chapter(1, total, 'One name per agent, one way to read time');
        await rec.hold(t, const Duration(milliseconds: 1800));

        rec.chapter(2, total, 'The tab bar says where you are');
        final agents = t.getCenter(find.byKey(FloatingTabBar.tabKey('Agents')));
        final machines = t.getCenter(find.byKey(FloatingTabBar.tabKey('Machines')));
        await rec.drag(t, agents, machines - agents, 'Drag along the bar', over: const Duration(milliseconds: 700), rest: const Duration(milliseconds: 200));
        await rec.hold(t, const Duration(milliseconds: 1400));

        rec.chapter(3, total, 'Settings has a hidden kit');
        await rec.tap(t, find.byKey(FloatingTabBar.tabKey('Settings')), 'Open Settings');
        await rec.hold(t, beat);
        await rec.longPress(t, find.text('About').first, 'Hold About', hold: const Duration(milliseconds: 600));
        await rec.hold(t, const Duration(milliseconds: 900));
        final kit = t.getCenter(find.byType(Scaffold).last);
        await rec.drag(t, kit, const Offset(0, -320), 'Every component, light and dark', over: const Duration(milliseconds: 800), rest: Duration.zero);
        await rec.hold(t, beat);
        await rec.tap(t, find.byTooltip('Back').last, 'Back');
        await rec.hold(t, beat);
        await rec.tap(t, find.byKey(FloatingTabBar.tabKey('Agents')), 'Back to Agents');
        await rec.hold(t, beat);

        rec.chapter(4, total, 'A toast rises from behind the bar', top: true);
        await rec.tap(t, find.text('Mark all reviewed').first, 'Mark all reviewed');
        await rec.hold(t, const Duration(milliseconds: 1100));
        // It swipes away: part of the change, and quicker than waiting it out.
        final toast = t.getCenter(find.textContaining('Marked', findRichText: true).first);
        await rec.drag(t, toast, const Offset(240, 0), 'Swipe it away', over: const Duration(milliseconds: 350), rest: Duration.zero);
        await rec.hold(t, const Duration(milliseconds: 600));

        rec.chapter(5, total, 'See the next agent while you swipe');
        await rec.tap(t, find.text('Approve migration for payments ledger').first, 'Open the agent that needs you');
        await rec.hold(t, const Duration(milliseconds: 1000));
        final from = t.getCenter(find.byType(AgentSwipe)) + const Offset(120, 0);
        await rec.drag(t, from, const Offset(-150, 0), 'Drag slowly sideways', over: const Duration(milliseconds: 1100), rest: const Duration(milliseconds: 200));
        await rec.hold(t, const Duration(milliseconds: 1300));

        rec.chapter(6, total, 'Wrap lines moved into Pane options', top: true);
        await rec.tap(t, find.byTooltip('Pane options').first, 'Pane options');
        await rec.hold(t, const Duration(milliseconds: 1900));
      },
    );
    rec.finish();
    await tester.pumpWidget(const SizedBox());
    sessions.dispose();
    h.dispose();
  });
}
