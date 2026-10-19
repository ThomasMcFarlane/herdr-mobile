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
import 'package:herdr_mobile/data/models/release_info.dart';
import 'package:herdr_mobile/data/repositories/agent_session.dart';
import 'package:herdr_mobile/data/repositories/app_update.dart';
import 'package:herdr_mobile/data/repositories/notification_settings.dart';
import 'package:herdr_mobile/data/repositories/quick_phrases.dart';
import 'package:herdr_mobile/data/services/notifier.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/shell/home_shell.dart';
import 'package:provider/provider.dart';

import '../../screenshot_test/demo_fleet.dart';
import '../support/clip_recorder.dart';
import '../support/fake_agent_session.dart';
import '../support/memory_quick_phrases_store.dart';
import '../support/shot.dart';
import '../support/update_fakes.dart';

/// The release's own notes, as the sheet shows them: its section of
/// CHANGELOG.md without the heading and without the walkthrough line (the
/// poster is fetched from GitHub, which a test cannot reach).
String _notes(String version) {
  final lines = File('../CHANGELOG.md').readAsLinesSync();
  final start = lines.indexWhere((l) => l.startsWith('## [$version]'));
  final end = lines.indexWhere((l) => l.startsWith('## ['), start + 1);
  return lines.sublist(start + 1, end).where((l) => !l.startsWith('[![')).join('\n').trim();
}

void main() {
  if (Platform.environment['RELEASE_CLIP'] == null) {
    test('release clip is off (set RELEASE_CLIP=1)', () {}, skip: 'set RELEASE_CLIP=1 to record frames');
    return;
  }
  final dir = Platform.environment['RELEASE_CLIP_DIR'] ?? '/tmp/release_clip';
  setUpAll(loadAppFonts);

  // 0.1.20, "Read what's new before you update".
  testWidgets('0.1.20 walkthrough', (tester) async {
    final h = await DemoFleet.create(timed: true);
    final sessions = FakeAgentSessions(const []);
    const version = '0.1.20';
    final release = ReleaseInfo(
      version: version,
      apkUrl: 'https://github.com/tuan3w/herdr-mobile/releases/download/v$version/herdr-mobile-$version.apk',
      size: 23819658,
      pageUrl: ReleaseInfo.pageFor(version),
      notes: _notes(version),
      sha256: 'a' * 64,
    );
    final files = FakeReleaseFiles();
    final update = AppUpdate(
      store: MemoryUpdateStore(),
      feed: FakeReleaseFeed()..answer = release,
      files: files,
      installer: FakeApkInstaller(),
      current: AppVersion.tryParse('0.1.19'),
    );
    addTearDown(update.dispose);
    await update.check();
    final rec = ClipRecorder(dir);
    const total = 3;
    const beat = Duration(milliseconds: 500);

    await shoot(
      tester,
      HomeShell(update: update),
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
        await t.pump(const Duration(milliseconds: 600));

        rec.chapter(1, total, 'The dot on Settings leads to the update');
        await rec.hold(t, const Duration(milliseconds: 1200));
        await rec.tap(t, find.byKey(FloatingTabBar.tabKey('Settings')), 'Open Settings');
        await rec.hold(t, const Duration(milliseconds: 1200));

        rec.chapter(2, total, 'What\u2019s new comes first');
        await rec.tap(t, find.text('Update available'), 'Tap Update available');
        await rec.hold(t, const Duration(milliseconds: 1600));
        final notes = t.getCenter(find.text('Update to $version'));
        await rec.drag(t, notes + const Offset(0, 260), const Offset(0, -180), 'Read what changed',
            over: const Duration(milliseconds: 900));
        await rec.hold(t, const Duration(milliseconds: 800));

        rec.chapter(3, total, 'Then Download and Install', top: true);
        await rec.tap(t, find.text('Download ${megabytes(release.size)}'), 'Download');
        for (var i = 1; i <= 16; i++) {
          files.report(release.size * i ~/ 16);
          await rec.hold(t, const Duration(milliseconds: 120));
        }
        files.running!.complete(File('/x.apk'));
        await t.pump();
        await rec.hold(t, const Duration(milliseconds: 2200));
        await rec.hold(t, beat);
      },
    );
    rec.finish();
    await tester.pumpWidget(const SizedBox());
    sessions.dispose();
    h.dispose();
  });
}
