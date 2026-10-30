import 'package:flutter/foundation.dart';

import '../../../data/acp/session_state.dart' show AgentPhase;
import '../../../data/models/herdr_models.dart';
import '../../../data/models/pane_name.dart';
import '../../../data/models/places.dart';
import '../../../data/models/status_time.dart';
import '../../../data/repositories/agent_session.dart';
import '../../../data/repositories/attention_set.dart';
import '../../../data/repositories/fleet_repository.dart';
import '../../../data/repositories/machine_connection.dart';
import '../../../data/words/agent_names.dart';
import '../../../data/words/elapsed.dart';
import '../../../data/words/place_name.dart';
import '../../../data/words/plural.dart';
import '../../../data/words/where_line.dart';
import 'agent_identity.dart' show identityLine;

/// Statuses in the order agents are listed by status (a batch action's
/// targets, [groupByStatus]): what needs the person first, then what finished
/// and awaits a look, then what is still running. A rank of its own:
/// [AgentStatus]'s order sorts the fleet's flat list, so it stays as it is.
/// The board itself groups by project ([boardLayout]).
const boardOrder = [AgentStatus.blocked, AgentStatus.done, AgentStatus.working, AgentStatus.idle, AgentStatus.unknown];

/// The state a row is in, as a word for screen readers: the visible label
/// says it with the glyph and the time's colour. Empty for "unknown".
String stateWord(AgentStatus status) => switch (status) {
  AgentStatus.blocked => 'needs you',
  AgentStatus.working => 'working',
  AgentStatus.done => 'done',
  AgentStatus.idle => 'idle',
  AgentStatus.unknown => '',
};

/// "12m", "<1m"; with a bound (the change was found after a gap and its start
/// is not known) "≤ 25m": at most that long. The time only: the row's glyph
/// already says the state (DESIGN.md Hierarchy 5). Empty for an agent whose
/// state has no useful word ("unknown").
String timeInState(AgentStatus status, Duration d, {bool exact = true}) {
  if (status == AgentStatus.unknown) return '';
  if (exact) return Elapsed.compact(d, seconds: false);
  // A bound is a gap of at least a minute; never "<1m" for one.
  return '≤ ${Elapsed.compact(d < _minute ? _minute : d, seconds: false)}';
}

/// What [timeInState] says, in words: "needs you, 4 minutes", "done, at most
/// 2 hours". Empty for "unknown".
String timeInStateWords(AgentStatus status, Duration d, {bool exact = true}) {
  final word = stateWord(status);
  if (word.isEmpty) return '';
  if (exact) return d < _minute ? '$word, under a minute' : '$word, ${Elapsed.words(d)}';
  return '$word, at most ${Elapsed.words(d < _minute ? _minute : d)}';
}

// design-lint: allow(raw-duration) a unit of the label, not a timer or an animation
const _minute = Duration(minutes: 1);

/// The board's status of an agent session: the same five shapes the terminal
/// rows use. A turn that finished and was not looked at is "done".
AgentStatus boardStatus(AgentSessionView s) => AttentionSet.sessionBlocked(s)
    ? AgentStatus.blocked
    : AttentionSet.sessionToReview(s)
    ? AgentStatus.done
    : s.phase == AgentPhase.working
    ? AgentStatus.working
    : AgentStatus.idle;

/// Everything one agent row shows. A record, so two equal rows compare equal
/// and the screen can tell that nothing it draws has changed.
typedef AgentRowData = ({
  // Stable across refreshes: machine id and pane id.
  String key,
  MachineConnection machine,
  String paneId,
  AgentStatus status,
  String title,

  // Second line: agent kind, machine (only when there are several),
  // workspace, folder. Last items are the first to be cut off.
  String subtitle,
  bool stale,

  // When the state began, as far as known: sorts Needs you and Done by how
  // long they have waited, oldest first.
  StatusTime? since,

  // Whole minutes a working agent has been quiet, as of the machine's last
  // refresh and 0 below its threshold: sorts Working, quietest first. Only
  // moves with a refresh, so the order cannot churn with events.
  int quietMinutes,
});

