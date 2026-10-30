import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../../data/models/herdr_models.dart';
import '../../../data/repositories/app_settings.dart';
import '../../../data/repositories/fleet_repository.dart';
import '../../../data/repositories/machine_connection.dart';
import '../../../data/repositories/agent_session.dart';
import '../../../data/words/elapsed.dart';
import '../../../data/words/plural.dart';
import '../../../data/repositories/attention_set.dart';
import '../machines/approval_button.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

import '../../shell/home_pages.dart';
import '../../support/step_clock.dart';
import '../../support/tap_guard.dart';
import '../create/new_agent_session_screen.dart';
import '../machines/machine_form_screen.dart';
import 'agent_card.dart';
import 'agent_more_row.dart';
import 'agent_session_rows.dart';
import 'agents_grouping.dart';
import 'batch_action_bar.dart';
import 'batch_actions_sheet.dart';
import 'board_selection.dart';
import 'reply_sheet.dart';
import 'swipe_review.dart';

/// Every agent across every machine: what needs the person pinned on top
/// across every project, then one group per project (a repo with all its
/// worktrees, else a folder), each agent a row named by its task with its
/// branch under it. Why (owner decision): people run several features of one
/// repo in separate worktrees, and status sections scattered one repo's
/// features across Working, Done and Idle. Terminal agents and agent sessions
/// share every place, so "what waits" has one place to look. Needs you and
/// To review count and order what [AttentionSet] says, the same as the triage
/// sheet and the notifications.
///
/// Calm by default: one status line says the count once, the first waiting
/// agent is a card with its answers and every other agent is a row. Why: the
/// count used to be said four times on one screen (a filter chip, the section
/// header, a floating pill and the tab badge), and chrome costs the focus a
/// glance is made of.
///
/// This is home: no bar under it. Its header opens Machines (the chip that
/// says how many are online) and Settings (the gear), as pages pushed over it
/// ([HomePages]). A pushed page leaves a picked set waiting for the person's
/// return, as any other pushed screen does: Back always comes home.
class AgentsScreen extends StatefulWidget {
  const AgentsScreen({super.key, this.pages = const HomePages(), this.onSelectingChanged});

  /// Opens Machines (where connection problems are explained and fixed) and
  /// Settings, and carries the update for the gear's dot.
  final HomePages pages;

  /// Called with true when the board starts picking agents for a batch action
  /// and false when it stops: Back is the board's then, not the app's.
  final ValueChanged<bool>? onSelectingChanged;

  @override
  State<AgentsScreen> createState() => _AgentsScreenState();
}

class _AgentsScreenState extends State<AgentsScreen> with RestorationMixin {
  // A group shows its first idle rows and folds the rest ([idleShown]); the
  // groups whose fold is open. Not kept: the board opens folded again, the
  // way a long inbox does.
  final _openFolds = <String>{};
  bool? _reportedVisible;
  AgentSessions? _sessions;

  // Folded groups, by [BoardGroup.key], one per line, so the set survives the
  // process being reclaimed. Nothing secret lives here (machine ids and
  // folders). Needs you never folds. It replaced one bit per status section
  // under another id: a restored int read as this string would throw.
  final _foldedGroups = RestorableString('');

  // The last page built. Hidden under a pushed page, the board hands this
  // back instead of rebuilding, so fleet updates cost it one cheap build call.
  Widget? _page;

  // Which agents are picked for a batch action. Not restored: a restart
  // starts without it. Only the rows and the two bars listen to it.
  final _selection = BoardSelection();
  List<String> _visibleRefs = const [];
  Set<String> _liveRefs = const {};
  bool _retainQueued = false;
  bool _wasSelecting = false;

  // Answers on cards move when a card above them comes or goes: the gate
  // closes for a moment so a tap aimed at the old place cannot answer for
  // another agent. [_answerLayout] is the lines down to the last answerable
  // card, as the last build saw them.
  final _gate = SettleGate();
  List<Key>? _answerLayout;

  // A line's last laid-out height is read through the key its child carries,
  // at the moment the agent stops waiting: [_folding] holds those that left
  // Needs you, each a gap shrinking where the card stood. [_lastEntries] is
  // the list the last build showed.
  final _measure = <String, GlobalKey>{};
  final _folding = <String, ({double height, Key? after, int at})>{};
  List<AgentEntry> _lastEntries = const [];

  @override
  String get restorationId => 'agents';

  @override
  void restoreState(RestorationBucket? oldBucket, bool initialRestore) {
    registerForRestoration(_foldedGroups, 'folded-groups');
  }

  @override
  void initState() {
    super.initState();
    _selection.addListener(_onSelection);
  }

