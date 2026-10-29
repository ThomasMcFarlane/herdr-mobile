// What an agent is called among others: its folder, or, when other agents on
// the same machine work in a folder of the same name (worktrees of one repo),
// its branch beside it; a branch the phone has not read leaves the folder.
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/features/agents/agent_identity.dart';

AgentPlace _at(String cwd, {String machine = 'm1', String? branch}) => (machineId: machine, cwd: cwd, branch: branch);

void main() {
  test('agents sharing a folder name on one machine are told apart by branch', () {
    final names = agentPlaceNames([
      _at('/home/u/web-app', branch: 'main'),
      _at('/home/u/.worktrees/a/web-app', branch: 'fix/login-redirect'),
    ]);
    expect(names, ['web-app · main', 'web-app · fix/login-redirect']);
  });

  test('an agent alone in its folder is named by the folder, even with a branch known', () {
    final names = agentPlaceNames([_at('/home/u/web-app', branch: 'main'), _at('/home/u/api', branch: 'dev')]);
    expect(names, ['web-app', 'api']);
  });

  test('a branch the phone has not read leaves the folder', () {
    final names = agentPlaceNames([
      _at('/home/u/web-app'),
      _at('/home/u/.worktrees/a/web-app', branch: 'fix/login-redirect'),
    ]);
    expect(names, ['web-app', 'web-app · fix/login-redirect']);
  });

  test('the same folder name on two machines is not shared', () {
    final names = agentPlaceNames([
      _at('/home/u/web-app', branch: 'main'),
      _at('/home/u/web-app', machine: 'm2', branch: 'dev'),
    ]);
    expect(names, ['web-app', 'web-app']);
  });

  test('the line leaves out what the title already says and keeps the rest in order', () {
    expect(
      identityLine(place: 'web-app · main', agent: 'Claude Code', machine: 'box', title: 'Fix login'),
      'web-app · main · Claude Code · box',
    );
    expect(identityLine(place: 'web-app', agent: 'Claude Code', title: 'Claude Code'), 'web-app');
    expect(identityLine(place: '', agent: 'Shell'), 'Shell');
  });
}