/// A machine that is not connected, and why.
typedef TroubledMachine = ({
  MachineConnection machine,
  String label,
  LinkState state,
  String? error,
  String? approvalUrl,
});

/// What the board needs from the fleet, and nothing more.
@immutable
class AgentsOverview {
  const AgentsOverview({
    required this.machineCount,
    required this.agents,
    required this.troubled,
    required this.enabledCount,
    this.branches = const [],
  });

  factory AgentsOverview.of(FleetRepository fleet) => AgentsOverview.from(fleet.connections, fleet.agents);

  factory AgentsOverview.from(List<MachineConnection> connections, List<FleetAgent> agents) {
    final several = connections.length > 1;
    return AgentsOverview(
      machineCount: connections.length,
      enabledCount: connections.where((c) => c.state != LinkState.disabled).length,
      agents: [for (final a in agents) agentRow(a, showMachine: several)],
      branches: [for (final c in connections) c.branchesVersion],
      troubled: [
        for (final c in connections)
          // A machine the person switched off is not a problem to fix.
          if (c.state != LinkState.online && c.state != LinkState.disabled)
            (machine: c, label: c.profile.label, state: c.state, error: c.error, approvalUrl: c.approvalUrl),
      ],
    );
  }

  final int machineCount;

  /// Machines that are switched on: the ones home's header counts.
  final int enabledCount;
  final List<AgentRowData> agents;
  final List<TroubledMachine> troubled;

  /// Each machine's [MachineConnection.branchesVersion]: the board names rows
  /// by branch, so a branch read changes what it shows.
  final List<int> branches;

  @override
  bool operator ==(Object other) =>
      other is AgentsOverview &&
      other.machineCount == machineCount &&
      other.enabledCount == enabledCount &&
      listEquals(other.agents, agents) &&
      listEquals(other.troubled, troubled) &&
      listEquals(other.branches, branches);

  @override
  int get hashCode => Object.hash(
    machineCount,
    enabledCount,
    Object.hashAll(agents),
    Object.hashAll(troubled),
    Object.hashAll(branches),
  );
}

AgentRowData agentRow(FleetAgent a, {required bool showMachine}) {
  final pane = a.pane;
  final kind = agentName(pane.agent);
  // A pane whose own title says nothing (omp's `π > <folder>`) is named by what
  // its session log says, when that was read (`PaneSessionNames`).
  final named = a.betterTitle;
  final workspace = a.workspace?.label ?? '';
  final path = placeName(a.machine.places, pane.cwd);
  // herdr gives no status timestamps, so a pane that was already idle when the
  // app first looked has no time of its own, or only a bound. The file its agent
  // writes says when it last did: the end of its last turn, the moment it went
  // idle (`PaneSessionNames`).
  var since = a.machine.statusTime(pane.id);
  final active = a.lastActive;
  if (pane.status == AgentStatus.idle && active != null && (since == null || !since.exact)) {
    since = StatusTime.exact(active);
  }
  return (
    key: '${a.machine.profile.id}/${pane.id}',
    machine: a.machine,
    paneId: pane.id,
    status: pane.status,
    // A pane with no title is named after its agent.
    title: named ?? (pane.title.isNotEmpty ? pane.title : kind),
    subtitle: whereLine(
      agent: kind,
      machine: a.machine.profile.label,
      workspace: workspace,
      folder: path,
      title: named ?? (pane.title.isNotEmpty ? pane.title : kind),
      showMachine: showMachine,
    ),
    stale: a.stale,
    since: since,
    quietMinutes: pane.status == AgentStatus.working ? a.machine.quietMinutes(pane.id) : 0,
  );
}

/// Agents by status in [boardOrder], empty groups left out. Inside a group:
/// Needs you and Done by how long they have waited (a bound counts as when it
/// begins; unknown last), Working quietest first, Idle by recency (see
/// [compareIdleTimes]), then machine, then pane. [now] is the moment recency is
/// measured from.
Map<AgentStatus, List<AgentRowData>> groupByStatus(Iterable<AgentRowData> agents, {DateTime? now}) {
  final at = now ?? DateTime.now();
  final groups = <AgentStatus, List<AgentRowData>>{};
  for (final a in agents) {
    groups.putIfAbsent(a.status, () => []).add(a);
  }
  return {
    for (final s in boardOrder)
      if (groups[s] case final list?) s: list..sort(_within(s, at)),
  };
}

