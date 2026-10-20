// The `Checkout` choice of the new-agent-session form: what a folder's repo
// offers, and the create-then-start sequence of a new worktree.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/agent_host.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/ui/features/create/new_agent_session_view_model.dart';

import '../support/create_harness.dart';
import '../support/fake_agent_host.dart';
import '../support/herdr_stub.dart';
import 'ui_harness.dart' show snapshotWith;

Map<String, dynamic> _worktree(String path, {bool linked = false, String? branch, String? open}) => {
      'path': path,
      'label': path.split('/').last,
      'is_linked_worktree': linked,
      'branch': ?branch,
      'open_workspace_id': ?open,
    };

Map<String, dynamic> _list(List<Map<String, dynamic>> worktrees) => {'type': 'worktree_list', 'worktrees': worktrees};

Map<String, dynamic> _created(String path) => {
      'type': 'worktree_created',
      'workspace': {'workspace_id': 'w9'},
      'tab': {'tab_id': 'w9:1'},
      'root_pane': {'pane_id': 'p9'},
      'worktree': _worktree(path, linked: true, branch: 'worktree/quiet-stone'),
    };

class _Env {
  _Env(this.h, this.vm, this.stub, this.host);

  final CreateHarness h;
  final NewAgentSessionViewModel vm;
  final HerdrStub stub;
  final FakeAgentHost host;

  void dispose() {
    vm.dispose();
    h.dispose();
  }
}

Future<_Env> _env() async {
  final h = await CreateHarness.create([(profile: profileOf('a', 'studio-mac'), snapshot: snapshotWith(const []))]);
  final host = h.hosts.putIfAbsent('a', FakeAgentHost.new);
  final vm = NewAgentSessionViewModel(
    fleet: h.fleet,
    sessions: h.agents,
    settings: h.agentSettings,
    machineId: 'a',
  );
  return _Env(h, vm, h.stubs['a']!, host);
}

