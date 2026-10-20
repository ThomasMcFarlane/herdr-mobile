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

  // 0.1.24, "A session in a worktree shows up in that worktree": the phone's
  // part is the Branch the form now starts with; the desk's part (the session's
  // tab inside the worktree's workspace) is herdr's window and cannot be drawn here.
  testWidgets('0.1.24 walkthrough', (tester) async {
    final h = await DemoFleet.create(timed: true, worktrees: true);
    await h.online(tester);
    final hosts = <String, FakeAgentHost>{};
    final sessions = AgentSessionRepository(fleet: h.fleet, hostFor: (c) => hosts.putIfAbsent(c.profile.id, FakeAgentHost.new));
    final settings = AgentSessionSettings(MemorySessionStore());
    await settings.load();
    final rec = ClipRecorder(dir);
    const total = 1;

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

        // 1. New agent session: Checkout, New worktree… starts with a Branch name.
        rec.chapter(1, total, 'A new worktree starts with a branch name');
        await rec.tap(t, find.byKey(FloatingTabBar.tabKey('Machines')), 'Open Machines');
        await rec.hold(t, const Duration(milliseconds: 800));
        await rec.tap(t, find.text('studio-mac'), 'Open studio-mac');
        await rec.hold(t, const Duration(milliseconds: 1200));
        await rec.tap(t, find.byTooltip('New agent session in payments-api'), 'Start a session in the repo');
        await rec.hold(t, const Duration(milliseconds: 1400));
        await rec.tap(t, find.byType(CheckoutField), 'Open Checkout');
        await rec.hold(t, const Duration(milliseconds: 1000));
        await rec.tap(t, find.text('New worktree…'), 'Pick New worktree…');
        await rec.hold(t, const Duration(milliseconds: 2400));
        final branchField = find.descendant(of: find.widgetWithText(LabeledField, 'Branch'), matching: find.byType(EditableText));
        await rec.tap(t, branchField, 'Change the Branch if you like');
        const branch = 'feat/refund-webhooks';
        for (var i = 1; i <= branch.length; i++) {
          await t.enterText(branchField, branch.substring(0, i));
          await rec.hold(t, const Duration(milliseconds: 70));
        }
        await rec.hold(t, const Duration(milliseconds: 1600));
      },
    );
    rec.finish();
    await tester.pumpWidget(const SizedBox());
    sessions.dispose();
    settings.dispose();
    h.dispose();
  });
}