  /// Tells the shell when picking starts and ends (Back is the board's
  /// then), and makes room at the list's end for the batch bar.
  void _onSelection() {
    final active = _selection.active;
    if (active == _wasSelecting) return;
    _wasSelecting = active;
    widget.onSelectingChanged?.call(active);
    setState(() {});
  }

  @override
  void dispose() {
    _sessions?.setBoardVisible(false);
    _selection
      ..removeListener(_onSelection)
      ..dispose();
    _gate.dispose();
    _foldedGroups.dispose();
    super.dispose();
  }

  Set<String> get _foldedKeys => {
    for (final key in _foldedGroups.value.split('\n'))
      if (key.isNotEmpty) key,
  };

  void _setFolded(Set<String> keys) => _foldedGroups.value = keys.join('\n');

  void _addMachine() => openMachineForm(context);

  void _newSession() => unawaited(openNewAgentSession(context));

  void _showMachines() => widget.pages.open(context, HomePage.machines);

  void _showSettings() => widget.pages.open(context, HomePage.settings);

  /// Settings, with a quiet dot while a newer version waits there (a
  /// suggestion, never a count: it is not something that needs the person).
  Widget _settingsButton() => ListenableBuilder(
    listenable: widget.pages.update ?? _noUpdate,
    builder: (context, _) => CircleButton(
      key: const ValueKey('settings'),
      icon: HerdrIcons.settings,
      tooltip: 'Settings',
      mark: widget.pages.update?.release != null,
      markLabel: 'update available',
      onPressed: _showSettings,
    ),
  );

  static final _noUpdate = Listenable.merge(const <Listenable>[]);

  void _toggleGroup(String key) => setState(() {
    final folded = _foldedKeys;
    if (!folded.remove(key)) folded.add(key);
    _setFolded(folded);
  });

  void _toggleFold(String key) => setState(() {
    if (!_openFolds.remove(key)) _openFolds.add(key);
  });

