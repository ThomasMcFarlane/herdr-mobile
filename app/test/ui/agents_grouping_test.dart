// What the agents tab lists, derived from the fleet without any widgets.
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/words/elapsed.dart';
import 'package:herdr_mobile/data/models/herdr_models.dart' show AgentStatus;
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/models/status_time.dart';
import 'package:herdr_mobile/data/repositories/attention_set.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:flutter/material.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/features/agents/agent_card.dart' show StateTime;
import 'package:herdr_mobile/ui/features/agents/agents_grouping.dart';

import '../support/fake_agent_session.dart';
import 'ui_harness.dart';

MachineProfile _machine(String id, String label, {bool enabled = true}) =>
    MachineProfile(id: id, label: label, host: '$id.example', username: 'dev', enabled: enabled);

Pane _pane(int i, String status, {String? agent = 'claude'}) => (id: 'w1:p$i', ws: 'w1', agent: agent, status: status);

Future<UiHarness> _fleet(
  Map<String, List<Pane>> machines, {
  Set<String> disabled = const {},
  String Function(String)? title,
  String Function(String)? cwd,
}) async {
  final h = await UiHarness.create([
    for (final MapEntry(:key, :value) in machines.entries)
      (
        profile: _machine(key, 'm-$key', enabled: !disabled.contains(key)),
        snapshot: snapshotWith(value, title: title, cwd: cwd),
      ),
  ]);
  await pumpEventQueue(times: 50);
  return h;
}

AgentRowData _row(String key, AgentStatus status, MachineConnection machine) => (
  key: key,
  machine: machine,
  paneId: key,
  status: status,
  title: key,
  subtitle: '',
  stale: false,
  since: null,
  quietMinutes: 0,
);