Comparator<AgentRowData> _within(AgentStatus status, DateTime now) => switch (status) {
  AgentStatus.blocked || AgentStatus.done => _longestWaiting,
  AgentStatus.working => _quietest,
  AgentStatus.idle => (a, b) {
    final byTime = compareIdleTimes(a.since?.at, b.since?.at, now);
    return byTime != 0 ? byTime : _byPlace(a, b);
  },
  AgentStatus.unknown => _byPlace,
};

int _byPlace(AgentRowData a, AgentRowData b) {
  final byMachine = a.machine.profile.label.compareTo(b.machine.profile.label);
  if (byMachine != 0) return byMachine;
  final byPane = a.paneId.compareTo(b.paneId);
  return byPane != 0 ? byPane : a.key.compareTo(b.key);
}

int _longestWaiting(AgentRowData a, AgentRowData b) {
  final x = a.since?.at;
  final y = b.since?.at;
  if (x != null && y != null) {
    final byAge = x.compareTo(y);
    if (byAge != 0) return byAge;
  } else if (x != null || y != null) {
    return x != null ? -1 : 1;
  }
  return _byPlace(a, b);
}

/// What counts as recent for Idle, and so what is not: past it an agent is
/// inventory.
const idleRecent = Duration(hours: 24);

/// Idle, recency first, in three groups: stopped within [idleRecent] (newest
/// first), then those with no known time, then those that stopped longer ago
/// (newest first). An agent the app has no date for was idle before it first
/// looked, and may be 3 minutes old or 3 months; it cannot be placed among the
/// dated ones, so it sits between "known recent" and "known old": above the
/// agent whose file says 3 days, below the one that stopped an hour ago. Put
/// last, as it was first, it buried the person's own recent agents under other
/// machines' dated old ones. 0 for two agents the same time does not tell apart.
int compareIdleTimes(DateTime? a, DateTime? b, DateTime now) {
  int bucket(DateTime? t) => t == null
      ? 1
      : now.difference(t) < idleRecent
      ? 0
      : 2;
  final byBucket = bucket(a).compareTo(bucket(b));
  if (byBucket != 0) return byBucket;
  return a != null && b != null ? b.compareTo(a) : 0;
}

int _quietest(AgentRowData a, AgentRowData b) {
  final byQuiet = b.quietMinutes.compareTo(a.quietMinutes);
  return byQuiet != 0 ? byQuiet : _byPlace(a, b);
}

/// A board row's status: a terminal agent's, or an agent session's
/// ([boardStatus]).
AgentStatus statusOfItem(BoardItem item) => switch (item) {
  PaneItem(:final row) => row.status,
  SessionItem(:final session) => boardStatus(session),
};

/// Where an agent's work lives on the board: the group it is listed in
/// ([key], stable), what the group is called ([label]) and, when herdr knows
/// the folder's repo, that repo's key (`repo_key`) to count its checkouts by.
typedef RepoKey = ({String key, String label, String? repo});

/// What the group of agents with no known folder is called.
const otherGroupLabel = 'Other';

/// The group an agent in [cwd] on machine [machineId] is listed in.
///
/// A folder herdr places in a repo ([PlaceIndex.of]: a workspace of a worktree
/// group) is grouped by that repo's primary checkout (`repo_root`), so every
/// worktree of one repo is one group, named by the repo. A folder herdr does
/// not place (a plain workspace, most agent sessions) is grouped by the folder
/// itself, named by its last part. No folder at all: one [otherGroupLabel]
/// group per machine. Always per machine: a checkout is a folder on one
/// machine, and two machines' clones are two places to look.
///
/// Stable as data arrives: herdr reports a repo only once a workspace is in a
/// worktree group, and an agent in the primary checkout's own folder has the
/// same key before (its folder) and after (the repo's root), so it does not
/// jump between groups when the first worktree is opened beside it. One in a
/// linked checkout or a sub-folder joins its repo's group then, once; nothing
/// is fetched to guess it sooner.
RepoKey repoKeyIn(String machineId, PlaceIndex places, String? cwd) {
  final place = places.of(cwd);
  if (place != null) return (key: '$machineId:${place.repoRoot}', label: place.repoName, repo: place.repoKey);
  final dir = cwd == null ? '' : cwd.trim();
  final folder = dir.length > 1 && dir.endsWith('/') ? dir.substring(0, dir.length - 1) : dir;
  if (folder.isEmpty) return (key: '$machineId:', label: otherGroupLabel, repo: null);
  return (key: '$machineId:$folder', label: paneFolder(folder), repo: null);
}