  /// Reads the branches of a machine whose repos the board shows with
  /// several checkouts, once per machine for the app run
  /// ([MachineConnection.loadBranchesOnce]), after the frame: the rows are
  /// named by their checkout's folder until then. Never per rebuild: a
  /// machine already asked is skipped here.
  void _askBranches(BoardLayout layout) {
    final machines = {
      for (final g in layout.groups)
        if (g.checkouts > 1 && g.machine.isLive && !g.machine.branchesAsked) g.machine,
    };
    if (machines.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final m in machines) {
        m.loadBranchesOnce();
      }
    });
  }

  /// Tells the sessions when the board is on screen (not under a pushed
  /// page): they list their hosts every minute only then.
  void _reportVisible(bool visible) {
    if (_reportedVisible == visible) return;
    _reportedVisible = visible;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _sessions?.setBoardVisible(_reportedVisible ?? false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final visible = TickerMode.valuesOf(context).enabled;
    _reportVisible(visible);
    if (!visible) {
      if (_page case final page?) return page;
    }
    final overview = context.select<FleetRepository, AgentsOverview>(AgentsOverview.of);
    // Set in Settings > Look > Agent list.
    final cards = context.select<AppSettings, bool>((s) => s.cards);
    final sessions = _sessions = context.watch<AgentSessions?>();
    final attention = context.watch<AttentionSet>();
    return _page = _buildPage(context, overview, sessions, attention, cards: cards);
  }

  Widget _buildPage(
    BuildContext context,
    AgentsOverview overview,
    AgentSessions? sessions,
    AttentionSet attention, {
    required bool cards,
  }) {
    // No bar under home: the list ends above the system inset, and keeps the
    // batch bar's room only while it is up, so the last row can be read
    // above it.
    final inset = MediaQuery.paddingOf(context).bottom;
    final listEnd = _selection.active ? FloatingBar.listEnd(context) : inset + Gap.xl;

    if (overview.machineCount == 0) {
      return CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          // Settings stays one tap away before the first machine; there is no
          // fleet yet for the chip to sum up, and nothing to start.
          SliverLargeTitle(title: 'Agents', actions: [_settingsButton()]),
          SliverFillRemaining(
            hasScrollBody: false,
            child: Padding(
              padding: EdgeInsets.only(bottom: inset),
              child: EmptyState(
                mark: const BrandMark(),
                title: 'No machines yet',
                message: 'Add a machine running herdr and its agents show here.',
                action: AppButton(label: 'Add your first machine', icon: LucideIcons.plus, onPressed: _addMachine),
              ),
            ),
          ),
        ],
      );
    }

    final sessionList = sessions?.sessions ?? const <AgentSessionView>[];
    final layout = boardLayout(overview.agents, sessionList, attention);
    _askBranches(layout);
    final entries = boardEntries(
      layout,
      collapsed: _foldedKeys,
      openFolds: _openFolds,
      showMachine: overview.machineCount > 1,
    );
    _armGateWhenAnswersMove(entries, cards: cards);
    final listed = _withFolding(entries, overview);
    final indexes = entryIndexes(listed);

    final troubled = overview.troubled;
    final needYouCount = attention.needsYou.length;
    final review = attention.toReview.length;
    final working = layout.working;

    // What All picks: the rows the board shows (open groups),
    // and what a pane that went away takes out of the selection.
    _visibleRefs = [
      for (final e in entries)
        if (e is AgentLine && e.open)
          paneRef(e.agent.key)
        else if (e is SessionLine && e.open)
          sessionRef(e.session.key),
    ];
    _liveRefs = {for (final a in overview.agents) paneRef(a.key), for (final s in sessionList) sessionRef(s.key)};
    if (_selection.active) _queueRetain();

    final status = _StatusLine(
      waiting: needYouCount,
      working: working,
      agents: overview.agents.length + sessionList.length,
      machines: overview.machineCount,
      troubled: troubled.length,
    );
    // Measured once per build with the longest "heard" the minute can grow
    // into, so the header does not change height (and move the list) as the
    // minutes tick.
    final heard = heardLabel(context.read<FleetRepository>().connections);
    final statusLines = status.lines(context, heard: heard == null ? null : _StatusLine.longestHeard);

    final list = AppRefresh(
      onRefresh: () async {
        await Future.wait([context.read<FleetRepository>().retryAll(), if (sessions != null) sessions.refresh()]);
      },
      edgeOffset: SliverLargeTitle.extent(context, hasSubtitle: true, subtitleLines: statusLines),
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverLargeTitle(
            title: 'Agents',
            // The board's one status line. Steps once a minute, so "heard 3m
            // ago" grows while nothing else changes: a board that went quiet
            // says so instead of looking live. It takes a second line rather
            // than cut its end ("1 not connected") on a narrow phone.
            subtitle: MinuteBuilder(
              builder: (context, _) => Text.rich(
                status.span(context, heard: heardLabel(context.read<FleetRepository>().connections)),
                maxLines: statusLines,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            subtitleLines: statusLines,
            // Scrolled, the bar keeps the chip and the two actions, and no
            // centred `Agents` to collide with the chip (home needs no name).
            compactTitle: false,
            // The fleet's health, and the way to Machines: status first, a
            // way in second.
            leading: _MachineHealth(
              online: overview.enabledCount - troubled.length,
              enabled: overview.enabledCount,
              worst: troubled.isEmpty ? null : worstLinkState(troubled.map((t) => t.state)),
              onTap: _showMachines,
            ),
            // Two actions, the budget (DESIGN.md Hierarchy 6): start an agent,
            // and Settings. Density is a setting (Settings > Look > Agent
            // list) and Past sessions is a row of the `+` form, where resuming
            // is one of the ways to start.
            actions: [
              CircleButton(icon: LucideIcons.plus, tooltip: 'New agent session', onPressed: _newSession),
              _settingsButton(),
            ],
          ),
          // Kept as a strip, not folded into the status line: it carries the
          // next step (Retry, Approve, or Machines), which words in a subtitle
          // cannot. It sits right under the header, where the status line is,
          // and both come back with the top of the list.
          if (troubled.isNotEmpty)
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.gutter),
              sliver: SliverToBoxAdapter(
                child: _ConnectionStrip(troubled: troubled, onShowMachines: _showMachines),
              ),
            ),
          if (overview.agents.isEmpty && troubled.isEmpty && sessionList.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Padding(
                padding: EdgeInsets.only(bottom: inset),
                child: const EmptyState(
                  icon: LucideIcons.moon,
                  title: 'No agents running',
                  message: 'Start one in herdr and it shows here.',
                ),
              ),
            )
          else ...[
            SliverList.builder(
              itemCount: listed.length,
              findChildIndexCallback: (key) => indexes[key],
              itemBuilder: (context, i) => switch (listed[i]) {
                // Counted by the status line, so its header does not say it
                // again.
                final NeedsYouHeader h => _SectionHeader(
                  key: h.key,
                  label: AgentStatus.blocked.label,
                  count: null,
                  expanded: null,
                  onTap: null,
                  actions: _needsYouActions(h, needYou: needYouCount),
                ),
                // With only offline ones listed: "To review · 2 offline", not
                // a 0 that reads as a count of nothing beside them.
                final ReviewHeader h => _SectionHeader(
                  key: h.key,
                  label: _toReview,
                  count: h.count == 0 && h.offline > 0 ? null : h.count,
                  expanded: null,
                  onTap: null,
                  actions: _reviewActions(h, review: review),
                ),
                final GroupHeader h => _GroupHeader(
                  key: h.key,
                  label: h.group.label,
                  summary: h.summary,
                  expanded: h.expanded,
                  onTap: () => _toggleGroup(h.group.key),
                ),
                final AgentLine l => Collapse(
                  key: l.key,
                  open: l.open,
                  // Measured when the agent stops waiting (see
                  // [_withFolding]); the key follows the line.
                  child: KeyedSubtree(
                    key: _measure.putIfAbsent(l.agent.key, GlobalKey.new),
                    // The board's job is to let you answer: the agent in
                    // front of Needs you keeps its card and its answers in
                    // the compact list; the others waiting are named in rows
                    // (the triage walk, from the header, answers them in turn).
                    child: cards || l.front
                        ? AgentCard(agent: l.agent)
                        : AgentCompactRow(agent: l.agent, divider: !l.last),
                  ),
                ),
                final SessionLine l => Collapse(
                  key: l.key,
                  open: l.open,
                  child: AgentSessionRow(session: l.session, divider: !l.last, where: l.where),
                ),
                final AgentMore m => AgentMoreRow(key: m.key, more: m, onTap: () => _toggleFold(m.groupKey)),
                final AgentFolding f => _FoldAway(key: f.key, height: f.height, onDone: () => _folded(f.agentKey)),
              },
            ),
            SliverToBoxAdapter(child: SizedBox(height: listEnd)),
          ],
        ],
      ),
    );
    // Picking agents puts a bar over the title bar and the batch bar at the
    // bottom, the one bar home ever has there.
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<BoardSelection>.value(value: _selection),
        ChangeNotifierProvider<SettleGate>.value(value: _gate),
      ],
      child: _BackLeavesSelection(
        selection: _selection,
        child: Stack(
          children: [
            Positioned.fill(child: list),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SelectionHeader(onAll: () => _selection.selectAll(_visibleRefs)),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: BatchActionBar(onAction: (action) => unawaited(performBatchAction(context, action, _selection))),
            ),
          ],
        ),
      ),
    );
  }

  /// Closes [_gate] when the cards above an answer changed: one was removed or
  /// inserted, or the order changed. A card appended below the last answer
  /// moves nothing.
  void _armGateWhenAnswersMove(List<AgentEntry> entries, {required bool cards}) {
    var last = -1;
    for (final (i, e) in entries.indexed) {
      if (e is AgentLine && e.agent.status == AgentStatus.blocked && !e.agent.stale && (cards || e.front)) last = i;
    }
    final layout = [for (final e in entries.take(last + 1)) e.key];
    final before = _answerLayout;
    _answerLayout = layout;
    if (before == null || before.isEmpty) return;
    final unmoved = before.length <= layout.length && listEquals(before, layout.sublist(0, before.length));
    if (unmoved) return;
    _gate.arm();
  }

  /// [entries] with a gap, shrinking over [Motion.expand], where a card that
  /// stopped waiting stood. The card itself goes to its new section at once;
  /// the cards below glide up into the gap instead of jumping by a whole card
  /// (the next question moving up under a thumb that has not lifted yet).
  List<AgentEntry> _withFolding(List<AgentEntry> entries, AgentsOverview overview) {
    final now = {for (final a in overview.agents) a.key: a.status};
    _measure.removeWhere((key, _) => !now.containsKey(key));
    final before = _lastEntries;
    _lastEntries = entries;
    if (!Motion.reduced(context)) {
      bool leaves(AgentEntry e) =>
          e is AgentLine &&
          e.open &&
          e.agent.status == AgentStatus.blocked &&
          now[e.agent.key] != null &&
          now[e.agent.key] != AgentStatus.blocked;
      for (final (i, e) in before.indexed) {
        if (e is! AgentLine || !leaves(e) || _folding.containsKey(e.agent.key)) continue;
        final box = _measure[e.agent.key]?.currentContext?.findRenderObject();
        final height = box is RenderBox && box.hasSize ? box.size.height : 0.0;
        if (height <= 0) continue;
        var anchor = i - 1;
        while (anchor >= 0 && leaves(before[anchor])) {
          anchor--;
        }
        _folding[e.agent.key] = (height: height, after: anchor < 0 ? null : before[anchor].key, at: i);
      }
    }
    if (_folding.isEmpty) return entries;
    final out = [...entries];
    for (final MapEntry(key: agentKey, value: gap) in _folding.entries) {
      var at = 0;
      if (gap.after != null) {
        final anchor = out.indexWhere((e) => e.key == gap.after);
        at = anchor < 0 ? math.min(gap.at, out.length) : anchor + 1;
      }
      out.insert(at, AgentFolding(agentKey, gap.height));
    }
    return out;
  }

  void _folded(String agentKey) {
    if (mounted && _folding.remove(agentKey) != null) setState(() {});
  }

  /// What the Needs you header carries on its right: how many of its rows are
  /// out of reach, then the walk through every waiting agent (the triage
  /// sheet) when more than one waits: only the first is a card.
  _HeaderActions _needsYouActions(NeedsYouHeader h, {required int needYou}) => _HeaderActions(
    offline: h.offline,
    // The action's room is kept while there is no action (its 44 dp box,
    // and the choice of line made as if it were there): a second agent
    // starting to wait must not move the card in front under the thumb.
    holdsFor: _answerOneByOne,
    actions: [
      if (needYou > 1)
        // The sheet walks the same set, in the same order: terminal agents
        // and agent sessions.
        (
          key: const ValueKey('answer-one-by-one'),
          label: _answerOneByOne,
          tone: TextActionTone.accent,
          onTap: () => unawaited(showTriageSheet(context)),
        ),
    ],
  );

  /// What the `To review` line carries: the offline note, then "Mark
  /// reviewed" when something can be marked (an offline agent cannot: it is
  /// not counted and the note says why, instead of a button that would do
  /// nothing) and "Select all". One line above the groups rather than one per
  /// group: Mark reviewed is one batch (one toast, one Undo) over every
  /// finished agent wherever it is listed, and Select all picks them all for
  /// one batch action; split per project they would be several batches. The
  /// words were "Mark all reviewed" and wrapped on a 320 dp phone.
  _HeaderActions _reviewActions(ReviewHeader h, {required int review}) => _HeaderActions(
    offline: h.offline,
    actions: [
      if (review > 0)
        (
          key: const ValueKey('mark-all-reviewed'),
          label: 'Mark reviewed',
          tone: TextActionTone.quiet,
          onTap: _markAllReviewed,
        ),
      (key: const ValueKey('select-all-done'), label: 'Select all', tone: TextActionTone.quiet, onTap: _selectAllDone),
    ],
  );

  static const _answerOneByOne = 'Answer one by one';
  static const _toReview = 'To review';

  /// Picks every finished agent (terminal and session), opening the groups
  /// they sit in (and a fold that hides one) so that what is picked is on
  /// screen.
  void _selectAllDone() {
    final overview = AgentsOverview.of(context.read<FleetRepository>());
    final sessions = _sessions?.sessions ?? const <AgentSessionView>[];
    final attention = context.read<AttentionSet>();
    final layout = boardLayout(overview.agents, sessions, attention);
    bool isDone(BoardItem item) => statusOfItem(item) == AgentStatus.done;
    final done = <String>[];
    final groups = <String>{};
    final folds = <String>{};
    for (final g in layout.groups) {
      for (final item in g.items.where(isDone)) {
        groups.add(g.key);
        done.add(switch (item) {
          PaneItem(:final row) => paneRef(row.key),
          SessionItem(:final session) => sessionRef(session.key),
        });
      }
      if (foldedItems(g).any(isDone)) folds.add(g.key);
    }
    if (done.isEmpty) return;
    setState(() {
      _setFolded(_foldedKeys.difference(groups));
      _openFolds.addAll(folds);
    });
    _selection.selectAll(done);
  }

  /// Marks every finished terminal agent and agent session reviewed at once,
  /// with one toast and one Undo: the "to review" of [AttentionSet], what a
  /// swipe could mark (reachable).
  void _markAllReviewed() {
    final toReview = context.read<AttentionSet>().toReview;
    final n = markAllReviewedWithUndo(
      context,
      panes: [
        for (final item in toReview)
          if (item case PaneAttention(:final agent)) (machine: agent.machine, paneId: agent.pane.id),
      ],
      sessions: [
        for (final item in toReview)
          if (item case SessionAttention(:final session)) session,
      ],
    );
    if (n > 0) Haptics.sent();
  }

  void _queueRetain() {
    if (_retainQueued) return;
    _retainQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _retainQueued = false;
      if (mounted) _selection.retain(_liveRefs);
    });
  }
}