void main() {
  group('agent rows', () {
    test('the second line is kind, machine, workspace, folder; one machine is not named', () async {
      final one = await _fleet(
        {
          'a': [_pane(1, 'working')],
        },
        title: (_) => 'Fix the retry test',
        cwd: (_) => '/src/payments-api',
      );
      final several = await _fleet(
        {
          'a': [_pane(1, 'working')],
          'b': const [],
        },
        title: (_) => 'Fix the retry test',
        cwd: (_) => '/src/payments-api',
      );
      addTearDown(one.dispose);
      addTearDown(several.dispose);

      final solo = AgentsOverview.of(one.fleet).agents.single;
      expect(solo.subtitle, 'Claude Code · payments-api');
      final multi = AgentsOverview.of(several.fleet).agents.single;
      expect(multi.subtitle, 'Claude Code · m-a · payments-api');
    });

    test('a pane with no title is named after its agent, which the line then omits', () async {
      final h = await _fleet(
        {
          'a': [_pane(1, 'idle', agent: 'codex')],
        },
        title: (_) => '',
        cwd: (_) => '/src/main',
      );
      addTearDown(h.dispose);

      final rows = AgentsOverview.of(h.fleet).agents;
      expect(rows.single.title, 'Codex');
      expect(rows.single.subtitle, 'main', reason: 'workspace and folder are the same name');
    });

    test('equal data is an equal overview, so an unchanged tab does not rebuild', () async {
      final h = await _fleet({
        'a': [_pane(1, 'blocked'), _pane(2, 'done')],
      });
      addTearDown(h.dispose);

      expect(AgentsOverview.of(h.fleet), AgentsOverview.of(h.fleet));
      expect(AgentsOverview.of(h.fleet).hashCode, AgentsOverview.of(h.fleet).hashCode);
    });
  });

  group('troubled machines', () {
    test('a machine the person disabled is not a problem', () async {
      final h = await _fleet(
        {
          'a': [_pane(1, 'working')],
          'b': [_pane(1, 'working')],
        },
        disabled: {'b'},
      );
      addTearDown(h.dispose);

      expect(h.fleet.connections.last.state, LinkState.disabled);
      expect(AgentsOverview.of(h.fleet).troubled, isEmpty);
    });

    test('one that fails is, with its reason', () async {
      final h = await _fleet({
        'a': [_pane(1, 'working')],
        'b': [_pane(1, 'working')],
      });
      addTearDown(h.dispose);
      h.transports['b']!.failure = HerdrTransportException('Host key changed', fatal: true);
      h.fleet.connections.last.reconnect();
      await pumpEventQueue(times: 50);

      final troubled = AgentsOverview.of(h.fleet).troubled.single;
      expect(troubled.label, 'm-b');
      expect(troubled.state, LinkState.attention);
      expect(troubled.error, 'Host key changed');
    });

    test('the worst state colours a summary', () {
      expect(worstLinkState([LinkState.offline, LinkState.attention, LinkState.reconnecting]), LinkState.attention);
      expect(worstLinkState([LinkState.offline, LinkState.connecting]), LinkState.connecting);
    });
  });

  group('entries', () {
    late UiHarness h;
    late MachineConnection m;
    late Map<AgentStatus, List<AgentRowData>> groups;

    // Terminal rows only: each group is a section that counts every row.
    List<BoardSection> sections(Map<AgentStatus, List<AgentRowData>> g) => [
      for (final MapEntry(key: status, value: rows) in g.entries)
        BoardSection(status, [for (final r in rows) PaneItem(r)], count: rows.length),
    ];

    setUp(() async {
      h = await _fleet({'a': const []});
      m = h.fleet.connections.single;
      groups = groupByStatus([
        _row('1', AgentStatus.blocked, m),
        _row('2', AgentStatus.blocked, m),
        _row('3', AgentStatus.working, m),
        _row('4', AgentStatus.idle, m),
      ]);
    });
    tearDown(() => h.dispose());

    test('groups are in urgency order and empty ones are left out', () {
      expect(groups.keys, [AgentStatus.blocked, AgentStatus.working, AgentStatus.idle]);
    });

    test('a header per group, then its rows, the last one marked', () {
      final e = agentEntries(sections(groups));
      expect(e.map((x) => x is AgentHeader ? 'h' : 'r'), ['h', 'r', 'r', 'h', 'r', 'h', 'r']);
      expect(
        [
          for (final x in e)
            if (x is AgentLine) x.last,
        ],
        [false, true, true, true],
      );
    });

    test('a filter keeps one group; one whose group is gone keeps all', () {
      final one = agentEntries(sections(groups), filter: AgentStatus.working);
      expect(one.whereType<AgentHeader>().map((h) => h.status), [AgentStatus.working]);
      final all = agentEntries(sections(groups), filter: AgentStatus.done);
      expect(all.whereType<AgentHeader>(), hasLength(3));
    });

    test('a collapsed group keeps its rows in the list, closed', () {
      final e = agentEntries(sections(groups), collapsed: {AgentStatus.blocked});
      final header = e.whereType<AgentHeader>().first;
      expect(header.expanded, isFalse);
      final lines = e.whereType<AgentLine>().toList();
      expect(lines.take(2).every((l) => !l.open), isTrue);
      expect(lines.skip(2).every((l) => l.open), isTrue);
    });

    test('keys are unique, and a group keeps its key when others come and go', () {
      final e = agentEntries(sections(groups));
      expect(e.map((x) => x.key).toSet(), hasLength(e.length));

      final without = agentEntries(sections(groupByStatus([_row('3', AgentStatus.working, m)])));
      expect(without.first.key, ValueKey(AgentStatus.working));
      expect(entryIndexes(without)[ValueKey(AgentStatus.working)], 0);
      expect(entryIndexes(e)[ValueKey(AgentStatus.working)], 3);
    });
  });

  group('time in state', () {
    test('is minutes, then hours, then days: never seconds', () {
      expect(Elapsed.compact(Duration.zero, seconds: false), '<1m');
      expect(Elapsed.compact(const Duration(seconds: 59), seconds: false), '<1m');
      expect(Elapsed.compact(const Duration(seconds: 60), seconds: false), '1m');
      expect(Elapsed.compact(const Duration(minutes: 12, seconds: 59), seconds: false), '12m');
      expect(Elapsed.compact(const Duration(minutes: 59, seconds: 59), seconds: false), '59m');
      expect(Elapsed.compact(const Duration(hours: 1), seconds: false), '1h');
      expect(Elapsed.compact(const Duration(hours: 1, minutes: 5), seconds: false), '1h 05m');
      expect(Elapsed.compact(const Duration(hours: 23, minutes: 59), seconds: false), '23h 59m');
      expect(Elapsed.compact(const Duration(hours: 24), seconds: false), '1d');
      expect(Elapsed.compact(const Duration(days: 3, hours: 7), seconds: false), '3d');
    });

    test('a clock that stepped back (a set-back device clock) never shows a negative', () {
      expect(Elapsed.compact(const Duration(minutes: -5), seconds: false), '<1m');
    });

    test('is the time only (the glyph says the state); unknown claims nothing', () {
      const d = Duration(minutes: 12);
      expect(timeInState(AgentStatus.working, d), '12m');
      expect(timeInState(AgentStatus.blocked, const Duration(minutes: 3)), '3m');
      expect(timeInState(AgentStatus.done, const Duration(hours: 2)), '2h');
      expect(timeInState(AgentStatus.idle, d), '12m');
      expect(timeInState(AgentStatus.unknown, d), '');
    });

    test('screen readers hear the state and the time in words', () {
      expect(timeInStateWords(AgentStatus.blocked, const Duration(minutes: 4)), 'needs you, 4 minutes');
      expect(timeInStateWords(AgentStatus.done, const Duration(hours: 2), exact: false), 'done, at most 2 hours');
      expect(timeInStateWords(AgentStatus.working, const Duration(seconds: 20)), 'working, under a minute');
      expect(timeInStateWords(AgentStatus.unknown, const Duration(minutes: 4)), '');
    });
  });

  group('board sections', () {
    test('Needs you counts and orders what can be answered; the offline one is listed last, not counted', () async {
      final h = await _fleet({
        'a': [_pane(1, 'blocked'), _pane(2, 'working'), _pane(3, 'blocked')],
        'b': [_pane(4, 'blocked')],
      });
      final attention = AttentionSet(fleet: h.fleet);
      h.fleet.connection('b')!.goOffline();
      final rows = AgentsOverview.of(h.fleet).agents;

      final blocked = boardSections(rows, const [], attention).first;
      expect(blocked.status, AgentStatus.blocked);
      expect(blocked.count, 2, reason: 'offline "needs you" cannot be answered');
      expect(blocked.offline, 1);
      expect(
        [for (final i in blocked.items) (i as PaneItem).row.key],
        [...attention.needsYou.map((i) => i.key), 'b/w1:p4'],
        reason: 'the set\'s order first, then what is out of reach',
      );
      attention.dispose();
      h.dispose();
    });
  });

  group('Idle, panes and sessions together', () {
    final noon = DateTime.utc(2026, 1, 1, 12);

    test(
      'a session the person used ten minutes ago is not under the panes: all by when they last did something',
      () async {
        final h = await _fleet({'a': const []});
        final machine = h.fleet.connections.single;
        final attention = AttentionSet(fleet: h.fleet);
        AgentRowData pane(String key, StatusTime? since) => (
          key: key,
          machine: machine,
          paneId: key,
          status: AgentStatus.idle,
          title: key,
          subtitle: '',
          stale: false,
          since: since,
          quietMinutes: 0,
        );
        FakeAgentSession session(String key, DateTime? activity) =>
            FakeAgentSession(key: key, machine: machine)..lastActivity = activity;

        final sections = boardSections(
          [
            pane('pane-3h', StatusTime.exact(noon.subtract(const Duration(hours: 3)))),
            pane('pane-undated', null),
            pane('pane-5d', StatusTime.exact(noon.subtract(const Duration(days: 5)))),
          ],
          [
            session('s-3d', noon.subtract(const Duration(days: 3))),
            session('s-10m', noon.subtract(const Duration(minutes: 10))),
            session('s-undated', null),
          ],
          attention,
          now: noon,
        );

        final idle = sections.singleWhere((s) => s.status == AgentStatus.idle);
        expect(
          [
            for (final i in idle.items)
              switch (i) {
                PaneItem(:final row) => row.key,
                SessionItem(:final session) => session.key,
              },
          ],
          ['s-10m', 'pane-3h', 'pane-undated', 's-undated', 's-3d', 'pane-5d'],
          reason: 'recent first, mixed; the undated panes then sessions; then the old, newest first',
        );
        attention.dispose();
        h.dispose();
      },
    );
  });

  group('the Idle fold', () {
    late UiHarness h;
    late MachineConnection machine;

    setUp(() async {
      h = await _fleet({'a': const []});
      machine = h.fleet.connections.single;
    });

    tearDown(() => h.dispose());

    BoardSection section(AgentStatus status, int n) =>
        BoardSection(status, [for (var i = 0; i < n; i++) PaneItem(_row('k$i', status, machine))], count: n);

    List<AgentMore> folds(List<AgentEntry> entries) => entries.whereType<AgentMore>().toList();
    List<bool> open(List<AgentEntry> entries) => [
      for (final e in entries)
        if (e is AgentLine) e.open,
    ];

    test('up to a row more than it shows, nothing folds: one hidden row is no saving', () {
      for (final n in [1, idleShown, idleShown + 1]) {
        final entries = agentEntries([section(AgentStatus.idle, n)]);
        expect(folds(entries), isEmpty, reason: '$n idle');
        expect(open(entries), everyElement(isTrue), reason: '$n idle');
      }
    });

    test('past that, the first rows show and the rest sit behind one line that says how many and what', () {
      final entries = agentEntries([section(AgentStatus.idle, 9)]);

      expect(open(entries), [...List.filled(idleShown, true), ...List.filled(4, false)]);
      final more = folds(entries).single;
      expect(more.hidden, 4);
      expect(more.names, ['k$idleShown', 'k${idleShown + 1}'], reason: 'the first two it holds, so it is not a guess');
      expect(more.open, isFalse);
      expect(entries.indexOf(more), 1 + idleShown, reason: 'header, then the rows that show, then the fold');
    });

    test('open, every row shows and the line moves to the end and reads Show less', () {
      final entries = agentEntries([section(AgentStatus.idle, 9)], idleOpen: true);

      expect(open(entries), everyElement(isTrue));
      expect(entries.last, isA<AgentMore>().having((m) => m.open, 'open', isTrue));
      expect(folds(entries), hasLength(1));
    });

    test('the Idle chip asks for exactly those rows: they all show, with no fold', () {
      final entries = agentEntries([section(AgentStatus.idle, 9)], filter: AgentStatus.idle);

      expect(folds(entries), isEmpty);
      expect(open(entries), everyElement(isTrue));
    });

    test('a folded section has no fold line, and Idle is the only section that folds', () {
      final closed = agentEntries([section(AgentStatus.idle, 9)], collapsed: {AgentStatus.idle});
      expect(folds(closed), isEmpty);
      expect(open(closed), everyElement(isFalse));

      for (final s in [AgentStatus.working, AgentStatus.done, AgentStatus.blocked]) {
        expect(folds(agentEntries([section(s, 12)])), isEmpty, reason: s.name);
      }
    });
  });

  // The working glyph does not say quiet, so the row must: a bare `14m` would
  // look like an agent that started 14 minutes ago.
  testWidgets('a quiet working agent says quiet on the row, not only to a screen reader', (tester) async {
    final h = (await tester.runAsync(() => _fleet({'a': const []})))!;
    addTearDown(h.dispose);
    final row = _row('1', AgentStatus.working, h.fleet.connections.single);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: StateTime(
            agent: (
              key: row.key,
              machine: row.machine,
              paneId: row.paneId,
              status: row.status,
              title: row.title,
              subtitle: row.subtitle,
              stale: false,
              since: null,
              quietMinutes: 14,
            ),
          ),
        ),
      ),
    );
    expect(find.textContaining('quiet'), findsOneWidget);
    expect(find.textContaining('14m'), findsOneWidget);
  });
}