/// [repoKeyIn] with what [machine] holds in memory now.
RepoKey repoKeyOf(MachineConnection machine, String? cwd) => repoKeyIn(machine.profile.id, machine.places, cwd);

/// A group's row: the agent and its line under the title inside the group
/// (`fix/rate-limit · omp`: the branch, else the checkout's folder, then the
/// agent kind; the repo is the group's name and is not said again).
typedef GroupRow = ({BoardItem item, String where});

/// The agents of one project (a repo, else a folder) on one machine, except
/// the ones that need the person: those are pinned above every group.
@immutable
class BoardGroup {
  const BoardGroup({
    required this.key,
    required this.label,
    required this.machine,
    required this.rows,
    this.checkouts = 0,
  });

  /// [RepoKey.key]: what its fold is kept by.
  final String key;
  final String label;
  final MachineConnection machine;

  /// Working first, then done, idle, then what is out of reach; recent first
  /// inside each ([boardLayout]).
  final List<GroupRow> rows;

  /// The repo's checkouts open in herdr when it has several (`4 worktrees`),
  /// else 0.
  final int checkouts;

  Iterable<BoardItem> get items => rows.map((r) => r.item);
}

/// What the board lists, top to bottom: Needs you across every project
/// ([needsYou], in [AttentionSet]'s order, the triage walk's), then one group
/// per project ([groups]).
@immutable
class BoardLayout {
  const BoardLayout({
    this.needsYou = const [],
    this.needsYouCount = 0,
    this.needsYouOffline = 0,
    this.toReviewCount = 0,
    this.toReviewOffline = 0,
    this.groups = const [],
  });

  final List<BoardItem> needsYou;

  /// What Needs you counts: the [AttentionSet]'s (what can be answered), the
  /// number the status line and the triage sheet show.
  final int needsYouCount;

  /// Waiting agents listed (last known) whose machine or link is down. Not in
  /// [needsYouCount]; the header says "N offline".
  final int needsYouOffline;

  /// Finished agents not reviewed that can be marked ([AttentionSet.toReview]),
  /// and those out of reach: the board's `To review` line.
  final int toReviewCount;
  final int toReviewOffline;

  final List<BoardGroup> groups;

  /// Every row, in the board's order.
  Iterable<BoardItem> get items sync* {
    yield* needsYou;
    for (final g in groups) {
      yield* g.items;
    }
  }

  /// How many agents are working, as the status line says.
  int get working => items.where((i) => statusOfItem(i) == AgentStatus.working).length;
}

/// Where a row sits inside its group: working, done, idle, then what cannot be
/// reached now (offline, ended) last.
int _rankOf(BoardItem item) => switch (item) {
  PaneItem(:final row) => row.stale ? 3 : _statusRank(row.status),
  SessionItem(:final session) => AttentionSet.sessionReachable(session) ? _statusRank(boardStatus(session)) : 3,
};

int _statusRank(AgentStatus s) => switch (s) {
  AgentStatus.working || AgentStatus.blocked => 0,
  AgentStatus.done => 1,
  AgentStatus.idle => 2,
  AgentStatus.unknown => 3,
};

/// When a row's state began, as far as known. A working session by its phase
/// (its activity moves with every event, and the order must not churn while
/// it streams); any other session by when it last did anything.
DateTime? _timeOf(BoardItem item) => switch (item) {
  PaneItem(:final row) => row.since?.at,
  SessionItem(:final session) =>
    boardStatus(session) == AgentStatus.working ? session.phaseSince : (session.lastActivity ?? session.phaseSince),
};

int _quietOf(BoardItem item) => switch (item) {
  PaneItem(:final row) => row.quietMinutes,
  SessionItem() => 0,
};