/// "2 offline" on a section header: rows listed as last known, whose machine
/// or link is down. They are not in the status line's count,
/// and nothing on the board can act on them until they are back.
class _OfflineNote extends StatelessWidget {
  const _OfflineNote({required this.count});

  final int count;

  static String words(int count) => '$count offline';

  static TextStyle style(Ds ds) => Type.label.copyWith(color: ds.textMuted, fontFeatures: Type.tabular);

  @override
  Widget build(BuildContext context) =>
      Text(words(count), maxLines: 1, overflow: TextOverflow.ellipsis, style: style(context.ds));
}

/// One ghost button on a section header, as data, so the header can measure
/// its words before it decides where they go.
typedef _HeaderAction = ({Key key, String label, TextActionTone tone, VoidCallback onTap});

/// What a header carries after its name: the note of how many of its agents
/// are offline, then its ghost buttons (Needs you's walk, To review's "Mark
/// reviewed" and "Select all").
class _HeaderActions {
  const _HeaderActions({required this.actions, this.offline = 0, this.holdsFor});

  final List<_HeaderAction> actions;
  final int offline;

  /// The label of an action that may come and go: its room is kept, and the
  /// header is laid out as if it were there, so its arrival moves nothing.
  final String? holdsFor;

  bool get isEmpty => actions.isEmpty && offline == 0 && holdsFor == null;

