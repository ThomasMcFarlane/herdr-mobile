import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/herdr_models.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/observed/omp_kind.dart' show ompWaitsOnPlanReview;
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/repositories/screen_waits.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';

import 'support/fake_transport.dart';
import 'support/omp_ask_fixtures.dart';

const _profile = MachineProfile(id: 'm', label: 'box', host: 'h', username: 'u');

/// A transport whose panes all show [screen].
class _Screens extends FakeTransport {
  _Screens(super.snapshot, this.screen);

  String screen;

  int get reads => calls.where((c) => c.$1 == 'pane.read').length;

  @override
  Future<Map<String, dynamic>> request(String method, [Map<String, dynamic> params = const {}]) async {
    if (method == 'pane.read') {
      calls.add((method, params));
      return {
        'type': 'pane_read',
        'read': {'text': screen},
      };
    }
    return super.request(method, params);
  }
}

MachineConnection _connect(FakeTransport t) => MachineConnection(
      profile: _profile,
      api: HerdrApi(t),
      pollInterval: const Duration(hours: 1),
      screenWaits: const {'omp': ompWaitsOnPlanReview},
    );

Map<String, dynamic> _snapshot(String status, {String agent = 'omp'}) => snapshotJson(
      panes: [(id: 'w1:p1', ws: 'w1', agent: agent, status: status)],
    );

/// The fake clock of [async] (`DateTime.now` is not faked by `fakeAsync`).
DateTime Function() _clockOf(FakeAsync async) => () => async.getClock(DateTime(2026)).now();