/// Newest first; an unknown time after every known one.
int _newestFirst(DateTime? a, DateTime? b) {
  if (a != null && b != null) return b.compareTo(a);
  if (a != null || b != null) return a != null ? -1 : 1;
  return 0;
}

/// The line under a row's title inside its group: the branch checked out
/// where it works (when its machine read it, [MachineConnection.branchOf]),
/// else the checkout's folder, then the agent kind. The folder is left out
/// when it is the group's own name (the repo's primary checkout, a plain
/// folder) and nothing tells it apart, and a part the title says is left out
/// (`identityLine`). Never empty while there is anything to say.
String _whereInGroup(
  MachineConnection machine,
  String? cwd, {
  required String kind,
  required String title,
  required String group,
}) {
  final place = machine.places.of(cwd);
  final branch = place == null ? null : machine.branchOf(place.checkoutPath);
  final checkout = branch ?? place?.checkoutName ?? paneFolder(cwd);
  final line = identityLine(place: branch == null && checkout == group ? '' : checkout, agent: kind, title: title);
  return line.isNotEmpty ? line : identityLine(place: checkout, agent: kind);
}

/// The board's layout: terminal agents ([rows]) and agent sessions
/// ([sessions]) together, so a status or a project means one place whatever
/// started the agent.
///
/// Needs you follows [attention]: what can be reached first, longest waiting
/// first, panes and sessions mixed (the order the triage sheet walks), then
/// what is out of reach. Every other agent is in its project's group
/// ([repoKeyOf]). Inside a group: working (quietest first), done, idle (by
/// [compareIdleTimes]), then what is offline or ended; newest first inside
/// each. Groups: the one with the most urgent row first (working before done
/// before idle), then the most recent, then by name. [now] is the moment
/// recency is measured from.
BoardLayout boardLayout(
  List<AgentRowData> rows,
  List<AgentSessionView> sessions,
  AttentionSet attention, {
  DateTime? now,
}) {
  final at = now ?? DateTime.now();
  final all = <BoardItem>[for (final r in rows) PaneItem(r), for (final s in sessions) SessionItem(s)];

  // [attention]'s order; anything it does not list keeps its own order, last.
  final order = [...attention.needsYou, ...attention.offlineNeedsYou];
  final rank = {for (final (i, item) in order.indexed) item.key: i};
  int waitRank(BoardItem b) =>
      rank[switch (b) {
        PaneItem(:final row) => row.key,
        SessionItem(:final session) => 'session/${session.key}',
      }] ??
      order.length;
  final waiting =
      [
        for (final (i, item) in all.indexed)
          if (statusOfItem(item) == AgentStatus.blocked) (i, item),
      ]..sort((a, b) {
        final byRank = waitRank(a.$2).compareTo(waitRank(b.$2));
        return byRank != 0 ? byRank : a.$1.compareTo(b.$1);
      });

  final byGroup = <String, ({RepoKey repo, MachineConnection machine, List<(int, GroupRow)> rows})>{};
  for (final (i, item) in all.indexed) {
    if (statusOfItem(item) == AgentStatus.blocked) continue;
    final (machine, cwd, kind, title) = switch (item) {
      PaneItem(:final row) => (
        row.machine,
        row.machine.paneById(row.paneId)?.cwd,
        agentName(row.machine.paneById(row.paneId)?.agent),
        row.title,
      ),
      SessionItem(:final session) => (session.machine, session.cwd, session.agentLabel, session.title),
    };
    final repo = repoKeyOf(machine, cwd);
    final where = _whereInGroup(machine, cwd, kind: kind, title: title, group: repo.label);
    byGroup.putIfAbsent(repo.key, () => (repo: repo, machine: machine, rows: [])).rows.add((
      i,
      (item: item, where: where),
    ));
  }

  int inGroup((int, GroupRow) a, (int, GroupRow) b) {
    final x = a.$2.item;
    final y = b.$2.item;
    final byRank = _rankOf(x).compareTo(_rankOf(y));
    if (byRank != 0) return byRank;
    final byTime = switch (_rankOf(x)) {
      0 => switch (_quietOf(y).compareTo(_quietOf(x))) {
        0 => _newestFirst(_timeOf(x), _timeOf(y)),
        final q => q,
      },
      2 => compareIdleTimes(_timeOf(x), _timeOf(y), at),
      _ => _newestFirst(_timeOf(x), _timeOf(y)),
    };
    return byTime != 0 ? byTime : a.$1.compareTo(b.$1);
  }

  final groups = [
    for (final g in byGroup.values)
      BoardGroup(
        key: g.repo.key,
        label: g.repo.label,
        machine: g.machine,
        rows: [for (final (_, row) in g.rows..sort(inGroup)) row],
        checkouts: switch (g.repo.repo) {
          final repo? => g.machine.places.repos.where((r) => r.repoKey == repo).firstOrNull?.checkouts.length ?? 0,
          null => 0,
        },
      ),
  ];
  int urgency(BoardGroup g) => _rankOf(g.rows.first.item);
  DateTime? latest(BoardGroup g) {
    DateTime? best;
    for (final item in g.items) {
      final t = _timeOf(item);
      if (t != null && (best == null || t.isAfter(best))) best = t;
    }
    return best;
  }

  groups.sort((a, b) {
    final byUrgency = urgency(a).compareTo(urgency(b));
    if (byUrgency != 0) return byUrgency;
    final byTime = _newestFirst(latest(a), latest(b));
    if (byTime != 0) return byTime;
    final byName = a.label.toLowerCase().compareTo(b.label.toLowerCase());
    return byName != 0 ? byName : a.key.compareTo(b.key);
  });

  return BoardLayout(
    needsYou: [for (final (_, item) in waiting) item],
    needsYouCount: attention.needsYou.length,
    needsYouOffline: attention.offlineNeedsYou.length,
    toReviewCount: attention.toReview.length,
    toReviewOffline: attention.offlineToReview.length,
    groups: groups,
  );
}