  /// The width the note and the buttons take on one line.
  double width(BuildContext context) {
    final ds = context.ds;
    final scaler = MediaQuery.textScalerOf(context);
    final labels = [
      for (final a in actions) a.label,
      if (holdsFor case final held? when !actions.any((a) => a.label == held)) held,
    ];
    final parts = [
      if (offline > 0) _textWidth(_OfflineNote.words(offline), _OfflineNote.style(ds), scaler),
      for (final l in labels) _textWidth(l, Type.labelStrong, scaler),
    ];
    final gaps = offline > 0 && labels.isNotEmpty
        ? Gap.sm + Gap.md * (labels.length - 1)
        : Gap.md * (labels.length - 1);
    return parts.fold(0.0, (a, b) => a + b) + (parts.length > 1 ? gaps : 0);
  }

  List<Widget> children() => [
    if (offline > 0) _OfflineNote(count: offline),
    for (final a in actions) TextAction(key: a.key, label: a.label, tone: a.tone, onTap: a.onTap),
  ];
}

double _textWidth(String text, TextStyle style, TextScaler scaler) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    textScaler: scaler,
    maxLines: 1,
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width;
}

/// A board section's header. Its name always shows whole: when the name and
/// the actions do not fit on one line (a narrow phone, large text), the
/// actions drop to their own line under it, left-aligned with the name, and
/// wrap if they must. Why not shrink them: an ellipsized "Mark re…" is an
/// action the person cannot read, and squeezing the name ("Do…") hid which
/// section the actions belong to.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    super.key,
    required this.label,
    required this.count,
    required this.expanded,
    required this.onTap,
    required this.actions,
  });

  final String label;
  final int? count;
  final bool? expanded;
  final VoidCallback? onTap;
  final _HeaderActions? actions;

  /// The width the header's name, count and caret need on one line.
  double _labelWidth(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    return _textWidth(label, Type.labelStrong, scaler) +
        (count == null ? 0 : Gap.sm + _textWidth('$count', Type.label.copyWith(fontFeatures: Type.tabular), scaler)) +
        (expanded == null ? 0 : Gap.xs + IconSize.row);
  }

  @override
  Widget build(BuildContext context) {
    final actions = this.actions;
    SectionLabel header({Widget? trailing}) =>
        SectionLabel(label: label, count: count, expanded: expanded, onTap: onTap, trailing: trailing);
    if (actions == null) return header();
    if (actions.isEmpty) return header();
    final room = MediaQuery.sizeOf(context).width - 2 * Gap.gutter;
    // One dp of slack for rounding between the measure and the layout.
    final oneLine = _labelWidth(context) + Gap.sm + actions.width(context) + 1 <= room;
    final items = actions.children();
    if (oneLine) {
      if (items.isEmpty) return header(trailing: const SizedBox(height: kMinTap));
      return header(
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (i, w) in items.indexed) ...[
              if (i > 0) SizedBox(width: i == 1 && actions.offline > 0 ? Gap.sm : Gap.md),
              w,
            ],
          ],
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header(),
        Container(
          constraints: const BoxConstraints(minHeight: kMinTap),
          padding: const EdgeInsets.symmetric(horizontal: Gap.gutter),
          child: Wrap(
            spacing: Gap.md,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final w in items)
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: kMinTap),
                  child: Align(widthFactor: 1, heightFactor: 1, child: w),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A project's header on the board: its name (a repo, else a folder) and a
/// one-line summary of what its rows are doing, in the words the board
/// already uses (`2 working · 1 done · 4 worktrees`). A tap folds it; folded,
/// the summary is what still says what is inside. Quiet on purpose: the
/// name of a thing in the text colour, the summary muted, no count in a
/// status colour (attention is Needs you's, pinned above).
class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    super.key,
    required this.label,
    required this.summary,
    required this.expanded,
    required this.onTap,
  });

  final String label;
  final String summary;
  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Padding(
      padding: const EdgeInsets.only(top: Gap.md),
      child: Semantics(
        header: true,
        expanded: expanded,
        child: PressRow(
          onTap: () {
            Haptics.tick();
            onTap();
          },
          minHeight: kMinTap,
          padding: const EdgeInsets.symmetric(horizontal: Gap.gutter - PressRow.inset, vertical: Gap.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Type.row.copyWith(color: ds.text),
                    ),
                  ),
                  const SizedBox(width: Gap.xs),
                  Caret(open: expanded),
                ],
              ),
              if (summary.isNotEmpty) ...[
                const SizedBox(height: Gap.hair),
                // Two lines at most: at large text on a narrow phone one line
                // cut the counts the fold exists to show. It breaks only
                // between facts, so a count never leaves its word (`1 / done`).
                Text(
                  summary.split(' · ').map((f) => f.replaceAll(' ', '\u00a0')).join(' · '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Type.secondary.copyWith(color: ds.textMuted, fontFeatures: Type.tabular),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Back leaves selection mode before it leaves anything else.
class _BackLeavesSelection extends StatelessWidget {
  const _BackLeavesSelection({required this.selection, required this.child});

  final BoardSelection selection;
  final Widget child;

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !context.select<BoardSelection?, bool>((s) => s?.active ?? false),
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) selection.cancel();
    },
    child: child,
  );
}

