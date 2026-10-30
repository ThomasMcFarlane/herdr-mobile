// What the board lists, derived from the fleet without any widgets.
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/words/elapsed.dart';
import 'package:herdr_mobile/data/models/herdr_models.dart' show AgentStatus;
import 'package:herdr_mobile/data/models/worktrees.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/models/places.dart';
import 'package:herdr_mobile/data/models/status_time.dart';
import 'package:herdr_mobile/data/repositories/attention_set.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:flutter/material.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/features/agents/agent_card.dart' show StateTime;
import 'package:herdr_mobile/ui/features/agents/agents_grouping.dart';

import '../support/fake_agent_session.dart';
import '../support/worktree_fixtures.dart';
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

    BoardGroup group(String key, List<AgentRowData> rows) => BoardGroup(
      key: key,
      label: key,
      machine: m,
      rows: [for (final r in rows) (item: PaneItem(r), where: 'where-${r.key}')],
    );

    BoardLayout layout() => BoardLayout(
      needsYou: [PaneItem(_row('1', AgentStatus.blocked, m)), PaneItem(_row('2', AgentStatus.blocked, m))],
      needsYouCount: 2,
      groups: [
        group('app', [_row('3', AgentStatus.working, m)]),
        group('notes', [_row('4', AgentStatus.idle, m)]),
      ],
    );

    setUp(() async {
      h = await _fleet({'a': const []});
      m = h.fleet.connections.single;
    });
    tearDown(() => h.dispose());

    test('Needs you first, then a header per project and its rows, the last one of each marked', () {
      final e = boardEntries(layout());
      expect(
        e.map(
          (x) => switch (x) {
            NeedsYouHeader() => 'n',
            GroupHeader(:final group) => 'g:${group.key}',
            _ => 'r',
          },
        ),
        ['n', 'r', 'r', 'g:app', 'r', 'g:notes', 'r'],
      );
      expect(
        [
          for (final x in e)
            if (x is AgentLine) x.last,
        ],
        [false, true, true, true],
      );
    });

    test('a row inside a project says its own line there, not the repo again', () {
      final e = boardEntries(layout());
      final inGroup = e.whereType<AgentLine>().where((l) => l.agent.status != AgentStatus.blocked);
      expect([for (final l in inGroup) l.agent.subtitle], ['where-3', 'where-4']);
    });

    test('a folded project keeps its rows in the list, closed; the others stay open', () {
      final e = boardEntries(layout(), collapsed: {'app'});
      final header = e.whereType<GroupHeader>().firstWhere((h) => h.group.key == 'app');
      expect(header.expanded, isFalse);
      expect([for (final l in e.whereType<AgentLine>()) l.open], [true, true, false, true]);
    });

    test('Needs you has no fold: its rows are open whatever is folded', () {
      final e = boardEntries(layout(), collapsed: {'app', 'notes'});
      expect(e.first, isA<NeedsYouHeader>());
      expect(e.whereType<AgentLine>().take(2).every((l) => l.open), isTrue);
    });

    test('only the first waiting agent is in front', () {
      final e = boardEntries(layout());
      expect([for (final l in e.whereType<AgentLine>()) l.front], [true, false, false, false]);
    });

    test('keys are unique, and a project keeps its key when others come and go', () {
      final e = boardEntries(layout());
      expect(e.map((x) => x.key).toSet(), hasLength(e.length));

      final without = boardEntries(
        BoardLayout(
          groups: [
            group('notes', [_row('4', AgentStatus.idle, m)]),
          ],
        ),
      );
      const notes = ValueKey('group/notes');
      expect(entryIndexes(without)[notes], 0);
      expect(entryIndexes(e)[notes], 5);
    });

    test('a To review line sits above the projects while anything finished waits', () {
      final e = boardEntries(
        BoardLayout(
          toReviewCount: 2,
          groups: [
            group('app', [_row('5', AgentStatus.done, m)]),
          ],
        ),
      );
      expect(e.first, isA<ReviewHeader>().having((r) => r.count, 'count', 2));
      expect(boardEntries(layout()).whereType<ReviewHeader>(), isEmpty);
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

  group('Needs you', () {
    test('counts and orders what can be answered; the offline one is listed last, not counted', () async {
      final h = await _fleet({
        'a': [_pane(1, 'blocked'), _pane(2, 'working'), _pane(3, 'blocked')],
        'b': [_pane(4, 'blocked')],
      });
      final attention = AttentionSet(fleet: h.fleet);
      h.fleet.connection('b')!.goOffline();
      final rows = AgentsOverview.of(h.fleet).agents;

      final layout = boardLayout(rows, const [], attention);
      expect(layout.needsYouCount, 2, reason: 'offline "needs you" cannot be answered');
      expect(layout.needsYouOffline, 1);
      expect(
        [for (final i in layout.needsYou) (i as PaneItem).row.key],
        [...attention.needsYou.map((i) => i.key), 'b/w1:p4'],
        reason: 'the set\'s order first, then what is out of reach',
      );
      expect(
        [for (final g in layout.groups) ...g.items.map((i) => (i as PaneItem).row.key)],
        ['a/w1:p2'],
        reason: 'a waiting agent is pinned above, not also listed in its project',
      );
      attention.dispose();
      h.dispose();
    });
  });

  group('projects', () {
    // One repo (`app`) with its primary checkout and two linked worktrees,
    // a plain folder (`notes`) and a pane with no folder.
    const primary = '/r/app';
    const login = '/wt/app-login';
    const search = '/wt/app-search';
    const workspaces = [
      (id: 'w1', label: 'app'),
      (id: 'w2', label: 'app-login'),
      (id: 'w3', label: 'app-search'),
      (id: 'w4', label: 'notes'),
    ];

    Map<String, Object> provenance(String path, {required bool linked}) => {
      'checkout_path': path,
      'is_linked_worktree': linked,
      'repo_key': '$primary/.git',
      'repo_name': 'app',
      'repo_root': primary,
    };

    void group(Map<String, dynamic> snapshot) {
      const checkouts = {'w1': (primary, false), 'w2': (login, true), 'w3': (search, true)};
      for (final w in snapshot['workspaces'] as List) {
        final ws = w as Map<String, dynamic>;
        if (checkouts[ws['workspace_id']] case (final path, final linked)?) {
          ws['worktree'] = provenance(path, linked: linked);
        }
      }
    }

    Future<UiHarness> repoFleet(List<Pane> panes, Map<String, String?> cwd, {bool known = true}) async {
      final snapshot = snapshotWith(panes, workspaces: workspaces, title: (id) => 'task ${id.split(':').last}');
      for (final p in snapshot['panes'] as List) {
        final pane = p as Map<String, dynamic>;
        pane['cwd'] = cwd[pane['pane_id']];
      }
      if (known) group(snapshot);
      final h = await UiHarness.create([(profile: _machine('a', 'm-a'), snapshot: snapshot)]);
      await pumpEventQueue(times: 50);
      return h;
    }

    Pane at(String id, String ws, String status) => (id: id, ws: ws, agent: 'claude', status: status);

    BoardLayout layoutOf(UiHarness h) {
      final attention = AttentionSet(fleet: h.fleet);
      addTearDown(attention.dispose);
      return boardLayout(AgentsOverview.of(h.fleet).agents, const [], attention);
    }

    List<String> idsOf(BoardGroup g) => [for (final i in g.items) (i as PaneItem).row.paneId];

    test(
      'every worktree of a repo is one group, named by the repo; a plain folder is its own; no folder is Other',
      () async {
        final h = await repoFleet(
          [
            at('w1:p1', 'w1', 'working'),
            at('w2:p2', 'w2', 'done'),
            at('w3:p3', 'w3', 'idle'),
            at('w4:p4', 'w4', 'working'),
            at('w4:p5', 'w4', 'idle'),
          ],
          {'w1:p1': primary, 'w2:p2': login, 'w3:p3': '$search/lib', 'w4:p4': '/src/notes', 'w4:p5': null},
        );
        addTearDown(h.dispose);

        final groups = {for (final g in layoutOf(h).groups) g.label: g};
        expect(groups.keys.toSet(), {'app', 'notes', otherGroupLabel});
        expect(idsOf(groups['app']!), ['w1:p1', 'w2:p2', 'w3:p3'], reason: 'working, then done, then idle');
        expect(idsOf(groups['notes']!), ['w4:p4']);
        expect(idsOf(groups[otherGroupLabel]!), ['w4:p5']);
        expect(groupSummary(groups['app']!), '1 working · 1 done · 1 idle · 3 worktrees');
      },
    );

    test('projects with work running come first, then finished ones, then idle ones', () async {
      final h = await repoFleet(
        [at('w4:p5', 'w4', 'idle'), at('w1:p1', 'w1', 'done'), at('w2:p2', 'w2', 'idle'), at('w4:p4', 'w4', 'idle')],
        {'w4:p5': null, 'w1:p1': primary, 'w2:p2': login, 'w4:p4': '/src/notes'},
      );
      addTearDown(h.dispose);
      expect(
        [for (final g in layoutOf(h).groups) g.label].first,
        'app',
        reason: 'its finished agent outranks idle ones',
      );

      h.transports['a']!.snapshot['panes'] = [
        for (final p in h.transports['a']!.snapshot['panes'] as List)
          if ((p as Map<String, dynamic>)['pane_id'] == 'w4:p4') {...p, 'agent_status': 'working'} else p,
      ];
      // Read now, as the event's refresh would after its delay.
      await h.fleet.connections.single.refresh();
      await pumpEventQueue(times: 50);
      expect([for (final g in layoutOf(h).groups) g.label], ['notes', 'app', otherGroupLabel]);
    });

    test('a row is named by its branch once read, else its checkout; the repo is left to the header', () async {
      final h = await repoFleet(
        [at('w1:p1', 'w1', 'working'), at('w2:p2', 'w2', 'working')],
        {'w1:p1': primary, 'w2:p2': login},
      );
      addTearDown(h.dispose);
      String whereOf(String id) =>
          layoutOf(h).groups.single.rows.firstWhere((r) => (r.item as PaneItem).row.paneId == id).where;

      expect(whereOf('w1:p1'), 'Claude Code', reason: 'the primary checkout is the group\'s own name');
      expect(whereOf('w2:p2'), 'app-login · Claude Code');

      h.fleet.connections.single.noteBranches(const [
        WorktreeInfo(path: primary, label: 'app', isLinked: false, branch: 'main'),
        WorktreeInfo(path: login, label: 'app-login', isLinked: true, branch: 'feat/login'),
      ]);
      expect(whereOf('w1:p1'), 'main · Claude Code');
      expect(whereOf('w2:p2'), 'feat/login · Claude Code');
    });

    test('an agent in the primary checkout keeps its group when herdr starts grouping the repo', () async {
      final h = await repoFleet(
        [at('w1:p1', 'w1', 'working'), at('w2:p2', 'w2', 'working')],
        {'w1:p1': primary, 'w2:p2': login},
        known: false,
      );
      addTearDown(h.dispose);
      String keyOf(String id) => layoutOf(h).groups.firstWhere((g) => idsOf(g).contains(id)).key;

      final before = keyOf('w1:p1');
      expect(layoutOf(h).groups, hasLength(2), reason: 'two plain folders until herdr says they are one repo');

      group(h.transports['a']!.snapshot);
      // Read now, as the event's refresh would after its delay.
      await h.fleet.connections.single.refresh();
      await pumpEventQueue(times: 50);

      expect(keyOf('w1:p1'), before, reason: 'its folder is the repo\'s root: same key before and after');
      expect(keyOf('w2:p2'), before, reason: 'the worktree joins it, once');
      expect(layoutOf(h).groups.single.label, 'app');
    });

    test('the key: the repo\'s root when known, else the folder itself, else Other; always per machine', () {
      final known = PlaceIndex.of(
        snapshotOf(
          workspaces: [
            wireWorkspace('w1', worktree: wirePrimaryWorktree),
            wireWorkspace('w2', worktree: wireLinkedWorktree),
          ],
        ),
      );
      final none = PlaceIndex.of(snapshotOf(workspaces: [wireWorkspace('w1')]));
      final root = wirePrimaryWorktree['checkout_path'] as String;
      final linked = wireLinkedWorktree['checkout_path'] as String;

      expect(repoKeyIn('a', known, '$linked/lib'), (key: 'a:$root', label: 'herdr-mobile', repo: '$root/.git'));
      expect(repoKeyIn('a', none, root).key, repoKeyIn('a', known, root).key);
      expect(
        repoKeyIn('a', none, '$root/').key,
        repoKeyIn('a', none, root).key,
        reason: 'a trailing slash is the same folder',
      );
      expect(repoKeyIn('a', none, root).label, 'herdr-mobile');
      expect(repoKeyIn('a', none, null), (key: 'a:', label: otherGroupLabel, repo: null));
      expect(repoKeyIn('a', none, '  '), (key: 'a:', label: otherGroupLabel, repo: null));
      expect(repoKeyIn('b', known, root).key, isNot(repoKeyIn('a', known, root).key));
    });

    test('the summary names the machine when the board spans several, and says what is quiet or offline', () async {
      final h = await _fleet({'a': const []});
      addTearDown(h.dispose);
      final m = h.fleet.connections.single;
      AgentRowData quiet(String key) => (
        key: key,
        machine: m,
        paneId: key,
        status: AgentStatus.working,
        title: key,
        subtitle: '',
        stale: false,
        since: null,
        quietMinutes: 14,
      );
      final stale = _row('s', AgentStatus.done, m);
      final g = BoardGroup(
        key: 'k',
        label: 'app',
        machine: m,
        rows: [
          (item: PaneItem(quiet('q')), where: ''),
          (item: PaneItem(_row('w', AgentStatus.working, m)), where: ''),
          (
            item: PaneItem((
              key: stale.key,
              machine: m,
              paneId: stale.paneId,
              status: stale.status,
              title: stale.title,
              subtitle: '',
              stale: true,
              since: null,
              quietMinutes: 0,
            )),
            where: '',
          ),
        ],
      );
      expect(groupSummary(g), '2 working · 1 quiet · 1 offline');
      expect(groupSummary(g, showMachine: true), 'm-a · 2 working · 1 quiet · 1 offline');
    });
  });

  group('inside a project, idle panes and sessions together', () {
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
        // No folder, like the panes above: one group.
        FakeAgentSession session(String key, DateTime? activity) =>
            FakeAgentSession(key: key, machine: machine, cwd: '')..lastActivity = activity;

        final layout = boardLayout(
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

        expect(
          [
            for (final i in layout.groups.single.items)
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

  group('the idle fold', () {
    late UiHarness h;
    late MachineConnection machine;

    setUp(() async {
      h = await _fleet({'a': const []});
      machine = h.fleet.connections.single;
    });

    tearDown(() => h.dispose());

    BoardGroup group(String key, AgentStatus status, int n, {int working = 0}) => BoardGroup(
      key: key,
      label: key,
      machine: machine,
      rows: [
        for (var i = 0; i < working; i++) (item: PaneItem(_row('$key-w$i', AgentStatus.working, machine)), where: ''),
        for (var i = 0; i < n; i++) (item: PaneItem(_row('$key-k$i', status, machine)), where: ''),
      ],
    );

    List<AgentEntry> entries(
      List<BoardGroup> groups, {
      Set<String> collapsed = const {},
      Set<String> openFolds = const {},
    }) => boardEntries(
      BoardLayout(groups: groups),
      collapsed: collapsed,
      openFolds: openFolds,
    );

    List<AgentMore> folds(List<AgentEntry> entries) => entries.whereType<AgentMore>().toList();
    List<bool> open(List<AgentEntry> entries) => [
      for (final e in entries)
        if (e is AgentLine) e.open,
    ];

    test('up to a row more than it shows, nothing folds: one hidden row is no saving', () {
      for (final n in [1, idleShown, idleShown + 1]) {
        final e = entries([group('app', AgentStatus.idle, n)]);
        expect(folds(e), isEmpty, reason: '$n idle');
        expect(open(e), everyElement(isTrue), reason: '$n idle');
      }
    });

    test('past that, the first idle rows show and the rest sit behind one line that says how many and what', () {
      final e = entries([group('app', AgentStatus.idle, 9, working: 2)]);

      expect(open(e), [true, true, ...List.filled(idleShown, true), ...List.filled(4, false)]);
      final more = folds(e).single;
      expect(more.hidden, 4);
      expect(more.kind, 'idle');
      expect(more.names, [
        'app-k$idleShown',
        'app-k${idleShown + 1}',
      ], reason: 'the first two it holds, so it is not a guess');
      expect(more.open, isFalse);
      expect(
        e.indexOf(more),
        1 + 2 + idleShown,
        reason: 'header, the working rows, the idle rows that show, then the fold',
      );
    });

    test('each project has its own fold: opening one leaves the other folded', () {
      final e = entries([group('app', AgentStatus.idle, 9), group('notes', AgentStatus.idle, 9)], openFolds: {'app'});

      final byGroup = {for (final m in folds(e)) m.groupKey: m};
      expect(byGroup['app']!.open, isTrue);
      expect(byGroup['notes']!.open, isFalse);
      expect(
        e.indexOf(byGroup['app']!),
        e.indexWhere((x) => x is GroupHeader && x.group.key == 'notes') - 1,
        reason: 'open, it reads Show less at the end of its own rows',
      );
    });

    test('a folded project has no fold line, and working or finished rows never fold', () {
      final closed = entries([group('app', AgentStatus.idle, 9)], collapsed: {'app'});
      expect(folds(closed), isEmpty);
      expect(open(closed), everyElement(isFalse));

      for (final s in [AgentStatus.working, AgentStatus.done]) {
        expect(folds(entries([group('app', s, 12)])), isEmpty, reason: s.name);
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