/// A group's one-line summary under its name, in the words the board already
/// uses: `2 working · 1 quiet · 1 done · 3 idle · 4 worktrees`, led by the
/// machine when the board spans several (a group is one machine's). Quiet is
/// the working agents the rows say are quiet. Folded, it is what says what
/// the group holds.
String groupSummary(BoardGroup group, {bool showMachine = false}) {
  var working = 0, quiet = 0, done = 0, idle = 0, offline = 0;
  for (final item in group.items) {
    final rank = _rankOf(item);
    final down = switch (item) {
      PaneItem(:final row) => row.stale,
      SessionItem(:final session) => !session.machine.isLive,
    };
    if (rank == 3 && down) {
      offline++;
    } else if (rank == 0) {
      working++;
      if (_quietOf(item) > 0) quiet++;
    } else if (rank == 1) {
      done++;
    } else {
      idle++;
    }
  }
  return [
    if (showMachine) group.machine.profile.label,
    if (working > 0) '$working working',
    if (quiet > 0) '$quiet quiet',
    if (done > 0) '$done done',
    if (idle > 0) '$idle idle',
    if (offline > 0) '$offline offline',
    if (group.checkouts > 1) countOf(group.checkouts, 'worktree'),
  ].join(' · ');
}

/// One line of the agents list.
sealed class AgentEntry {
  const AgentEntry();

  /// What identifies this line across rebuilds, so a line keeps its element
  /// (and any animation in flight) when others come and go around it.
  Key get key;
}

/// The Needs you header. It never folds: a fold is kept across launches, and
/// a folded Needs you would hide the one loud section the board exists for.
class NeedsYouHeader extends AgentEntry {
  const NeedsYouHeader({required this.count, this.offline = 0});

  /// What counts (see [BoardLayout.needsYouCount]).
  final int count;

  /// Listed but out of reach (see [BoardLayout.needsYouOffline]).
  final int offline;

  @override
  Key get key => const ValueKey('header/needs-you');
}

/// The `To review` line above the groups: how many finished agents can be
/// marked, and the actions that review them all at once. One line for every
/// project, since one Mark reviewed (one toast, one Undo) and one Select all
/// cover finished agents wherever they are listed.
class ReviewHeader extends AgentEntry {
  const ReviewHeader({required this.count, this.offline = 0});