/// How fresh the board is: the connected machine heard from longest ago, so
/// one that stopped answering shows before it is declared offline. Null when
/// no connected machine has answered yet.
String? heardLabel(List<MachineConnection> connections) {
  Duration? oldest;
  for (final c in connections) {
    if (c.state != LinkState.online) continue;
    final ago = c.heardAgo();
    if (ago != null && (oldest == null || ago > oldest)) oldest = ago;
  }
  if (oldest == null) return null;
  // design-lint: allow(raw-duration) the label's own resolution, not a timer
  return oldest < const Duration(minutes: 1)
      ? 'heard just now'
      : 'heard ${Elapsed.compact(oldest, seconds: false)} ago';
}

/// The board's one status line: `2 need you · 3 working · heard just now ·
/// 1 not connected`. The needs-you count is the only loud words on it (the
/// blocked text colour), and the only place the board says it. A board with nothing waiting or working says
/// `nothing running`, so the line always answers "is everything alive?".
/// Counts are tabular, so a number that changes does not shift the words
/// after it.
class _StatusLine {
  const _StatusLine({
    required this.waiting,
    required this.working,
    required this.agents,
    required this.machines,
    required this.troubled,
  });

  final int waiting;
  final int working;
  final int agents;
  final int machines;
  final int troubled;