void main() {
  final review = fixtureScreen('plan-review');

  group('an omp pane herdr calls finished while the plan review is open', () {
    test('shows as blocked, with its workspace and tab, so the board and alerts see it', () async {
      final t = _Screens(_snapshot('done'), review);
      final c = _connect(t)..start();
      addTearDown(c.dispose);

      await eventually(() => c.snapshot.agentPanes.firstOrNull?.status == AgentStatus.blocked, reason: 'blocked');
      expect(c.snapshot.workspaces.single.status, AgentStatus.blocked);
      expect(c.snapshot.tabs.single.status, AgentStatus.blocked);
    });

    test('an idle one too: that is the status herdr had in the capture', () async {
      final t = _Screens(_snapshot('idle'), review);
      final c = _connect(t)..start();
      addTearDown(c.dispose);

      await eventually(() => c.snapshot.agentPanes.firstOrNull?.status == AgentStatus.blocked, reason: 'blocked');
    });

    test('is not blocked once the agent works again', () async {
      final t = _Screens(_snapshot('done'), review);
      final c = _connect(t)..start();
      addTearDown(c.dispose);
      await eventually(() => c.snapshot.agentPanes.firstOrNull?.status == AgentStatus.blocked, reason: 'blocked');

      t.snapshot = _snapshot('working');
      t.emit({'event': 'pane.agent_status_changed'});
      await eventually(() => c.snapshot.agentPanes.firstOrNull?.status == AgentStatus.working, reason: 'working');
      expect(c.snapshot.workspaces.single.status, isNot(AgentStatus.blocked));
    });
  });

  group('panes that are not waiting are left alone', () {
    test('a finished omp turn with no review on screen stays done', () async {
      final t = _Screens(_snapshot('done'), fixtureScreen('ask-single').replaceAll('Ask', 'Result'));
      final c = _connect(t)..start();
      addTearDown(c.dispose);
      await eventually(() => c.isLive && t.reads > 0, reason: 'read');
      expect(c.snapshot.agentPanes.single.status, AgentStatus.done);
    });

    test('another agent is not read at all, and neither is a working pane', () async {
      final claude = _Screens(_snapshot('done', agent: 'claude'), review);
      final a = _connect(claude)..start();
      addTearDown(a.dispose);
      final working = _Screens(_snapshot('working'), review);
      final b = _connect(working)..start();
      addTearDown(b.dispose);
      await eventually(() => a.isLive && b.isLive, reason: 'online');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(claude.reads, 0);
      expect(working.reads, 0);
      expect(a.snapshot.agentPanes.single.status, AgentStatus.done);
    });
  });

  group('ScreenWaits timing', () {
    Pane pane(String status) => Pane.fromJson({
          'pane_id': 'p',
          'workspace_id': 'w',
          'tab_id': 't',
          'agent': 'omp',
          'agent_status': status,
        });

    test('the review that opens a moment after the status turns is found by the second read', () {
      fakeAsync((async) {
        var screen = '';
        var changes = 0;
        final waits = ScreenWaits(
          readers: {'omp': ompWaitsOnPlanReview},
          read: (_) async => screen,
          onChange: () => changes++,
          clock: _clockOf(async),
        );
        addTearDown(waits.dispose);
        waits.update([pane('done')]);
        async.flushMicrotasks();
        expect(waits.panes, isEmpty);

        screen = review;
        async.elapse(const Duration(seconds: 2));
        expect(waits.panes, {'p'});
        expect(changes, 1);
      });
    });

    test('a review dismissed in the terminal stops counting once the pane shows activity', () {
      fakeAsync((async) {
        var screen = review;
        var changes = 0;
        final waits = ScreenWaits(
          readers: {'omp': ompWaitsOnPlanReview},
          read: (_) async => screen,
          onChange: () => changes++,
          clock: _clockOf(async),
        );
        addTearDown(waits.dispose);
        waits.update([pane('done')]);
        async.flushMicrotasks();
        expect(waits.panes, {'p'});

        screen = '';
        waits.touch('p');
        async.elapse(const Duration(seconds: 1));
        expect(waits.panes, isEmpty);
        expect(changes, 2);
      });
    });

    test('a review opened again after it was dismissed is found on the pane\'s next activity', () {
      fakeAsync((async) {
        var screen = review;
        final waits = ScreenWaits(
          readers: {'omp': ompWaitsOnPlanReview},
          read: (_) async => screen,
          onChange: () {},
          clock: _clockOf(async),
        );
        addTearDown(waits.dispose);
        waits.update([pane('done')]);
        async.flushMicrotasks();
        screen = '';
        waits.touch('p');
        async.elapse(const Duration(seconds: 3));
        expect(waits.panes, isEmpty);

        screen = review;
        waits.touch('p');
        async.elapse(const Duration(seconds: 1));
        expect(waits.panes, {'p'});
      });
    });

    test('a read that failed is tried again on the next refresh', () {
      fakeAsync((async) {
        var fail = true;
        var reads = 0;
        final waits = ScreenWaits(
          readers: {'omp': ompWaitsOnPlanReview},
          read: (_) async {
            reads++;
            if (fail) throw StateError('link blip');
            return review;
          },
          onChange: () {},
          clock: _clockOf(async),
        );
        addTearDown(waits.dispose);
        waits.update([pane('done')]);
        async.flushMicrotasks();
        expect(waits.panes, isEmpty);

        fail = false;
        waits.update([pane('done')]);
        async.flushMicrotasks();
        expect(waits.panes, {'p'});
        expect(reads, 2);
      });
    });

    test('a pane that keeps showing the review is not read on every refresh', () {
      fakeAsync((async) {
        var reads = 0;
        final waits = ScreenWaits(
          readers: {'omp': ompWaitsOnPlanReview},
          read: (_) async {
            reads++;
            return review;
          },
          onChange: () {},
          clock: _clockOf(async),
        );
        addTearDown(waits.dispose);
        waits.update([pane('done')]);
        async.flushMicrotasks();
        for (var i = 0; i < 5; i++) {
          async.elapse(const Duration(seconds: 2));
          waits.update([pane('done')]);
        }
        expect(reads, 1);
        async.elapse(const Duration(seconds: 10));
        waits.update([pane('done')]);
        async.flushMicrotasks();
        expect(reads, 2);
      });
    });

    test('an answer sent by keys is followed by a read, so a closed review stops showing', () {
      fakeAsync((async) {
        var screen = review;
        final waits = ScreenWaits(
          readers: {'omp': ompWaitsOnPlanReview},
          read: (_) async => screen,
          onChange: () {},
          clock: _clockOf(async),
        );
        addTearDown(waits.dispose);
        waits.update([pane('done')]);
        async.flushMicrotasks();
        screen = '';
        waits.answered('p');
        async.elapse(const Duration(seconds: 1));
        expect(waits.panes, isEmpty);
      });
    });
  });
}