  final int count;
  final int offline;

  @override
  Key get key => const ValueKey('header/to-review');
}

/// A project's header: its name and summary; a tap folds it.
class GroupHeader extends AgentEntry {
  const GroupHeader(this.group, {required this.summary, required this.expanded});

  final BoardGroup group;
  final String summary;
  final bool expanded;

  @override
  Key get key => ValueKey('group/${group.key}');
}

/// A row stays in the list while its group is folded so that it can animate
/// away; it costs one empty box, not a built row.
class AgentLine extends AgentEntry {
  const AgentLine(this.agent, {required this.open, required this.last, this.front = false});

  final AgentRowData agent;
  final bool open;
  final bool last;

  /// The first row of Needs you: the one decision in front, drawn as a card
  /// with its answers whatever the density. The other waiting agents are
  /// named in rows under it, so one question is in front and the rest are
  /// known, not stacked as cards the thumb has to scroll past.
  final bool front;

  @override
  Key get key => ValueKey(agent.key);
}

/// The place a card held until a moment ago, shrinking to nothing: an agent
/// that stopped waiting leaves Needs you, and the cards below glide up into
/// the gap instead of jumping by a whole card. Only the board adds these, for
/// a fraction of a second; they are not agents and nothing selects them.
class AgentFolding extends AgentEntry {
  const AgentFolding(this.agentKey, this.height);

  final String agentKey;

  /// What the card measured when it left.
  final double height;

  @override
  Key get key => ValueKey('folding/$agentKey');
}

/// How many idle rows a group shows before the rest fold behind [AgentMore].
/// Idle is inventory, not a decision: a board with 27 of them buried
/// everything else.
const idleShown = 5;

/// The line that stands for the rows of a group that are folded away ("22
/// more idle", with the names of the first two, so what is inside is not a
/// guess) and opens them in place. Open, it sits after the last row and reads
/// "Show less".
class AgentMore extends AgentEntry {
  const AgentMore(this.groupKey, this.hidden, this.names, {required this.open, this.kind});

  final String groupKey;

  /// How many rows the fold holds.
  final int hidden;

  /// The titles of the first rows it holds, to say what is inside.
  final List<String> names;
  final bool open;

  /// What the folded rows are (`idle`) when they are all one thing; null when
  /// they mix idle and offline ones.
  final String? kind;

  @override
  Key get key => ValueKey('more/$groupKey');
}

/// A session's line, in Needs you or its project's group. The board only
/// tells about it (answers are given in the session). [where] replaces its
/// meta line inside a group (the repo is the group's name).
class SessionLine extends AgentEntry {
  const SessionLine(this.session, {required this.open, required this.last, this.where});

  final AgentSessionView session;
  final bool open;
  final bool last;
  final String? where;

  @override
  Key get key => ValueKey('session/${session.key}');
}

/// One row of the board: a terminal agent or an agent session.
sealed class BoardItem {
  const BoardItem();
}

final class PaneItem extends BoardItem {
  const PaneItem(this.row);
  final AgentRowData row;
}

final class SessionItem extends BoardItem {
  const SessionItem(this.session);
  final AgentSessionView session;
}

/// [row] with [subtitle] as its line under the title.
AgentRowData _withSubtitle(AgentRowData row, String subtitle) => (
  key: row.key,
  machine: row.machine,
  paneId: row.paneId,
  status: row.status,
  title: row.title,
  subtitle: subtitle,
  stale: row.stale,
  since: row.since,
  quietMinutes: row.quietMinutes,
);