  /// The longest [heardLabel] in practice (`Elapsed.compact` past an hour),
  /// for measuring.
  static const longestHeard = 'heard 23h 59m ago';

  /// The facts in order; the needs-you count is the loud one.
  List<({String text, bool loud})> _facts(String? heard) {
    final quiet = [
      if (working > 0) '$working working' else if (waiting == 0 && agents > 0) 'nothing running',
      ?heard,
      if (troubled > 0) '$troubled not connected',
    ];
    if (waiting == 0 && quiet.isEmpty) quiet.add(countOf(machines, 'machine'));
    return [if (waiting > 0) (text: needYou(waiting), loud: true), for (final q in quiet) (text: q, loud: false)];
  }

  static TextSpan _join(Ds ds, List<({String text, bool loud})> facts, {int breakAt = -1}) => TextSpan(
    style: Type.secondary.copyWith(color: ds.textSecondary, fontFeatures: Type.tabular),
    children: [
      for (final (i, f) in facts.indexed) ...[
        if (i > 0) TextSpan(text: i == breakAt ? '\n' : ' · '),
        TextSpan(
          text: f.text,
          style: f.loud ? Type.secondaryStrong.copyWith(color: ds.blockedText, fontFeatures: Type.tabular) : null,
        ),
      ],
    ],
  );

  /// The line, with [heard] for this minute. When it does not fit one line
  /// it breaks between two facts, never inside one: `2 not` / `connected`
  /// read as two broken facts.
  TextSpan span(BuildContext context, {required String? heard}) {
    final ds = context.ds;
    final facts = _facts(heard);
    final whole = _join(ds, facts);
    if (_fits(context, whole)) return whole;
    var at = facts.length - 1;
    while (at > 1 && !_fits(context, _join(ds, facts.sublist(0, at)))) {
      at--;
    }
    return _join(ds, facts, breakAt: at);
  }