void main() {
  late _Env e;

  tearDown(() => e.dispose());

  test('a new worktree is created, then the session starts in it; the typed folder is remembered', () async {
    e = await _env();
    e.stub.on['worktree.list'] = (_) => _list([_worktree('/r/app', branch: 'main')]);
    e.stub.on['worktree.create'] = (_) => _created('/r/worktree-quiet-stone');
    await e.vm.lookUp('/r/app');
    expect(e.vm.checkouts, hasLength(1));

    e.vm.chooseCheckout(const NewWorktree());
    final session = await e.vm.start('/r/app', branch: ' fix/x ');

    expect(session, isNotNull);
    expect(session!.cwd, '/r/worktree-quiet-stone');
    expect(e.stub.paramsOf('worktree.create'), [
      {'cwd': '/r/app', 'branch': 'fix/x', 'focus': false},
    ]);
    expect(e.h.agentSettings.folderFor('a'), '/r/app');
    expect(e.vm.choice, const ExistingCheckout('/r/worktree-quiet-stone'));
    expect(e.h.connection('a').branchOf('/r/worktree-quiet-stone'), 'worktree/quiet-stone');
  });

  test('an existing checkout starts the session there without creating anything', () async {
    e = await _env();
    e.stub.on['worktree.list'] = (_) => _list([_worktree('/r/app'), _worktree('/r/wt-a', linked: true)]);
    await e.vm.lookUp('/r/app');

    e.vm.chooseCheckout(const ExistingCheckout('/r/wt-a'));
    final session = await e.vm.start('/r/app');

    expect(session!.cwd, '/r/wt-a');
    expect(e.stub.paramsOf('worktree.create'), isEmpty);
    expect(e.h.agentSettings.folderFor('a'), '/r/app');
  });

  test('a worktree that cannot be created starts no session', () async {
    e = await _env();
    e.stub.on['worktree.list'] = (_) => _list([_worktree('/r/app')]);
    e.stub.on['worktree.create'] = (_) => throw const HerdrApiException('worktree_failed', 'branch exists');
    await e.vm.lookUp('/r/app');

    e.vm.chooseCheckout(const NewWorktree());
    final session = await e.vm.start('/r/app');

    expect(session, isNull);
    expect(e.host.startCalls, 0);
    expect(e.vm.error?.title, 'Couldn’t create the worktree');
    expect(e.vm.error?.message, 'branch exists');
    expect(e.h.agentSettings.folderFor('a'), isNull);
  });

  test('a create whose answer was lost is not made twice: the worktree herdr made is found and used', () async {
    e = await _env();
    var made = false;
    e.stub.on['worktree.list'] = (_) => _list([
          _worktree('/r/app', branch: 'main'),
          if (made) _worktree('/r/worktree-slow-hook', linked: true, branch: 'worktree/slow-hook'),
        ]);
    // herdr finishes the worktree (its hooks are slow) after the request timed out.
    e.stub.on['worktree.create'] = (_) {
      made = true;
      throw const HerdrTransportException('The machine did not answer in time.');
    };
    await e.vm.lookUp('/r/app');
    e.vm.chooseCheckout(const NewWorktree());

    expect(await e.vm.start('/r/app'), isNull);
    expect(e.vm.error?.title, 'The worktree was created');
    expect(e.vm.choice, const ExistingCheckout('/r/worktree-slow-hook'));

    final session = await e.vm.start('/r/app');

    expect(session!.cwd, '/r/worktree-slow-hook');
    expect(e.stub.paramsOf('worktree.create'), hasLength(1));
  });

  test('a create that is lost and left no worktree says it may exist, and offers a retry', () async {
    e = await _env();
    e.stub.on['worktree.list'] = (_) => _list([_worktree('/r/app')]);
    e.stub.on['worktree.create'] = (_) => throw const HerdrTransportException('Connection lost.');
    await e.vm.lookUp('/r/app');
    e.vm.chooseCheckout(const NewWorktree());

    expect(await e.vm.start('/r/app'), isNull);

    expect(e.vm.error?.title, 'Couldn’t create the worktree');
    expect(e.vm.error?.message, contains('may still have been created'));
  });

  test('a herdr without worktrees says so and offers This folder', () async {
    e = await _env();
    e.stub.on['worktree.list'] = (_) => _list([_worktree('/r/app')]);
    e.stub.on['worktree.create'] = (_) => throw HerdrApiException('invalid_request', 'unknown variant `worktree.create`');
    await e.vm.lookUp('/r/app');

    e.vm.chooseCheckout(const NewWorktree());
    expect(await e.vm.start('/r/app'), isNull);

    expect(e.vm.error?.title, 'Worktrees aren’t supported');
    expect(e.vm.error?.message, contains('choose This folder'));
  });

  test('a session that fails to start after the worktree was made reuses it on the next Start', () async {
    e = await _env();
    e.stub.on['worktree.list'] = (_) => _list([_worktree('/r/app')]);
    e.stub.on['worktree.create'] = (_) => _created('/r/worktree-quiet-stone');
    await e.vm.lookUp('/r/app');
    e.vm.chooseCheckout(const NewWorktree());

    e.host.startFailure = const AgentHostException('The keeper did not start.');
    expect(await e.vm.start('/r/app'), isNull);
    expect(e.vm.error?.title, 'Couldn’t start the session');
    expect(e.vm.error?.message, contains('The worktree worktree-quiet-stone was created'));

    e.host.startFailure = null;
    final session = await e.vm.start('/r/app');

    expect(session!.cwd, '/r/worktree-quiet-stone');
    expect(e.stub.paramsOf('worktree.create'), hasLength(1));
  });

  test('a folder whose lookup fails has no checkouts and no error', () async {
    e = await _env();
    e.stub.on['worktree.list'] = (_) => throw const HerdrApiException('not_a_repo', 'not a git repository');

    await e.vm.lookUp('/tmp');

    expect(e.vm.checkouts, isNull);
    expect(e.vm.choice, isA<ThisFolder>());
    expect(e.vm.error, isNull);
  });

  test('a repo with a single checkout still offers it', () async {
    e = await _env();
    e.stub.on['worktree.list'] = (_) => _list([_worktree('/r/app')]);

    await e.vm.lookUp('/r/app');

    expect(e.vm.checkouts?.map((c) => c.path), ['/r/app']);
  });

  test('the answer for an earlier folder is ignored', () async {
    e = await _env();
    final slow = Completer<Map<String, dynamic>>();
    e.stub.on['worktree.list'] = (params) =>
        params['cwd'] == '/r/old' ? slow.future : _list([_worktree('/r/new'), _worktree('/r/new-wt', linked: true)]);

    final first = e.vm.lookUp('/r/old');
    await e.vm.lookUp('/r/new');
    expect(e.vm.checkouts?.map((c) => c.path), ['/r/new', '/r/new-wt']);

    slow.complete(_list([_worktree('/r/old')]));
    await first;

    expect(e.vm.checkouts?.map((c) => c.path), ['/r/new', '/r/new-wt']);
  });

  test('a choice made for one folder does not carry to another typed since', () async {
    e = await _env();
    e.stub.on['worktree.list'] = (_) => _list([_worktree('/r/app'), _worktree('/r/wt-a', linked: true)]);
    await e.vm.lookUp('/r/app');
    e.vm.chooseCheckout(const ExistingCheckout('/r/wt-a'));

    // Typed, but the pause before the lookup has not passed yet.
    final session = await e.vm.start('/other/place');

    expect(session!.cwd, '/other/place');
  });

  test('a folder that is not absolute forgets the checkouts', () async {
    e = await _env();
    e.stub.on['worktree.list'] = (_) => _list([_worktree('/r/app'), _worktree('/r/wt-a', linked: true)]);
    await e.vm.lookUp('/r/app');
    e.vm.chooseCheckout(const NewWorktree());

    await e.vm.lookUp('~/code');

    expect(e.vm.checkouts, isNull);
    expect(e.vm.choice, isA<ThisFolder>());
  });

  test('branchError leaves naming to git, except for what would break the command', () async {
    e = await _env();

    expect(e.vm.branchError(''), isNull);
    expect(e.vm.branchError('  '), isNull);
    expect(e.vm.branchError('fix/x'), isNull);
    expect(e.vm.branchError('fix x'), 'No spaces or control characters');
    expect(e.vm.branchError('a\tb'), 'No spaces or control characters');
    expect(e.vm.branchError('-D'), 'Can’t start with -');
  });

  test('a bad branch name stops a new worktree before anything is created', () async {
    e = await _env();
    e.stub.on['worktree.list'] = (_) => _list([_worktree('/r/app')]);
    await e.vm.lookUp('/r/app');
    e.vm.chooseCheckout(const NewWorktree());

    expect(await e.vm.start('/r/app', branch: '-D'), isNull);

    expect(e.vm.error?.title, 'Check the form');
    expect(e.stub.paramsOf('worktree.create'), isEmpty);
  });
}