/// The lines to list: Needs you's header and rows (its first row the one in
/// front, [AgentLine.front]), the `To review` line when anything finished
/// waits, then each group's header and rows. Needs you never folds; a group
/// in [collapsed] (by [BoardGroup.key]) does. [showMachine]: the board spans
/// several machines, so each group's summary names its own.
///
/// A group shows its first [idleShown] idle (or offline) rows and folds the
/// rest behind one [AgentMore] line (opened when its key is in [openFolds]),
/// unless folding would hide a single row. The rows are in the list either
/// way, closed, so that they animate away.
List<AgentEntry> boardEntries(
  BoardLayout layout, {
  Set<String> collapsed = const {},
  Set<String> openFolds = const {},
  bool showMachine = false,
}) {
  String titleOf(BoardItem item) => switch (item) {
    PaneItem(:final row) => row.title,
    SessionItem(:final session) => session.title,
  };
  final waiting = layout.needsYou;
  return [
    if (waiting.isNotEmpty) ...[
      NeedsYouHeader(count: layout.needsYouCount, offline: layout.needsYouOffline),
      for (final (i, item) in waiting.indexed)
        switch (item) {
          PaneItem(:final row) => AgentLine(
            row,
            open: true,
            last: i == waiting.length - 1,
            front: i == 0 && !row.stale,
          ),
          SessionItem(:final session) => SessionLine(session, open: true, last: i == waiting.length - 1),
        },
    ],
    if (layout.toReviewCount + layout.toReviewOffline > 0)
      ReviewHeader(count: layout.toReviewCount, offline: layout.toReviewOffline),
    for (final group in layout.groups) ...[
      GroupHeader(
        group,
        summary: groupSummary(group, showMachine: showMachine),
        expanded: !collapsed.contains(group.key),
      ),
      ..._groupLines(
        group,
        open: !collapsed.contains(group.key),
        foldOpen: openFolds.contains(group.key),
        titleOf: titleOf,
      ),
    ],
  ];
}

/// Where [group]'s fold begins: the index of its first row the fold holds,
/// or null when it has no fold. The tail that folds is idle and what is out
/// of reach, which sort last; the fold holds what follows its first
/// [idleShown] rows, unless it would hold a single row.
int? _foldAt(BoardGroup group) {
  final rows = group.rows;
  final tailStart = rows.indexWhere((r) => _rankOf(r.item) >= 2);
  final tail = tailStart < 0 ? 0 : rows.length - tailStart;
  return tail > idleShown + 1 ? tailStart + idleShown : null;
}

/// The rows of [group] its fold holds (none when it has no fold).
Iterable<BoardItem> foldedItems(BoardGroup group) => switch (_foldAt(group)) {
  final at? => group.items.skip(at),
  null => const <BoardItem>[],
};

List<AgentEntry> _groupLines(
  BoardGroup group, {
  required bool open,
  required bool foldOpen,
  required String Function(BoardItem) titleOf,
}) {
  final rows = group.rows;
  final at = _foldAt(group);
  final foldable = at != null;
  final folded = foldable && !foldOpen;
  final foldAt = at ?? rows.length;

  AgentEntry line(int i) {
    final shown = open && (!folded || i < foldAt);
    final last = i == rows.length - 1;
    final GroupRow(:item, :where) = rows[i];
    return switch (item) {
      PaneItem(:final row) => AgentLine(_withSubtitle(row, where), open: shown, last: last),
      SessionItem(:final session) => SessionLine(session, open: shown, last: last, where: where),
    };
  }

  AgentMore more() {
    final hidden = rows.skip(foldAt);
    return AgentMore(
      group.key,
      rows.length - foldAt,
      [for (final r in hidden.take(2)) titleOf(r.item)],
      open: foldOpen,
      kind: hidden.every((r) => _rankOf(r.item) == 2) ? 'idle' : null,
    );
  }

  return [
    for (var i = 0; i < rows.length; i++) ...[
      line(i),
      // Closed, the fold comes right after the rows that show.
      if (folded && open && i == foldAt - 1) more(),
    ],
    // Open, it comes last: "Show less" where the list ends.
    if (foldable && foldOpen && open) more(),
  ];
}

/// Entry key to its index, for `findChildIndexCallback`.
Map<Key, int> entryIndexes(List<AgentEntry> entries) => {for (final (i, e) in entries.indexed) e.key: i};

/// The state that most needs the person, to colour a summary of several
/// machines: something to fix, then something to approve, then waiting.
LinkState worstLinkState(Iterable<LinkState> states) {
  const order = [
    LinkState.attention,
    LinkState.approval,
    LinkState.reconnecting,
    LinkState.connecting,
    LinkState.offline,
  ];
  return states.reduce((a, b) => order.indexOf(b) < order.indexOf(a) ? b : a);
}
