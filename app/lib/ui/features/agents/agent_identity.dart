import '../../../data/models/pane_name.dart';
import '../../../data/repositories/machine_connection.dart';
import '../../../data/words/agent_names.dart';
import 'agents_grouping.dart';

/// Where an agent runs, as far as the phone already holds it: the machine,
/// the folder it works in and, when it was read, the branch checked out
/// there.
typedef AgentPlace = ({String machineId, String? cwd, String? branch});

/// What each of [places] is called in a list of agents, in the same order.
///
/// An agent is named by its folder (the last part of its path). Agents on one
/// machine whose folders share that name (git worktrees of one repo often
/// do) are told apart by their branch: `web-app · fix/login-redirect`. A
/// branch the phone has not read leaves the folder alone. Why: a switcher
/// whose rows all read `web-app · Claude Code` cannot be used to switch.
List<String> agentPlaceNames(List<AgentPlace> places) {
  final shared = <(String, String), int>{};
  for (final p in places) {
    final folder = paneFolder(p.cwd);
    if (folder.isEmpty) continue;
    shared.update((p.machineId, folder), (n) => n + 1, ifAbsent: () => 1);
  }
  return [
    for (final p in places)
      switch ((paneFolder(p.cwd), p.branch)) {
        (final folder, final branch?) when branch.isNotEmpty && (shared[(p.machineId, folder)] ?? 0) > 1 =>
          '$folder · $branch',
        (final folder, _) => folder,
      },
  ];
}

/// The place of [item] from what is in memory: the pane's or session's
/// folder and the branch its machine last read for that checkout
/// ([MachineConnection.branchOf]). Nothing is fetched: a branch that was
/// never read is null.
AgentPlace placeOfItem(BoardItem item) {
  final (machine, cwd) = switch (item) {
    PaneItem(:final row) => (row.machine, row.machine.paneById(row.paneId)?.cwd),
    SessionItem(:final session) => (session.machine, session.cwd),
  };
  return (machineId: machine.profile.id, cwd: cwd, branch: _branchAt(machine, cwd));
}

String? _branchAt(MachineConnection machine, String? cwd) {
  final checkout = machine.places.of(cwd)?.checkoutPath;
  return checkout == null ? null : machine.branchOf(checkout);
}

/// The agent kind of [item], in words (`Claude Code`, `Shell`).
String agentKindOf(BoardItem item) => switch (item) {
  PaneItem(:final row) => agentName(row.machine.paneById(row.paneId)?.agent),
  SessionItem(:final session) => session.agentLabel,
};

/// The line under an agent's title where it is named among others:
/// `web-app · fix/login-redirect · Claude Code`, then the [machine] when the
/// list spans several. A part the [title] already says is left out.
String identityLine({required String place, required String agent, String? machine, String? title}) {
  bool said(String part) => title != null && part.toLowerCase() == title.trim().toLowerCase();
  return [
    for (final part in [place, agent, ?machine])
      if (part.trim().isNotEmpty && !said(part)) part.trim(),
  ].join(' · ');
}
