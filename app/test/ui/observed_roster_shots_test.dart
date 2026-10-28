// Renders the subagent roster of an observed session to PNGs for review, light
// and dark: a 66-subagent swarm with six running (long Vietnamese tasks), the
// same with nothing running, a log read in part, a held stop in its states, a
// link that is down, one subagent, and the narrow (320x640) layout at text
// scale 1.6. Off by default; it writes files:
//
//   ROSTER_SHOTS=1 flutter test test/ui/observed_roster_shots_test.dart
//
// Output: $ROSTER_SHOTS_DIR (default /tmp/roster_shots)/<case>-<light|dark>.png
@TestOn('vm')
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/background/background_work.dart';
import 'package:herdr_mobile/data/observed/observed_contracts.dart' show SubagentInfo;
import 'package:herdr_mobile/data/repositories/agent_session.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/features/agent_session/subagent_roster.dart';

import '../support/fake_agent_session.dart';
import '../support/shot.dart' show loadAppFonts;
import 'hold_support.dart';

void main() {
  if (Platform.environment['ROSTER_SHOTS'] == null) {
    test('roster shots are off (set ROSTER_SHOTS=1)', () {}, skip: 'set ROSTER_SHOTS=1 to render PNGs');
    return;
  }
  final out = Platform.environment['ROSTER_SHOTS_DIR'] ?? '/tmp/roster_shots';

  setUpAll(() async {
    await loadAppFonts();
    Directory(out).createSync(recursive: true);
  });

  final now = DateTime.now();

  SubagentEntry entry(String name, SubagentState state, {int tools = 0, String assignment = ''}) => SubagentEntry(
    info: SubagentInfo(
      name: name,
      assignment: assignment,
      toolCount: tools,
      recentTools: state == SubagentState.running ? const ['read', 'bash', 'edit'] : const [],
    ),
    state: state,
  );

  BackgroundTask task(String id) => BackgroundTask(
    id: id,
    kind: BackgroundKind.agent,
    status: BackgroundStatus.running,
    title: id,
    stop: StopRoute.message,
    startedAt: now.subtract(const Duration(minutes: 12)),
  );

  const names = ['SecFixAuth', 'SecFixFile', 'SecFixOps', 'SecFixContractor', 'SecFixTenantA', 'SecFixTenantB'];
  const task0 =
      'Hoàn thành nhiệm vụ được giao một cách kỹ lưỡng: sửa các lỗi bảo mật trong nhóm Auth, chạy bộ kiểm thử riêng trong worktree và báo cáo kết quả chi tiết cho người điều phối.';

  List<SubagentEntry> swarm({bool running = true}) => [
    for (var i = 0; i < 55; i++) entry('SecRev${i.toString().padLeft(2, '0')}', SubagentState.finished, tools: 10 + i),
    for (var i = 0; i < 3; i++) entry('FfRevBroken$i', SubagentState.failed, tools: 4),
    if (running)
      for (final n in names) entry(n, SubagentState.running, tools: 9, assignment: task0),
    entry('GradeNext0', SubagentState.waiting),
    entry('GradeNext1', SubagentState.waiting, assignment: 'Wait for the fixes, then grade them.'),
  ];

  FakeAgentSession session(List<SubagentEntry> roster, {List<BackgroundTask> tasks = const []}) =>
      FakeAgentSession(agent: 'omp', agentLabel: 'omp')
        ..observed = true
        ..paneId = 'p1'
        ..roster = roster
        ..backgroundWork = BackgroundWork(tasks: tasks, wakes: true, wakeLabel: 'omp');

  late FakeAgentSession current;
  final held = {'stop-held', 'stop-could-not-confirm'};

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.byType(SubagentsChip));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  final scenarios = <String, (FakeAgentSession Function(), Future<void> Function(WidgetTester)?, Size, double)>{
    'chip-only': (() => session(swarm(), tasks: [for (final n in names) task(n)]), null, const Size(412, 160), 1),
    'swarm': (() => session(swarm(), tasks: [for (final n in names) task(n)]), open, const Size(412, 892), 1),
    'swarm-narrow-scaled': (
      () => session(swarm(), tasks: [for (final n in names) task(n)]),
      open,
      const Size(320, 640),
      1.6,
    ),
    'swarm-none-running': (() => session(swarm(running: false)), open, const Size(412, 892), 1),
    'partial-log': (
      () => session(swarm(running: false))..earlierValue = EarlierHistory.available,
      (tester) async {
        await open(tester);
        await tester.drag(find.byType(ListView).last, const Offset(0, -4000));
        await tester.pump();
      },
      const Size(412, 892),
      1,
    ),
    'stop-held': (
      () => session(swarm(), tasks: [for (final n in names) task(n)]),
      (tester) async {
        await open(tester);
        await holdFor(tester, find.text('Ask to stop').first);
        await tester.pump();
      },
      const Size(412, 892),
      1,
    ),
    'stop-could-not-confirm': (
      () => session(swarm(), tasks: [for (final n in names) task(n)]),
      (tester) async {
        await open(tester);
        await holdFor(tester, find.text('Ask to stop').first);
        await tester.pump(const Duration(seconds: 13));
      },
      const Size(412, 892),
      1,
    ),
    'disconnected': (
      () => session(swarm(), tasks: [for (final n in names) task(n)]),
      (tester) async {
        await open(tester);
        current.setLink(AgentLink.reconnecting);
        await tester.pump();
      },
      const Size(412, 892),
      1,
    ),
    'one': (
      () => session(
        [entry('Alpha', SubagentState.running, tools: 2, assignment: 'Survey RL frameworks')],
        tasks: [task('Alpha')],
      ),
      open,
      const Size(412, 892),
      1,
    ),
  };

  for (final brightness in Brightness.values) {
    for (final e in scenarios.entries) {
      testWidgets('${e.key} ${brightness.name}', (tester) async {
        final (make, then, size, scale) = e.value;
        final s = current = make();
        const dpr = 2.625;
        tester.view.physicalSize = size * dpr;
        tester.view.devicePixelRatio = dpr;
        tester.view.padding = const FakeViewPadding(top: 24 * dpr, bottom: 20 * dpr);
        tester.view.viewPadding = tester.view.padding;
        addTearDown(tester.view.reset);
        final key = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: AppTheme.light(),
            darkTheme: AppTheme.dark(),
            themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
            builder: (context, child) => RepaintBoundary(
              key: key,
              child: MediaQuery(
                data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
            ),
            home: Scaffold(
              body: SafeArea(
                child: Align(
                  alignment: Alignment.topLeft,
                  child: SubagentsChip(session: s),
                ),
              ),
            ),
          ),
        );
        await tester.pump(Dwell.tapGuard);
        await then?.call(tester);
        await tester.pump(Duration(milliseconds: held.contains(e.key) ? 10 : 600));
        final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final ui.Image image = await boundary.toImage(pixelRatio: 1.5);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('$out/${e.key}-${brightness.name}.png').writeAsBytes(data!.buffer.asUint8List());
        });
        expect(tester.takeException(), isNull, reason: '${e.key} ${brightness.name}');
      });
    }
  }
}
