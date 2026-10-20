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
import 'package:herdr_mobile/data/repositories/agent_session_repository.dart';
import 'package:herdr_mobile/data/repositories/agent_session_settings.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/features/create/checkout_field.dart';
import 'package:herdr_mobile/ui/shell/home_shell.dart';
import 'package:provider/provider.dart';

import '../../screenshot_test/demo_fleet.dart';
import '../support/clip_recorder.dart';
import '../support/fake_agent_host.dart';
import '../support/shot.dart';
import 'history_support.dart' show MemorySessionStore;

void main() {
  if (Platform.environment['RELEASE_CLIP'] == null) {
    test('release clip is off (set RELEASE_CLIP=1)', () {}, skip: 'set RELEASE_CLIP=1 to record frames');
    return;
  }
  final dir = Platform.environment['RELEASE_CLIP_DIR'] ?? '/tmp/release_clip';
  setUpAll(loadAppFonts);

  // 0.1.22, "See and manage your worktrees from the phone".
  testWidgets('0.1.22 walkthrough', (tester) async {
    final h = await DemoFleet.create(timed: true, worktrees: true);
    await h.online(tester);
    final hosts = <String, FakeAgentHost>{};
    final sessions = AgentSessionRepository(fleet: h.fleet, hostFor: (c) => hosts.putIfAbsent(c.profile.id, FakeAgentHost.new));
    final settings = AgentSessionSettings(MemorySessionStore());
    await settings.load();
    final rec = ClipRecorder(dir);
    const total = 3;
    const beat = Duration(milliseconds: 500);

    await shoot(
      tester,
      const HomeShell(),
      '$dir/last.png',
      wrap: (app) => demoProviders(h, extra: [
        ListenableProvider<AgentSessions>.value(value: sessions),
        ChangeNotifierProvider.value(value: settings),
      ])(rec.wrap(app)),
      pump: (t) async {
        await h.ageStatuses(t);
        await t.pump(const Duration(milliseconds: 600));

        // 1. A machine's screen: the repo, its checkouts, branches and agents.
        rec.chapter(1, total, 'A repo shows its checkouts and who works in each');
        await rec.tap(t, find.byKey(FloatingTabBar.tabKey('Machines')), 'Open Machines');
        await rec.hold(t, const Duration(milliseconds: 800));
        await rec.tap(t, find.text('studio-mac'), 'Open studio-mac');
        await rec.hold(t, const Duration(milliseconds: 2800));

        // 2. New agent session: Checkout, New worktree…, Branch.
        rec.chapter(2, total, 'Start an agent in a new worktree', top: true);
        await rec.tap(t, find.byTooltip('New agent session in payments-api'), 'Start a session in the repo');
        await rec.hold(t, const Duration(milliseconds: 1400));
        await rec.tap(t, find.byType(CheckoutField), 'Open Checkout');
        await rec.hold(t, const Duration(milliseconds: 1200));
        await rec.tap(t, find.text('New worktree…'), 'Pick New worktree…');
        await rec.hold(t, const Duration(milliseconds: 900));
        await rec.tap(t, find.widgetWithText(TextFormField, 'Named by herdr'), 'Type a Branch');
        const branch = 'feat/refund-webhooks';
        for (var i = 1; i <= branch.length; i++) {
          await t.enterText(find.widgetWithText(TextFormField, 'Named by herdr'), branch.substring(0, i));
          await rec.hold(t, const Duration(milliseconds: 70));
        }
        await rec.hold(t, const Duration(milliseconds: 1600));

        // 3. A checkout's ⋯: Remove worktree asks for a hold.
        rec.chapter(3, total, 'Remove a worktree with a hold', top: true);
        await rec.tap(t, find.byType(AppBackButton).hitTestable(), 'Back to the machine');
        await rec.hold(t, const Duration(milliseconds: 1000));
        await rec.tap(t, find.byTooltip('Checkout actions').at(2), 'Open Checkout actions');
        await rec.hold(t, const Duration(milliseconds: 1000));
        await rec.tap(t, find.text('Remove worktree'), 'Remove worktree');
        await rec.hold(t, const Duration(milliseconds: 1500));
        await rec.longPress(t, find.byType(HoldToConfirm), 'Hold to remove', hold: const Duration(milliseconds: 1100));
        await rec.hold(t, const Duration(milliseconds: 1600));
        await rec.hold(t, beat);
      },
    );
    rec.finish();
    await tester.pumpWidget(const SizedBox());
    sessions.dispose();
    settings.dispose();
    h.dispose();
  });
}