  /// 1, or 2 when the line does not fit the large title's width.
  int lines(BuildContext context, {required String? heard}) => _fits(context, _join(context.ds, _facts(heard))) ? 1 : 2;

  /// Whether [text] fits one line of the large title (with the header's own
  /// text-scale cap, [kBarTextScale]).
  static bool _fits(BuildContext context, TextSpan text) {
    final painter = TextPainter(
      text: text,
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context).clamp(maxScaleFactor: kBarTextScale),
      maxLines: 1,
    )..layout(maxWidth: math.max(0, MediaQuery.sizeOf(context).width - 2 * Gap.gutter));
    final fits = !painter.didExceedMaxLines;
    painter.dispose();
    return fits;
  }
}

/// Machines that are not connected, in one line. One machine is named and can
/// be retried here; several are summed up and the detail lives on Machines,
/// so the agents stay on the first screen.
class _ConnectionStrip extends StatelessWidget {
  const _ConnectionStrip({required this.troubled, required this.onShowMachines});

  final List<TroubledMachine> troubled;
  final VoidCallback? onShowMachines;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    if (troubled.length > 1) {
      final state = worstLinkState(troubled.map((t) => t.state));
      return StatusStrip(
        color: state.color(ds),
        leading: LinkDot(state: state),
        title: '${countOf(troubled.length, 'machine')} not connected',
        action: Icon(LucideIcons.chevronRight, size: IconSize.row, color: ds.textSecondary),
        onTap: onShowMachines,
      );
    }
    final t = troubled.single;
    return StatusStrip(
      key: ValueKey(t.machine.profile.id),
      color: t.state.color(ds),
      leading: LinkDot(state: t.state),
      title: t.label,
      detail: t.state.label,
      action: switch (t.approvalUrl) {
        final url? => ApprovalButton(url: url),
        null => AppButton(label: 'Retry', compact: true, kind: AppButtonKind.secondary, onPressed: t.machine.retry),
      },
    );
  }
}

/// A gap that was a card, closing. Not a card: it shows nothing, takes no tap.
class _FoldAway extends StatelessWidget {
  const _FoldAway({super.key, required this.height, required this.onDone});

  final double height;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: height, end: 0),
    duration: Motion.expand,
    curve: Motion.easeOut,
    onEnd: onDone,
    builder: (context, h, _) => SizedBox(height: h, width: double.infinity),
  );
}

/// The fleet at a glance, on the left of home's header: `2 of 3 machines`
/// with a mark, and a tap opens Machines. It reads as status, not as a
/// button: no fill at rest (the round buttons on the right have one),
/// secondary words, and its mark and words start on the large title's edge.
/// The mark is the [LinkDot] of the machine that most needs the person, the
/// same shape as its row on Machines: the quiet filled dot when every machine
/// that is on is online, the working ring while one connects, the blocked
/// ring with a dot for one to fix or approve, a quiet ring when every machine
/// is off. A switched-off machine is neither a problem nor online: it is not
/// counted.
class _MachineHealth extends StatelessWidget {
  const _MachineHealth({required this.online, required this.enabled, required this.worst, required this.onTap});

  final int online;
  final int enabled;

  /// The state that most needs the person among the machines not online;
  /// null when every one that is on is.
  final LinkState? worst;
  final VoidCallback onTap;

  static const _height = 36.0;

  /// From the bar's padded edge to the large title's: the mark lines up
  /// with the title's first letter.
  static const _inset = Gap.gutter - AppTopBar.edge;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final state = worst ?? (enabled == 0 ? LinkState.disabled : LinkState.online);
    final words = enabled == 0 ? 'All machines off' : '$online of ${countOf(enabled, 'machine')}';
    final spoken = enabled == 0 ? words : '$words online';
    return PressBuilder(
      key: const ValueKey('machine-health'),
      onTap: onTap,
      scale: PressScale.chip,
      button: true,
      minTapSize: kMinTap,
      semanticLabel: spoken,
      builder: (context, pressed) => AnimatedContainer(
        duration: Motion.pressing(pressed),
        curve: Motion.easeOut,
        height: _height,
        padding: const EdgeInsets.symmetric(horizontal: _inset),
        decoration: BoxDecoration(
          color: pressed ? ds.fill : Colors.transparent,
          borderRadius: BorderRadius.circular(Radii.pill),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            LinkDot(key: const ValueKey('machine-health-mark'), state: state),
            const SizedBox(width: Gap.sm),
            Flexible(
              child: Text(
                words,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Type.label.copyWith(color: ds.textSecondary, fontFeatures: Type.tabular),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
